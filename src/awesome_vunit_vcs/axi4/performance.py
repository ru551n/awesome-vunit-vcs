# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Performance statistics of an AXI4 interface, independent of the protocol checker.

Definitions
-----------
* observation window: from the first sample to the latest time the monitor knows
* cycles: the window divided by the clock period, plus one
* bytes: the bytes a transaction moves, strobed bytes of a write and the byte lanes of a read
* bandwidth: bytes * 8 / window, in bit/s
* channel utilization: handshakes / cycles; backpressure: stall cycles (VALID 1, READY 0) / (stall
  cycles + handshakes)
* latencies, in clock cycles between handshakes: ``address_to_first_data`` and
  ``address_to_last_data`` for both directions (negative for a write whose data came before its
  address), ``address_to_response`` (AW to B) and ``data_to_response`` (last W to B) for writes
* outstanding: transactions whose address handshake came and that are not complete; the mean is
  weighted by time over the window
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from .bus import Axi4Sample, Channel
from .transaction import Axi4Transaction, Direction, Response

__all__ = [
    "Axi4PerformanceMonitor",
    "Axi4Statistics",
    "ChannelStatistics",
    "DirectionStatistics",
    "Distribution",
]

FS_PER_SECOND = 10**15


def _bucket(value: int) -> str:
    if value < 0:
        return "<0"
    if value < 2:
        return str(value)
    low = 1 << (value.bit_length() - 1)
    return f"{low}-{2 * low - 1}"


def _bucket_key(label: str) -> int:
    return -1 if label == "<0" else int(label.split("-")[0])


@dataclass(frozen=True, slots=True)
class Distribution:
    """
    Summary of a series of integers, such as latencies in clock cycles. The values are None while the count
    is 0. Percentiles are nearest-rank. The histogram has power-of-2 buckets (``"0"``, ``"1"``, ``"2-3"``,
    ``"4-7"``, ...; ``"<0"`` for negative values), empty buckets left out.
    """

    count: int = 0
    minimum: int | None = None
    maximum: int | None = None
    mean: float | None = None
    p50: int | None = None
    p90: int | None = None
    p99: int | None = None
    histogram: tuple[tuple[str, int], ...] = ()

    def describe(self, unit: str = "cycles") -> str:
        """One line: minimum, maximum, mean and percentiles."""
        if not self.count:
            return "none"
        return (
            f"min={self.minimum} max={self.maximum} mean={self.mean:.1f} p50={self.p50} p90={self.p90}"
            f" p99={self.p99} {unit} (n={self.count})"
        )


class _Series:
    __slots__ = ("values",)

    def __init__(self) -> None:
        self.values: Counter[int] = Counter()

    def add(self, value: int) -> None:
        self.values[value] += 1

    def distribution(self) -> Distribution:
        count = sum(self.values.values())
        if not count:
            return Distribution()
        ordered = sorted(self.values.items())

        def percentile(percent: int) -> int:
            rank = max(1, -(-percent * count // 100))
            seen = 0
            for value, number in ordered:
                seen += number
                if seen >= rank:
                    return value
            return ordered[-1][0]

        buckets: Counter[str] = Counter()
        for value, number in ordered:
            buckets[_bucket(value)] += number
        return Distribution(
            count=count,
            minimum=ordered[0][0],
            maximum=ordered[-1][0],
            mean=sum(value * number for value, number in ordered) / count,
            p50=percentile(50),
            p90=percentile(90),
            p99=percentile(99),
            histogram=tuple(sorted(buckets.items(), key=lambda item: _bucket_key(item[0]))),
        )


@dataclass(frozen=True, slots=True)
class ChannelStatistics:
    """
    The handshakes and backpressure of one channel.

    Attributes:
        handshakes: Cycles with VALID and READY 1.
        stall_cycles: Cycles with VALID 1 and READY 0.
        utilization: handshakes / cycles of the window, None without a window.
        backpressure: stall_cycles / (stall_cycles + handshakes), None when both are 0.
    """

    handshakes: int = 0
    stall_cycles: int = 0
    utilization: float | None = None
    backpressure: float | None = None


@dataclass(frozen=True, slots=True)
class DirectionStatistics:
    """
    The transactions of one direction, or of one ID in one direction.

    Attributes:
        transactions: Transactions completed.
        beats: Their data beats.
        bytes: The bytes they moved, see the module definitions.
        bandwidth_bps: bytes * 8 / window in bit/s, None without a window.
        responses: The number of each response, ``(name, count)`` for OKAY, EXOKAY, SLVERR and DECERR.
        address_to_first_data: Cycles from the address handshake to the first data handshake.
        address_to_last_data: Cycles from the address handshake to the last data handshake.
        address_to_response: Cycles from AW to B; empty for reads.
        data_to_response: Cycles from the last W beat to B; empty for reads.
        outstanding_max: The most transactions outstanding at once.
        outstanding_mean: The time weighted mean of the outstanding transactions, None without a window.
        burst_lengths: ``(beats, transactions)`` by burst length.
        burst_sizes: ``(bytes per beat, transactions)`` by AxSIZE.
        burst_types: ``(name, transactions)`` by AxBURST.
    """

    transactions: int = 0
    beats: int = 0
    bytes: int = 0
    bandwidth_bps: float | None = None
    responses: tuple[tuple[str, int], ...] = ()
    address_to_first_data: Distribution = field(default_factory=Distribution)
    address_to_last_data: Distribution = field(default_factory=Distribution)
    address_to_response: Distribution = field(default_factory=Distribution)
    data_to_response: Distribution = field(default_factory=Distribution)
    outstanding_max: int = 0
    outstanding_mean: float | None = None
    burst_lengths: tuple[tuple[int, int], ...] = ()
    burst_sizes: tuple[tuple[int, int], ...] = ()
    burst_types: tuple[tuple[str, int], ...] = ()


class _DirectionAccumulator:
    def __init__(self, start_fs: int) -> None:
        self.transactions = 0
        self.beats = 0
        self.bytes = 0
        self.responses: Counter[Response] = Counter()
        self.first_data = _Series()
        self.last_data = _Series()
        self.response = _Series()
        self.data_response = _Series()
        self.lengths: Counter[int] = Counter()
        self.sizes: Counter[int] = Counter()
        self.types: Counter[str] = Counter()
        self.outstanding = 0
        self.outstanding_max = 0
        self.area = 0
        self.changed_fs = start_fs

    def transaction(self, transaction: Axi4Transaction, period_fs: int) -> None:
        t = transaction
        self.transactions += 1
        self.beats += len(t.beats)
        self.bytes += len(t.transferred_bytes())
        self.responses[t.resp] += 1
        self.first_data.add(round((t.first_data_fs - t.address_fs) / period_fs))
        self.last_data.add(round((t.last_data_fs - t.address_fs) / period_fs))
        if t.is_write:
            self.response.add(round((t.response_fs - t.address_fs) / period_fs))
            self.data_response.add(round((t.response_fs - t.last_data_fs) / period_fs))
        self.lengths[t.len + 1] += 1
        self.sizes[t.number_bytes] += 1
        self.types[t.burst.name] += 1

    def set_outstanding(self, count: int, time_fs: int) -> None:
        self.area += self.outstanding * max(0, time_fs - self.changed_fs)
        self.changed_fs = time_fs
        self.outstanding = count
        self.outstanding_max = max(self.outstanding_max, count)

    def statistics(self, first_fs: int | None, now_fs: int) -> DirectionStatistics:
        window = now_fs - first_fs if first_fs is not None else 0
        area = self.area + self.outstanding * max(0, now_fs - self.changed_fs)
        return DirectionStatistics(
            transactions=self.transactions,
            beats=self.beats,
            bytes=self.bytes,
            bandwidth_bps=self.bytes * 8 * FS_PER_SECOND / window if window > 0 else None,
            responses=tuple((response.name, self.responses[response]) for response in Response),
            address_to_first_data=self.first_data.distribution(),
            address_to_last_data=self.last_data.distribution(),
            address_to_response=self.response.distribution(),
            data_to_response=self.data_response.distribution(),
            outstanding_max=self.outstanding_max,
            outstanding_mean=area / window if window > 0 else None,
            burst_lengths=tuple(sorted(self.lengths.items())),
            burst_sizes=tuple(sorted(self.sizes.items())),
            burst_types=tuple(sorted(self.types.items())),
        )


@dataclass(frozen=True)
class Axi4Statistics:
    """
    A snapshot of the performance of an interface, see the module definitions.

    Attributes:
        write: The writes.
        read: The reads.
        channels: The statistics of each channel, keyed by its name (``"AW"``, ``"W"``, ``"B"``, ``"AR"``,
            ``"R"``).
        write_by_id: The writes of each AWID; empty unless the monitor keeps statistics per ID.
        read_by_id: The reads of each ARID; empty unless the monitor keeps statistics per ID.
        clock_period_fs: The clock period, 0 before the second rising edge of ACLK.
        window_fs: The observation window.
        cycles: The clock cycles of the window.
    """

    write: DirectionStatistics
    read: DirectionStatistics
    channels: dict[str, ChannelStatistics]
    write_by_id: dict[int, DirectionStatistics]
    read_by_id: dict[int, DirectionStatistics]
    clock_period_fs: int
    window_fs: int
    cycles: int

    def summary(self, name: str = "AXI4") -> str:
        """A human-readable multi-line summary for a simulation log."""
        lines = [
            f"{name}: {self.cycles} cycles of {self.clock_period_fs} fs, window {self.window_fs} fs",
        ]

        def direction(label: str, stats: DirectionStatistics, indent: str) -> None:
            bandwidth = "n/a" if stats.bandwidth_bps is None else f"{stats.bandwidth_bps / 1e6:.1f} Mbit/s"
            mean = "n/a" if stats.outstanding_mean is None else f"{stats.outstanding_mean:.2f}"
            lines.append(
                f"{indent}{label}: {stats.transactions} transactions, {stats.beats} beats, {stats.bytes} bytes,"
                f" {bandwidth}, outstanding max {stats.outstanding_max} mean {mean}"
            )
            lines.append(f"{indent}  responses: " + " ".join(f"{n}={c}" for n, c in stats.responses))
            latencies = [("address to first data", stats.address_to_first_data)]
            latencies.append(("address to last data", stats.address_to_last_data))
            if label.startswith("write"):
                latencies += [
                    ("address to response", stats.address_to_response),
                    ("last data to response", stats.data_to_response),
                ]
            for what, distribution in latencies:
                lines.append(f"{indent}  {what}: {distribution.describe()}")
                if distribution.histogram:
                    lines.append(f"{indent}    histogram: " + " ".join(f"{b}={c}" for b, c in distribution.histogram))
            lines.append(
                f"{indent}  burst lengths: " + (" ".join(f"{b}={c}" for b, c in stats.burst_lengths) or "none")
            )
            lines.append(f"{indent}  burst sizes: " + (" ".join(f"{b}={c}" for b, c in stats.burst_sizes) or "none"))
            lines.append(f"{indent}  burst types: " + (" ".join(f"{b}={c}" for b, c in stats.burst_types) or "none"))

        direction("write", self.write, "  ")
        direction("read", self.read, "  ")
        for channel, channel_stats in self.channels.items():
            utilization = "n/a" if channel_stats.utilization is None else f"{100 * channel_stats.utilization:.1f}%"
            backpressure = "n/a" if channel_stats.backpressure is None else f"{100 * channel_stats.backpressure:.1f}%"
            lines.append(
                f"  {channel}: {channel_stats.handshakes} handshakes, {channel_stats.stall_cycles} stall cycles,"
                f" utilization {utilization}, backpressure {backpressure}"
            )
        for label, by_id in (("write", self.write_by_id), ("read", self.read_by_id)):
            for id_, stats in sorted(by_id.items()):
                direction(f"{label} ID {id_}", stats, "  ")
        return "\n".join(lines)


class Axi4PerformanceMonitor:
    """
    Count what an AXI4 interface does. :class:`~awesome_vunit_vcs.axi4.monitor.Axi4Monitor` feeds it; the
    methods below are for other feeds.

    Args:
        per_id: Also keep the statistics of each ID.
    """

    def __init__(self, per_id: bool = False) -> None:
        self.per_id = per_id
        #: The clock period in fs, 0 while unknown
        self.period_fs = 0
        self.clear()

    def clear(self) -> None:
        """Set everything to 0, keeping the clock period."""
        self._first_fs: int | None = None
        self._now_fs = 0
        self._handshakes: Counter[Channel] = Counter()
        self._stalls: Counter[Channel] = Counter()
        self._directions = {direction: _DirectionAccumulator(0) for direction in Direction}
        self._by_id: dict[tuple[Direction, int], _DirectionAccumulator] = {}

    @property
    def now_fs(self) -> int:
        """The latest time the monitor knows."""
        return self._now_fs

    def advance(self, time_fs: int) -> None:
        """The monitor knows the bus up to ``time_fs``."""
        if self._first_fs is None:
            self._first_fs = time_fs
            for accumulator in self._directions.values():
                accumulator.changed_fs = time_fs
        self._now_fs = max(self._now_fs, time_fs)

    def sample(self, sample: Axi4Sample) -> None:
        """Count the handshake or stall of a channel sample."""
        self.advance(sample.time_fs)
        if sample.handshake:
            self._handshakes[sample.channel] += 1
        elif sample.stall:
            self._stalls[sample.channel] += 1

    def transaction(self, transaction: Axi4Transaction) -> None:
        """Count a complete transaction."""
        self.advance(transaction.response_fs)
        period_fs = self.period_fs or 1
        self._directions[transaction.direction].transaction(transaction, period_fs)
        if self.per_id:
            self._id_accumulator(transaction.direction, transaction.id).transaction(transaction, period_fs)

    def outstanding(self, direction: Direction, count: int, time_fs: int, by_id: dict[int, int] | None = None) -> None:
        """
        The outstanding transactions of a direction changed.

        Args:
            direction: Write or read.
            count: The transactions outstanding from ``time_fs`` on.
            time_fs: The time of the change.
            by_id: The outstanding transactions per ID, with every ID not in it at 0; used with ``per_id``.
        """
        self.advance(time_fs)
        self._directions[direction].set_outstanding(count, time_fs)
        if self.per_id and by_id is not None:
            for (key_direction, id_), accumulator in self._by_id.items():
                if key_direction == direction and id_ not in by_id and accumulator.outstanding:
                    accumulator.set_outstanding(0, time_fs)
            for id_, id_count in by_id.items():
                accumulator = self._id_accumulator(direction, id_)
                if accumulator.outstanding != id_count:
                    accumulator.set_outstanding(id_count, time_fs)

    def _id_accumulator(self, direction: Direction, id_: int) -> _DirectionAccumulator:
        key = (direction, id_)
        if key not in self._by_id:
            self._by_id[key] = _DirectionAccumulator(self._now_fs)
        return self._by_id[key]

    def statistics(self) -> Axi4Statistics:
        """A snapshot of the statistics."""
        first, now = self._first_fs, self._now_fs
        window = now - first if first is not None else 0
        cycles = window // self.period_fs + 1 if self.period_fs and first is not None else 0
        channels = {}
        for channel in Channel:
            handshakes, stalls = self._handshakes[channel], self._stalls[channel]
            channels[channel.name] = ChannelStatistics(
                handshakes=handshakes,
                stall_cycles=stalls,
                utilization=handshakes / cycles if cycles else None,
                backpressure=stalls / (stalls + handshakes) if stalls + handshakes else None,
            )
        by_id = {
            direction: {
                id_: accumulator.statistics(first, now)
                for (key_direction, id_), accumulator in self._by_id.items()
                if key_direction == direction
            }
            for direction in Direction
        }
        return Axi4Statistics(
            write=self._directions[Direction.WRITE].statistics(first, now),
            read=self._directions[Direction.READ].statistics(first, now),
            channels=channels,
            write_by_id=by_id[Direction.WRITE],
            read_by_id=by_id[Direction.READ],
            clock_period_fs=self.period_fs,
            window_fs=window,
            cycles=cycles,
        )
