# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The sample words of the AXI4 monitor and protocol checker, and their decoding.

On every rising edge of ACLK the VHDL components record a *record* for each channel whose VALID is
high, whose VALID changed since the previous edge, or whose VALID or READY is a metavalue. Cycles
without a record are idle: VALID low on every channel. A record is a header word followed by the
payload words of the channel, all with the time of the edge:

Header word
    ======  =========================================================
    Bits    Meaning
    ======  =========================================================
    0-2     The :class:`Channel`, or 5 for a control record
    3       VALID is 1
    4       READY is 1
    5, 6    A metavalue on VALID, on READY
    7       A metavalue on the payload, data lanes not counted
    8       ARESETn is 1
    9       A metavalue on ARESETn
    10-11   The :class:`ControlKind` of a control record
    ======  =========================================================

Payload words
    The fields of the channel, first field in the least significant bits of the first word, packed
    32 bits to a word (the last word padded with 0), see :meth:`Axi4Config.layout`. A metavalue
    bit is sent as 0. The write and read data channels end with a *lane metavalue* field: bit ``n``
    is set when byte lane ``n`` of the data has a metavalue.

Control records
    ``RESET``: ARESETn changed (bits 8 and 9 give its new value). ``PERIOD``: the clock period
    changed; one payload word holds the new period in ps. ``TICK``: no information, sent by a
    protocol checker so the backend learns the time when nothing happens on the bus.

VHDL records control records before the channel records of the same edge, and may split a batch
inside a record; :class:`SampleDecoder` keeps the unfinished record for the next batch.
"""

from __future__ import annotations

import enum
from collections.abc import Iterator
from dataclasses import dataclass, field

from .burst import BurstType
from .errors import Axi4ValueError

__all__ = [
    "AddressPayload",
    "Axi4Config",
    "Axi4Control",
    "Axi4Sample",
    "Channel",
    "ControlKind",
    "ReadDataPayload",
    "ResponsePayload",
    "SampleDecoder",
    "WriteDataPayload",
]

#: The kind of a control record in the header word
CONTROL = 5
KIND_MASK = 0x7
VALID_BIT = 1 << 3
READY_BIT = 1 << 4
VALID_METAVALUE_BIT = 1 << 5
READY_METAVALUE_BIT = 1 << 6
PAYLOAD_METAVALUE_BIT = 1 << 7
RESETN_BIT = 1 << 8
RESETN_METAVALUE_BIT = 1 << 9
CONTROL_SHIFT = 10
WORD_BITS = 32
_WORD_MASK = (1 << WORD_BITS) - 1
_FS_PER_PS = 1000


class Channel(enum.IntEnum):
    """The five channels of AXI4, with their code in the header word."""

    AW = 0
    W = 1
    B = 2
    AR = 3
    R = 4


class ControlKind(enum.IntEnum):
    """The kind of a control record."""

    RESET = 0
    PERIOD = 1
    TICK = 2


@dataclass(frozen=True, slots=True)
class Axi4Config:
    """
    The widths of an AXI4 or AXI4-Lite interface, in bits.

    Args:
        data_width: WDATA and RDATA, a power of 2 from 8 to 1024; 32 or 64 for AXI4-Lite.
        address_width: AWADDR and ARADDR, 1 to 64.
        id_width: AWID, BID, ARID and RID, 0 to 32; 0 when the interface has no ID signals.
        awuser_width, wuser_width, buser_width, aruser_width, ruser_width: The USER signals, 0 to
            1024; 0 when absent.
        lite: AXI4-Lite: every transaction is a single beat of the full data width with ID 0, and the
            signals AXI4-Lite does not have take their default values whatever the pins carry.

    Raises:
        Axi4ValueError: A width is out of range.
    """

    data_width: int = 32
    address_width: int = 32
    id_width: int = 0
    awuser_width: int = 0
    wuser_width: int = 0
    buser_width: int = 0
    aruser_width: int = 0
    ruser_width: int = 0
    lite: bool = False
    _layouts: dict[Channel, tuple[tuple[str, int], ...]] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        width = self.data_width
        if width < 8 or width > 1024 or width & (width - 1):
            raise Axi4ValueError(f"data_width={width} is not a power of 2 from 8 to 1024")
        if self.lite and width not in (32, 64):
            raise Axi4ValueError(f"AXI4-Lite has a data width of 32 or 64 bits, not {width}")
        if not 1 <= self.address_width <= 64:
            raise Axi4ValueError(f"address_width={self.address_width} is not from 1 to 64")
        if not 0 <= self.id_width <= 32:
            raise Axi4ValueError(f"id_width={self.id_width} is not from 0 to 32")
        for name in ("awuser_width", "wuser_width", "buser_width", "aruser_width", "ruser_width"):
            if not 0 <= getattr(self, name) <= 1024:
                raise Axi4ValueError(f"{name}={getattr(self, name)} is not from 0 to 1024")
        lanes = self.data_bytes

        def address(user: int) -> tuple[tuple[str, int], ...]:
            return (
                ("id", self.id_width),
                ("address", self.address_width),
                ("len", 8),
                ("size", 3),
                ("burst", 2),
                ("lock", 1),
                ("cache", 4),
                ("prot", 3),
                ("qos", 4),
                ("region", 4),
                ("user", user),
            )

        layouts = {
            Channel.AW: address(self.awuser_width),
            Channel.W: (
                ("data", width),
                ("strb", lanes),
                ("last", 1),
                ("user", self.wuser_width),
                ("lane_metavalues", lanes),
            ),
            Channel.B: (("id", self.id_width), ("resp", 2), ("user", self.buser_width)),
            Channel.AR: address(self.aruser_width),
            Channel.R: (
                ("id", self.id_width),
                ("data", width),
                ("resp", 2),
                ("last", 1),
                ("user", self.ruser_width),
                ("lane_metavalues", lanes),
            ),
        }
        object.__setattr__(self, "_layouts", layouts)

    @property
    def data_bytes(self) -> int:
        """The width of the data bus in bytes, the number of byte lanes."""
        return self.data_width // 8

    @property
    def full_size(self) -> int:
        """The AxSIZE of a beat as wide as the data bus."""
        return self.data_bytes.bit_length() - 1

    def layout(self, channel: Channel) -> tuple[tuple[str, int], ...]:
        """The payload fields of a channel as ``(name, bits)``, first field in the least significant bits."""
        return self._layouts[channel]

    def payload_words(self, channel: Channel) -> int:
        """The number of payload words of a record of the channel."""
        bits = sum(width for _, width in self._layouts[channel])
        return -(-bits // WORD_BITS)


@dataclass(frozen=True, slots=True)
class AddressPayload:
    """The AW or AR channel: the address phase of a transaction."""

    id: int
    address: int
    len: int
    size: int
    burst: int
    lock: int
    cache: int
    prot: int
    qos: int
    region: int
    user: int


@dataclass(frozen=True, slots=True)
class WriteDataPayload:
    """The W channel: one beat of write data. Bit ``n`` of ``strb`` and ``lane_metavalues`` is lane ``n``."""

    data: int
    strb: int
    last: bool
    user: int
    lane_metavalues: int


@dataclass(frozen=True, slots=True)
class ResponsePayload:
    """The B channel: a write response."""

    id: int
    resp: int
    user: int


@dataclass(frozen=True, slots=True)
class ReadDataPayload:
    """The R channel: one beat of read data with its response."""

    id: int
    data: int
    resp: int
    last: bool
    user: int
    lane_metavalues: int


Payload = AddressPayload | WriteDataPayload | ResponsePayload | ReadDataPayload


@dataclass(frozen=True, slots=True)
class Axi4Sample:
    """
    One channel at one rising edge of ACLK.

    Attributes:
        channel: The channel.
        time_fs: The time of the edge.
        valid: VALID is 1.
        ready: READY is 1.
        valid_metavalue: VALID is a metavalue (``valid`` is then false).
        ready_metavalue: READY is a metavalue (``ready`` is then false).
        payload_metavalue: A payload signal other than the data is a metavalue.
        in_reset: ARESETn is 0 or a metavalue.
        payload: The payload, with metavalue bits read as 0.
    """

    channel: Channel
    time_fs: int
    valid: bool
    ready: bool
    valid_metavalue: bool
    ready_metavalue: bool
    payload_metavalue: bool
    in_reset: bool
    payload: Payload

    @property
    def handshake(self) -> bool:
        """Whether VALID and READY are 1 outside reset, so the payload is transferred."""
        return self.valid and self.ready and not self.in_reset

    @property
    def stall(self) -> bool:
        """Whether VALID is 1 and READY is not, outside reset, so the channel is under backpressure."""
        return self.valid and not self.ready and not self.in_reset


@dataclass(frozen=True, slots=True)
class Axi4Control:
    """
    A control record.

    Attributes:
        kind: What it tells.
        time_fs: The time of the edge.
        in_reset: ARESETn is 0 or a metavalue.
        resetn_metavalue: ARESETn is a metavalue.
        period_fs: The new clock period of a ``PERIOD`` record, else 0.
    """

    kind: ControlKind
    time_fs: int
    in_reset: bool
    resetn_metavalue: bool
    period_fs: int = 0


class SampleDecoder:
    """
    Turn the sample words of the VHDL components into :class:`Axi4Sample` and :class:`Axi4Control`.

    Args:
        config: The widths of the interface.
    """

    def __init__(self, config: Axi4Config) -> None:
        self.config = config
        self._pending_words: list[int] = []
        self._pending_times: list[int] = []
        self._fields = {
            channel: tuple((name, offset, (1 << width) - 1) for name, offset, width in _offsets(config.layout(channel)))
            for channel in Channel
        }
        self._words = {channel: config.payload_words(channel) for channel in Channel}

    def reset(self) -> None:
        """Drop an unfinished record."""
        self._pending_words = []
        self._pending_times = []

    def decode(self, words: list[int], times: list[int]) -> Iterator[Axi4Sample | Axi4Control]:
        """
        The records of a batch, in order. An unfinished record at the end waits for the next batch.

        Args:
            words: Sample words.
            times: The time of each word in fs.

        Raises:
            Axi4ValueError: A header word has an unknown kind.
        """
        if self._pending_words:
            words = self._pending_words + list(words)
            times = self._pending_times + list(times)
            self._pending_words, self._pending_times = [], []
        index = 0
        count = len(words)
        while index < count:
            header = words[index]
            kind = header & KIND_MASK
            if kind == CONTROL:
                control_kind = ControlKind((header >> CONTROL_SHIFT) & 0x3)
                needed = 2 if control_kind == ControlKind.PERIOD else 1
            elif kind < CONTROL:
                needed = 1 + self._words[Channel(kind)]
            else:
                raise Axi4ValueError(f"Unknown record kind {kind} in the sample word 0x{header & _WORD_MASK:08X}")
            if index + needed > count:
                self._pending_words = words[index:]
                self._pending_times = times[index:]
                return
            yield self._record(header, kind, words[index + 1 : index + needed], times[index])
            index += needed

    def _record(self, header: int, kind: int, payload_words: list[int], time_fs: int) -> Axi4Sample | Axi4Control:
        in_reset = not header & RESETN_BIT or bool(header & RESETN_METAVALUE_BIT)
        if kind == CONTROL:
            control_kind = ControlKind((header >> CONTROL_SHIFT) & 0x3)
            period = (payload_words[0] & _WORD_MASK) * _FS_PER_PS if control_kind == ControlKind.PERIOD else 0
            return Axi4Control(control_kind, time_fs, in_reset, bool(header & RESETN_METAVALUE_BIT), period)
        channel = Channel(kind)
        value = 0
        for position, word in enumerate(payload_words):
            value |= (word & _WORD_MASK) << (WORD_BITS * position)
        fields = {name: (value >> offset) & mask for name, offset, mask in self._fields[channel]}
        return Axi4Sample(
            channel=channel,
            time_fs=time_fs,
            valid=bool(header & VALID_BIT),
            ready=bool(header & READY_BIT),
            valid_metavalue=bool(header & VALID_METAVALUE_BIT),
            ready_metavalue=bool(header & READY_METAVALUE_BIT),
            payload_metavalue=bool(header & PAYLOAD_METAVALUE_BIT),
            in_reset=in_reset,
            payload=self._payload(channel, fields),
        )

    def _payload(self, channel: Channel, fields: dict[str, int]) -> Payload:
        lite = self.config.lite
        if channel in (Channel.AW, Channel.AR):
            if lite:
                return AddressPayload(
                    0, fields["address"], 0, self.config.full_size, BurstType.INCR, 0, 0, fields["prot"], 0, 0, 0
                )
            return AddressPayload(**fields)
        if channel == Channel.W:
            return WriteDataPayload(
                fields["data"], fields["strb"], lite or bool(fields["last"]), fields["user"], fields["lane_metavalues"]
            )
        if channel == Channel.B:
            return ResponsePayload(0 if lite else fields["id"], fields["resp"], fields["user"])
        return ReadDataPayload(
            0 if lite else fields["id"],
            fields["data"],
            fields["resp"],
            lite or bool(fields["last"]),
            fields["user"],
            fields["lane_metavalues"],
        )


def _offsets(layout: tuple[tuple[str, int], ...]) -> Iterator[tuple[str, int, int]]:
    offset = 0
    for name, width in layout:
        yield name, offset, width
        offset += width
