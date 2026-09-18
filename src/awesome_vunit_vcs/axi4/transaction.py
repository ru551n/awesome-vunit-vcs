# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
AXI4 transactions, reconstructed from the handshakes of the five channels.

A write is an AW handshake, its ``AWLEN + 1`` W beats, which may come before the AW handshake, and a
B handshake. A read is an AR handshake and its ``ARLEN + 1`` R beats. AXI4 has no WID, so W beats
belong to the writes in the order of their AW handshakes. B and R handshakes belong to the oldest
outstanding transaction with their ID; transactions with different IDs complete in any order, and
the read data of different IDs may interleave.

The burst length is authoritative: a transaction ends after its ``len + 1`` beats whatever WLAST or
RLAST say, and a wrong WLAST or RLAST is reported.
"""

from __future__ import annotations

import enum
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass

from .burst import BurstType, beat_addresses, beat_lanes, lane_mask
from .bus import AddressPayload, Axi4Config, Axi4Sample, Channel, ReadDataPayload, ResponsePayload, WriteDataPayload
from .checks import Axi4CheckId

__all__ = ["Axi4Beat", "Axi4Transaction", "Direction", "Response", "TransactionTracker"]


class Direction(str, enum.Enum):
    """The direction of a transaction."""

    WRITE = "write"
    READ = "read"


class Response(enum.IntEnum):
    """The BRESP and RRESP encodings."""

    OKAY = 0
    EXOKAY = 1
    SLVERR = 2
    DECERR = 3


@dataclass(frozen=True, slots=True)
class Axi4Beat:
    """
    One data beat of a transaction.

    Attributes:
        index: The number of the beat, from 0.
        address: The address of the beat, see :func:`~awesome_vunit_vcs.axi4.burst.beat_addresses`.
        lanes: The lowest and highest byte lane that carry data, both included.
        data: WDATA or RDATA, lane 0 in the least significant byte.
        strobe: WSTRB for a write; for a read, the mask of ``lanes``.
        last: WLAST or RLAST.
        user: WUSER or RUSER.
        resp: RRESP of a read beat, None for a write beat.
        time_fs: The time of the handshake.
    """

    index: int
    address: int
    lanes: tuple[int, int]
    data: int
    strobe: int
    last: bool
    user: int
    resp: Response | None
    time_fs: int

    def lane_bytes(self) -> bytes:
        """The bytes of ``lanes``, lowest lane first."""
        lower, upper = self.lanes
        return bytes((self.data >> (8 * lane)) & 0xFF for lane in range(lower, upper + 1))

    def lane_strobes(self) -> tuple[bool, ...]:
        """Whether each byte of :meth:`lane_bytes` is written; always true for a read."""
        lower, upper = self.lanes
        return tuple(bool(self.strobe >> lane & 1) for lane in range(lower, upper + 1))


@dataclass(frozen=True, slots=True)
class Axi4Transaction:
    """
    A complete write or read.

    Attributes:
        index: The number of the transaction among those of its direction, from 0.
        direction: Write or read.
        id: AWID or ARID.
        address: AWADDR or ARADDR.
        len: AxLEN; the burst has ``len + 1`` beats.
        size: AxSIZE; a beat has ``2**size`` bytes.
        burst: AxBURST.
        lock: AxLOCK, 1 for an exclusive access.
        cache: AxCACHE.
        prot: AxPROT.
        qos: AxQOS.
        region: AxREGION.
        user: AWUSER or ARUSER.
        beats: The data beats.
        resp: BRESP of a write. For a read, the first RRESP that is neither OKAY nor EXOKAY, or else
            the RRESP of the last beat.
        response_user: BUSER of a write, 0 for a read.
        data_bytes: The width of the data bus in bytes.
        address_fs: The time of the address handshake.
        first_data_fs: The time of the first data handshake; before ``address_fs`` for a write
            whose data came first.
        last_data_fs: The time of the last data handshake.
        response_fs: The time of the B handshake of a write; ``last_data_fs`` for a read.
    """

    index: int
    direction: Direction
    id: int
    address: int
    len: int
    size: int
    burst: BurstType
    lock: int
    cache: int
    prot: int
    qos: int
    region: int
    user: int
    beats: tuple[Axi4Beat, ...]
    resp: Response
    response_user: int
    data_bytes: int
    address_fs: int
    first_data_fs: int
    last_data_fs: int
    response_fs: int

    @property
    def is_write(self) -> bool:
        """The transaction is a write."""
        return self.direction == Direction.WRITE

    @property
    def exclusive(self) -> bool:
        """The transaction is an exclusive access."""
        return bool(self.lock)

    @property
    def number_bytes(self) -> int:
        """The bytes of a beat, ``2**size``."""
        return 1 << self.size

    def data(self) -> bytes:
        """The bytes of the byte lanes of every beat, in beat order, lowest lane first."""
        return b"".join(beat.lane_bytes() for beat in self.beats)

    def strobes(self) -> tuple[bool, ...]:
        """For each byte of :meth:`data`, whether it is written; always true for a read."""
        return tuple(strobe for beat in self.beats for strobe in beat.lane_strobes())

    def transferred_bytes(self) -> list[tuple[int, int]]:
        """``(address, value)`` of every byte written (strobed) or read, in beat order."""
        result = []
        for beat in self.beats:
            base = beat.address // self.data_bytes * self.data_bytes
            lower, upper = beat.lanes
            for lane in range(lower, upper + 1):
                if beat.strobe >> lane & 1:
                    result.append((base + lane, (beat.data >> (8 * lane)) & 0xFF))
        return result

    def describe(self) -> str:
        """A short description for messages: direction, ID, address, beats and size."""
        return (
            f"{self.direction.value} ID {self.id} at 0x{self.address:X} ({self.len + 1} x {self.number_bytes} bytes,"
            f" {self.burst.name})"
        )


#: Called with a check, a message and the time in fs
ViolationHandler = Callable[[Axi4CheckId, str, int], None]


class _Pending:
    """A transaction whose address handshake came and that is not complete."""

    __slots__ = ("address", "beats", "direction", "index", "lanes", "payload", "reported", "time_fs")

    def __init__(self, direction: Direction, payload: AddressPayload, time_fs: int, config: Axi4Config) -> None:
        self.direction = direction
        self.payload = payload
        self.time_fs = time_fs
        self.address = beat_addresses(payload.address, payload.len, payload.size, payload.burst)
        self.lanes = beat_lanes(payload.address, payload.len, payload.size, payload.burst, config.data_bytes)
        self.beats: list[Axi4Beat] = []
        self.index = -1
        self.reported = False

    @property
    def complete(self) -> bool:
        return len(self.beats) > self.payload.len

    def describe(self) -> str:
        p = self.payload
        return f"{self.direction.value} ID {p.id} at 0x{p.address:X} ({p.len + 1} x {1 << p.size} bytes)"


class TransactionTracker:
    """
    Reconstruct transactions from channel handshakes.

    Args:
        config: The widths of the interface.
        on_transaction: Called with every complete transaction.
        on_violation: Called with the protocol violations the reconstruction finds: ``AXI4_WLAST``,
            ``AXI4_RLAST``, ``AXI4_WSTRB``, ``AXI4_UNEXPECTED_RESP``, ``AXI4_EXCL`` (EXOKAY to a normal
            access), ``AXI4_METAVALUE`` (on an active read data lane) and ``AXI4_TIMEOUT``.
    """

    def __init__(
        self,
        config: Axi4Config,
        on_transaction: Callable[[Axi4Transaction], None],
        on_violation: ViolationHandler | None = None,
    ) -> None:
        self.config = config
        self._on_transaction = on_transaction
        self._on_violation = on_violation
        self._counts = {Direction.WRITE: 0, Direction.READ: 0}
        self.reset()

    def reset(self) -> None:
        """Drop every outstanding transaction and buffered write data, as a reset of the bus does."""
        self._waiting_data: deque[_Pending] = deque()
        self._w_buffer: deque[tuple[WriteDataPayload, int]] = deque()
        self._w_buffer_reported = False
        self._awaiting_response: dict[int, deque[_Pending]] = {}
        self._reads: dict[int, deque[_Pending]] = {}

    def outstanding(self, direction: Direction) -> int:
        """The transactions of a direction whose address handshake came and that are not complete."""
        if direction == Direction.WRITE:
            return len(self._waiting_data) + sum(len(queue) for queue in self._awaiting_response.values())
        return sum(len(queue) for queue in self._reads.values())

    def outstanding_ids(self, direction: Direction) -> dict[int, int]:
        """The outstanding transactions of a direction per ID, IDs without any left out."""
        counts: dict[int, int] = {}
        if direction == Direction.WRITE:
            pending = [*self._waiting_data, *(p for queue in self._awaiting_response.values() for p in queue)]
        else:
            pending = [p for queue in self._reads.values() for p in queue]
        for p in pending:
            counts[p.payload.id] = counts.get(p.payload.id, 0) + 1
        return counts

    def next_read_lanes(self, id_: int) -> int | None:
        """The lane mask of the next read data beat with RID ``id_``, None without an outstanding read."""
        queue = self._reads.get(id_)
        if not queue:
            return None
        pending = queue[0]
        return lane_mask(pending.lanes[len(pending.beats)])

    @property
    def buffered_write_beats(self) -> int:
        """W beats that came before their AW handshake."""
        return len(self._w_buffer)

    def handshake(self, sample: Axi4Sample) -> None:
        """Take the handshake of a channel. ``sample.handshake`` must be true."""
        payload = sample.payload
        if sample.channel == Channel.AW:
            assert isinstance(payload, AddressPayload)
            self._waiting_data.append(_Pending(Direction.WRITE, payload, sample.time_fs, self.config))
            self._attribute_write_data()
        elif sample.channel == Channel.W:
            assert isinstance(payload, WriteDataPayload)
            self._w_buffer.append((payload, sample.time_fs))
            self._attribute_write_data()
        elif sample.channel == Channel.B:
            assert isinstance(payload, ResponsePayload)
            self._write_response(payload, sample.time_fs)
        elif sample.channel == Channel.AR:
            assert isinstance(payload, AddressPayload)
            self._reads.setdefault(payload.id, deque()).append(
                _Pending(Direction.READ, payload, sample.time_fs, self.config)
            )
        else:
            assert isinstance(payload, ReadDataPayload)
            self._read_data(payload, sample.time_fs)

    def check_timeouts(self, now_fs: int, limit_fs: int) -> None:
        """
        Report ``AXI4_TIMEOUT`` once for every transaction outstanding, and for write data waiting for
        its address, for longer than ``limit_fs`` at ``now_fs``.
        """
        pending = [
            *self._waiting_data,
            *(p for queue in self._awaiting_response.values() for p in queue),
            *(p for queue in self._reads.values() for p in queue),
        ]
        for p in pending:
            if not p.reported and now_fs - p.time_fs > limit_fs:
                p.reported = True
                if p.direction == Direction.READ:
                    what = f"read data beat {len(p.beats)}"
                elif p.complete:
                    what = "a write response"
                else:
                    what = f"write data beat {len(p.beats)}"
                self._violation(
                    Axi4CheckId.TIMEOUT,
                    f"the {p.describe()} with its address handshake at {p.time_fs} fs is still waiting for {what}"
                    f" at {now_fs} fs",
                    now_fs,
                )
        if self._w_buffer and not self._w_buffer_reported and now_fs - self._w_buffer[0][1] > limit_fs:
            self._w_buffer_reported = True
            self._violation(
                Axi4CheckId.TIMEOUT,
                f"the write data beat at {self._w_buffer[0][1]} fs is still waiting for its AW handshake"
                f" at {now_fs} fs",
                now_fs,
            )

    def _violation(self, check: Axi4CheckId, message: str, time_fs: int) -> None:
        if self._on_violation is not None:
            self._on_violation(check, f"{check.value}: {message}", time_fs)

    def _attribute_write_data(self) -> None:
        while self._w_buffer and self._waiting_data:
            payload, time_fs = self._w_buffer.popleft()
            self._w_buffer_reported = False
            pending = self._waiting_data[0]
            index = len(pending.beats)
            lanes = pending.lanes[index]
            beat = Axi4Beat(
                index,
                pending.address[index],
                lanes,
                payload.data,
                payload.strb,
                payload.last,
                payload.user,
                None,
                time_fs,
            )
            pending.beats.append(beat)
            last = index == pending.payload.len
            if payload.last != last:
                self._violation(
                    Axi4CheckId.WLAST,
                    f"WLAST is {int(payload.last)} on beat {index} of {pending.payload.len + 1} of the"
                    f" {pending.describe()} at {time_fs} fs",
                    time_fs,
                )
            outside = payload.strb & ~lane_mask(lanes) & ((1 << self.config.data_bytes) - 1)
            if outside:
                self._violation(
                    Axi4CheckId.WSTRB,
                    f"WSTRB 0x{payload.strb:X} sets lanes 0x{outside:X} outside the lanes {lanes[0]} to {lanes[1]} of"
                    f" beat {index} (address 0x{beat.address:X}) of the {pending.describe()} at {time_fs} fs",
                    time_fs,
                )
            if last:
                self._waiting_data.popleft()
                self._awaiting_response.setdefault(pending.payload.id, deque()).append(pending)

    def _write_response(self, payload: ResponsePayload, time_fs: int) -> None:
        queue = self._awaiting_response.get(payload.id)
        if not queue:
            waiting = [p for p in self._waiting_data if p.payload.id == payload.id]
            reason = (
                f"before the last write data beat of the {waiting[0].describe()}"
                if waiting
                else "without an outstanding write with that ID"
            )
            self._violation(
                Axi4CheckId.UNEXPECTED_RESP,
                f"write response BID {payload.id} BRESP {Response(payload.resp).name} at {time_fs} fs {reason}",
                time_fs,
            )
            return
        pending = queue.popleft()
        if not queue:
            del self._awaiting_response[payload.id]
        self._check_exokay(pending, payload.resp, time_fs)
        self._finish(pending, Response(payload.resp), payload.user, time_fs)

    def _read_data(self, payload: ReadDataPayload, time_fs: int) -> None:
        queue = self._reads.get(payload.id)
        if not queue:
            self._violation(
                Axi4CheckId.UNEXPECTED_RESP,
                f"read data RID {payload.id} at {time_fs} fs without an outstanding read with that ID",
                time_fs,
            )
            return
        pending = queue[0]
        index = len(pending.beats)
        lanes = pending.lanes[index]
        mask = lane_mask(lanes)
        beat = Axi4Beat(
            index,
            pending.address[index],
            lanes,
            payload.data,
            mask,
            payload.last,
            payload.user,
            Response(payload.resp),
            time_fs,
        )
        pending.beats.append(beat)
        last = index == pending.payload.len
        if payload.last != last:
            self._violation(
                Axi4CheckId.RLAST,
                f"RLAST is {int(payload.last)} on beat {index} of {pending.payload.len + 1} of the {pending.describe()}"
                f" at {time_fs} fs",
                time_fs,
            )
        if payload.lane_metavalues & mask:
            self._violation(
                Axi4CheckId.METAVALUE,
                f"metavalue on RDATA lanes 0x{payload.lane_metavalues & mask:X} of beat {index} of the"
                f" {pending.describe()} at {time_fs} fs",
                time_fs,
            )
        self._check_exokay(pending, payload.resp, time_fs)
        if last:
            queue.popleft()
            if not queue:
                del self._reads[payload.id]
            responses = [b.resp for b in pending.beats if b.resp is not None]
            errors = [r for r in responses if r not in (Response.OKAY, Response.EXOKAY)]
            self._finish(pending, errors[0] if errors else responses[-1], 0, time_fs)

    def _check_exokay(self, pending: _Pending, resp: int, time_fs: int) -> None:
        if resp == Response.EXOKAY and not pending.payload.lock:
            self._violation(
                Axi4CheckId.EXCL,
                f"EXOKAY response at {time_fs} fs to the {pending.describe()}, which is not an exclusive access",
                time_fs,
            )

    def _finish(self, pending: _Pending, resp: Response, response_user: int, time_fs: int) -> None:
        p = pending.payload
        index = self._counts[pending.direction]
        self._counts[pending.direction] = index + 1
        self._on_transaction(
            Axi4Transaction(
                index=index,
                direction=pending.direction,
                id=p.id,
                address=p.address,
                len=p.len,
                size=p.size,
                burst=BurstType(p.burst),
                lock=p.lock,
                cache=p.cache,
                prot=p.prot,
                qos=p.qos,
                region=p.region,
                user=p.user,
                beats=tuple(pending.beats),
                resp=resp,
                response_user=response_user,
                data_bytes=self.config.data_bytes,
                address_fs=pending.time_fs,
                first_data_fs=pending.beats[0].time_fs,
                last_data_fs=pending.beats[-1].time_fs,
                response_fs=time_fs,
            )
        )
