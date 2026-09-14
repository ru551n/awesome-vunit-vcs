"""
XGMII and its wider relatives: one octet and one control bit per lane.

The same framing covers XGMII (IEEE 802.3 Clause 46, 4 lanes), the 64-bit
variant most 10G/25G MAC cores expose (8 lanes), 2.5GMII/5GMII, 25GMII,
XLGMII and CGMII. They differ in lane count and link rate only.

The VHDL frontend records one sample word per lane per column (a column is
the lanes transferred at one clock edge), lane 0 first, all at the time of
the edge::

    bit  0-7   lane data (TXD/RXD)
    bit  8     lane control (TXC/RXC)
    bit 10     metavalue on the data of the lane
    bit 11     metavalue on the control bit of the lane

Control characters, from IEEE 802.3 Table 46-3 (also Xilinx XAPP687 Table 2):
Idle 0x07, Start 0xFB, Terminate 0xFD, Error 0xFE and Sequence 0x9C. A
Sequence ordered set is 0x9C on lane 0 followed by three data lanes; local
fault is 0x00 0x00 0x01 and remote fault 0x00 0x00 0x02 (Table 46-5).

Decoding turns lanes into the octet words of :mod:`.common`: Start becomes
the first preamble octet (it replaces it on the wire), data lanes inside a
frame are valid octets, Error inside a frame is a valid octet with the error
bit, Terminate ends the frame. Everything the octet words cannot express is
reported as a :class:`~.common.PhyEvent`.

The octet time of lane ``k`` is the column time plus ``k`` octet periods
(``8 / link_rate`` seconds), so inter-frame gaps are measured in octets on
the wire whatever the clocking (single edge or both edges).
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from .common import (
    WORD_ERROR,
    WORD_META_CTRL,
    WORD_META_DATA,
    WORD_VALID,
    Int32Array,
    Int64Array,
    OctetBatch,
    PhyEvent,
    WireFrame,
)

XGMII_IDLE = 0x07
XGMII_LPI = 0x06
XGMII_START = 0xFB
XGMII_TERMINATE = 0xFD
XGMII_ERROR = 0xFE
XGMII_SEQUENCE = 0x9C

#: Sequence ordered set values (the three data lanes after 0x9C)
LOCAL_FAULT = 0x000001
REMOTE_FAULT = 0x000002
FAULT_NAMES = {LOCAL_FAULT: "local fault", REMOTE_FAULT: "remote fault"}

#: Control bit of an XGMII sample word
WORD_CONTROL = 1 << 8

_PREAMBLE_OCTET = 0x55

# Emits one octet word and its time
_Emit = Callable[[int, int], None]


class XgmiiPhy:
    """
    Decoder and encoder of an XGMII-style interface.

    ``lanes`` is 4 (XGMII) or 8 (the 64-bit variants). A frame starts on
    lane 0; ``allow_lane4_start`` also accepts Start and Sequence on lane 4
    of an 8-lane interface, as some 10GBASE-R PCS cores produce.

    The encoder always starts frames on lane 0, so the gap after a frame is
    rounded to whole columns. With ``deficit_idle`` it rounds down when the
    running deficit allows it, like a deficit idle count (IEEE 802.3 46.3.1.4),
    so the average gap equals the requested one; otherwise it rounds up.
    """

    name = "xgmii"

    def __init__(
        self,
        link_rate_bps: int = 10_000_000_000,
        lanes: int = 4,
        *,
        allow_lane4_start: bool = False,
        deficit_idle: bool = True,
    ) -> None:
        if lanes not in (4, 8):
            raise ValueError(f"An XGMII interface has 4 or 8 lanes, got {lanes}")
        if link_rate_bps <= 0:
            raise ValueError(f"link_rate_bps must be positive, got {link_rate_bps}")
        if allow_lane4_start and lanes != 8:
            raise ValueError("allow_lane4_start needs 8 lanes")
        self.link_rate_bps = link_rate_bps
        self.lanes = lanes
        self.octet_period_fs = 8 * 10**15 // link_rate_bps
        self.start_lanes = (0, 4) if allow_lane4_start else (0,)
        self.deficit_idle = deficit_idle

        # Decoder state, kept between batches
        self._lane = 0
        self._in_frame = False
        self._sequence: bytearray | None = None
        self._sequence_time = 0
        self._fault: int | None = None
        # Encoder state
        self._deficit = 0

    # Decoding
    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        count = int(words.size)
        lanes = self.lanes
        lane_index = (self._lane + np.arange(count, dtype=np.int64)) % lanes
        self._lane = (self._lane + count) % lanes
        octet_times = times + lane_index * self.octet_period_fs

        out_words: list[Int64Array] = []
        out_times: list[Int64Array] = []
        events: list[PhyEvent] = []

        def emit(word: int, time: int) -> None:
            out_words.append(np.array([word], dtype=np.int64))
            out_times.append(np.array([time], dtype=np.int64))

        controls = np.flatnonzero(words & (WORD_CONTROL | WORD_META_CTRL)).tolist()
        position = 0
        for index in [*controls, count]:
            if index > position:
                self._data(
                    words[position:index],
                    octet_times[position:index],
                    lane_index[position:index],
                    out_words,
                    out_times,
                    events,
                )
            if index == count:
                break
            self._control(int(words[index]), int(octet_times[index]), int(lane_index[index]), emit, events)
            position = index + 1

        if out_words:
            return OctetBatch(np.concatenate(out_words), np.concatenate(out_times), tuple(events))
        empty = np.zeros(0, dtype=np.int64)
        return OctetBatch(empty, empty.copy(), tuple(events))

    def _data(
        self,
        words: Int64Array,
        times: Int64Array,
        lane_index: Int64Array,
        out_words: list[Int64Array],
        out_times: list[Int64Array],
        events: list[PhyEvent],
    ) -> None:
        if self._in_frame:
            octets = (words & 0xFF) | WORD_VALID | (words & WORD_META_DATA)
            out_words.append(octets.astype(np.int64))
            out_times.append(times)
            return

        start = 0
        if self._sequence is not None:
            take = min(3 - len(self._sequence), int(words.size))
            self._sequence += (words[:take] & 0xFF).astype(np.uint8).tobytes()
            start = take
            if len(self._sequence) == 3:
                self._sequence_complete(events)

        rest = words[start:]
        if rest.size == 0:
            return
        metavalues = np.flatnonzero(rest & WORD_META_DATA)
        if metavalues.size:
            # Reported by the frame assembler as a metavalue outside a frame
            out_words.append(rest[metavalues] & WORD_META_DATA)
            out_times.append(times[start:][metavalues])
        if metavalues.size < rest.size:
            first = int(np.flatnonzero((rest & WORD_META_DATA) == 0)[0])
            events.append(
                PhyEvent(
                    int(times[start + first]),
                    "ETH_CONTROL",
                    "data character outside a frame",
                    (f"lane={int(lane_index[start + first])}", f"data=0x{int(rest[first]) & 0xFF:02X}"),
                )
            )

    def _control(self, word: int, time: int, lane: int, emit: _Emit, events: list[PhyEvent]) -> None:
        code = word & 0xFF

        if word & WORD_META_CTRL:
            # A control bit that is not 0 or 1: part of the frame when in one
            emit((code | WORD_VALID | WORD_META_CTRL) if self._in_frame else WORD_META_CTRL, time)
            return

        if self._in_frame:
            if code == XGMII_TERMINATE:
                self._in_frame = False
                emit(0, time)
                return
            if code == XGMII_ERROR:
                emit(code | WORD_VALID | WORD_ERROR, time)
                return
            events.append(
                PhyEvent(
                    time,
                    "ETH_TERMINATION",
                    f"frame ended by control character 0x{code:02X} without Terminate",
                    (f"lane={lane}",),
                )
            )
            self._in_frame = False
            emit(0, time)

        if self._sequence is not None:
            events.append(
                PhyEvent(
                    time, "ETH_CONTROL", "incomplete Sequence ordered set", (f"lane={lane}", f"control=0x{code:02X}")
                )
            )
            self._sequence = None

        if code == XGMII_START:
            if lane not in self.start_lanes:
                events.append(PhyEvent(time, "ETH_CONTROL", f"Start on lane {lane}", self._start_lane_details()))
            self._in_frame = True
            self._fault = None
            # Start is an explicit frame boundary: the frame cannot have been
            # in progress before it, whatever was recorded earlier
            emit(0, time)
            emit(_PREAMBLE_OCTET | WORD_VALID, time)
        elif code in (XGMII_IDLE, XGMII_LPI):
            if lane == 0:
                self._fault = None
            emit(0, time)
        elif code == XGMII_ERROR:
            emit(WORD_ERROR | code, time)
        elif code == XGMII_SEQUENCE:
            if lane not in self.start_lanes:
                events.append(
                    PhyEvent(time, "ETH_CONTROL", f"Sequence ordered set on lane {lane}", self._start_lane_details())
                )
            self._sequence = bytearray()
            self._sequence_time = time
        elif code == XGMII_TERMINATE:
            events.append(PhyEvent(time, "ETH_CONTROL", "Terminate outside a frame", (f"lane={lane}",)))
            emit(0, time)
        else:
            events.append(PhyEvent(time, "ETH_CONTROL", f"unknown control character 0x{code:02X}", (f"lane={lane}",)))
            emit(0, time)

    def _start_lane_details(self) -> tuple[str, ...]:
        return ("allowed lanes=" + ", ".join(str(lane) for lane in self.start_lanes),)

    def _sequence_complete(self, events: list[PhyEvent]) -> None:
        assert self._sequence is not None
        value = int.from_bytes(self._sequence, "big")
        self._sequence = None
        if value in FAULT_NAMES:
            if self._fault != value:
                events.append(
                    PhyEvent(
                        self._sequence_time,
                        "ETH_LINK_FAULT",
                        f"{FAULT_NAMES[value]} signaled",
                        (f"ordered set=0x9C 0x{value:06X}",),
                    )
                )
            self._fault = value
        else:
            events.append(
                PhyEvent(
                    self._sequence_time,
                    "ETH_CONTROL",
                    "reserved Sequence ordered set",
                    (f"ordered set=0x9C 0x{value:06X}",),
                )
            )

    # Encoding
    def encode(self, wire: WireFrame) -> Int32Array:
        lanes = self.lanes
        length = len(wire.octets)
        if length == 0:
            return np.zeros(0, dtype=np.int32)

        requested = max(wire.ifg_octets, 1)
        # Octets from Terminate to the end of its column
        first = lanes - length % lanes
        up = first + max(0, -(-(requested - first) // lanes)) * lanes
        down = up - lanes
        if self.deficit_idle and down >= first and requested - down + self._deficit <= lanes - 1:
            gap = down
            self._deficit += requested - down
        else:
            gap = up
            if self.deficit_idle:
                self._deficit = max(0, self._deficit - (gap - requested))

        symbols = np.full(length + gap, XGMII_IDLE | WORD_CONTROL, dtype=np.int32)
        symbols[:length] = np.frombuffer(wire.octets, dtype=np.uint8)
        symbols[0] = XGMII_START | WORD_CONTROL
        if wire.error_offsets:
            symbols[list(wire.error_offsets)] = XGMII_ERROR | WORD_CONTROL
        symbols[length] = XGMII_TERMINATE | WORD_CONTROL
        return symbols

    def ordered_set_symbols(self, value: int, columns: int = 1) -> Int32Array:
        """Columns carrying a Sequence ordered set on lane 0, for example :data:`LOCAL_FAULT`."""
        if not 0 <= value < 1 << 24:
            raise ValueError(f"An ordered set value is 24 bits, got 0x{value:X}")
        column = np.full(self.lanes, XGMII_IDLE | WORD_CONTROL, dtype=np.int32)
        column[:4] = [XGMII_SEQUENCE | WORD_CONTROL, *value.to_bytes(3, "big")]
        return np.tile(column, columns)

    def column_symbols(self, data: list[int], control: list[int]) -> Int32Array:
        """Raw columns: one data octet and one control bit per lane, lane 0 first."""
        if len(data) != len(control) or len(data) % self.lanes:
            raise ValueError(
                f"Raw columns need as many control bits as data octets, a multiple of {self.lanes}; "
                f"got {len(data)} data octets and {len(control)} control bits"
            )
        values = np.asarray(data, dtype=np.int32) & 0xFF
        return values | np.where(np.asarray(control) != 0, WORD_CONTROL, 0).astype(np.int32)
