# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The I2C monitor: transfers and statistics from SCL and SDA samples, without a simulator.

::

    from awesome_vunit_vcs.i2c import I2cMonitor

    monitor = I2cMonitor()
    monitor.transfers.subscribe(print)
    monitor.feed(words, times_fs)
"""

from __future__ import annotations

import statistics
from collections import Counter
from collections.abc import Callable, Iterable
from dataclasses import dataclass

from ..common.events import Publisher
from .bus import BusDecoder, BusEvent, EventKind
from .transfer import I2cTransfer, TransferAssembler

__all__ = ["I2cMonitor", "I2cStatistics"]


@dataclass(frozen=True)
class I2cStatistics:
    """
    What a monitor observed.

    Attributes:
        transactions: Transactions started, START to STOP.
        transfers: Transfers completed.
        reads: Transfers with the R/W bit R.
        writes: Transfers with the R/W bit W.
        repeated_starts: Transfers started with a repeated START.
        data_bytes: Data bytes, not counting address bytes.
        nacks: Bytes not acknowledged, address bytes included.
        address_nacks: Transfers whose address was not acknowledged.
        metavalues: Samples with a metavalue on SCL or SDA.
        scl_frequency_hz: 1 / the median time between rising SCL edges inside transactions, 0
            without a clock.
        max_scl_frequency_hz: 1 / the shortest of those times, 0 without a clock.
        busy_fs: Time inside transactions, START to STOP.
        observed_fs: Time from the first sample to the latest time the monitor knows.
        stretch_fs: SCL low time beyond the usual low period: the sum, over the low periods inside
            transactions longer than 1.5 times their median, of the time beyond the median.
    """

    transactions: int
    transfers: int
    reads: int
    writes: int
    repeated_starts: int
    data_bytes: int
    nacks: int
    address_nacks: int
    metavalues: int
    scl_frequency_hz: int
    max_scl_frequency_hz: int
    busy_fs: int
    observed_fs: int
    stretch_fs: int

    @property
    def utilization(self) -> float:
        """The share of the observed time the bus was busy, 0 to 1."""
        return self.busy_fs / self.observed_fs if self.observed_fs else 0.0


def _median(counter: Counter[int]) -> float:
    return float(statistics.median(counter.elements())) if counter else 0.0


class I2cMonitor:
    """
    Reconstruct transfers from SCL and SDA samples and count what happens on the bus.

    Args:
        on_subscriber_error: Called with the subscriber and the exception when a subscriber of
            ``transfers`` raises. Without it the exception propagates from :meth:`feed`.

    Attributes:
        transfers: Publishes every :class:`~awesome_vunit_vcs.i2c.transfer.I2cTransfer` when it ends.
        metavalues: Publishes every metavalue :class:`~awesome_vunit_vcs.i2c.bus.BusEvent`.
    """

    def __init__(self, on_subscriber_error: Callable[[Callable[..., None], BaseException], None] | None = None) -> None:
        self.transfers: Publisher[I2cTransfer] = Publisher(on_subscriber_error)
        self.metavalues: Publisher[BusEvent] = Publisher(on_subscriber_error)
        self._decoder = BusDecoder()
        self._assembler = TransferAssembler(self._transfer)
        self._transaction_start: int | None = None
        self._last_rise: int | None = None
        self._last_fall: int | None = None
        self.clear_statistics()

    @property
    def in_transaction(self) -> bool:
        """A START was seen and no STOP after it."""
        return self._assembler.in_transaction

    def reset(self) -> None:
        """Drop a transaction in progress; statistics are kept."""
        self._decoder.reset()
        self._assembler.reset()
        self._transaction_start = None
        self._last_rise = None
        self._last_fall = None

    def clear_statistics(self) -> None:
        """Set the statistics to 0."""
        self._first_fs: int | None = None
        self._last_fs = 0
        self._busy_fs = 0
        self._transaction_start = None
        self._last_rise = None
        self._last_fall = None
        self._periods: Counter[int] = Counter()
        self._lows: Counter[int] = Counter()
        self._counts: Counter[str] = Counter()
        self._transaction_base = self._assembler.transaction_count

    def feed(self, words: Iterable[int], times_fs: Iterable[int]) -> None:
        """Decode a batch of sample words with their times in fs."""
        for word, time_fs in zip(words, times_fs, strict=True):
            time_fs = int(time_fs)
            if self._first_fs is None:
                self._first_fs = time_fs
            self._last_fs = max(self._last_fs, time_fs)
            for event in self._decoder.decode(int(word), time_fs):
                self._event(event)

    def advance(self, now_fs: int) -> None:
        """The simulation reached ``now_fs``: it counts as observed time."""
        if self._first_fs is None:
            self._first_fs = now_fs
        self._last_fs = max(self._last_fs, now_fs)

    def _event(self, event: BusEvent) -> None:
        kind = event.kind
        if kind is EventKind.METAVALUE:
            self._counts["metavalues"] += 1
            self.metavalues.publish(event)
            return
        in_transaction = self._assembler.in_transaction
        if kind is EventKind.RISE and in_transaction:
            if self._last_rise is not None:
                self._periods[event.time_fs - self._last_rise] += 1
            if self._last_fall is not None:
                self._lows[event.time_fs - self._last_fall] += 1
            self._last_rise = event.time_fs
        elif kind is EventKind.FALL and in_transaction:
            self._last_fall = event.time_fs
        elif kind is EventKind.START:
            # A repeated START interrupts the clock; periods across it are not clock periods
            self._last_rise = None
            self._last_fall = None
            if not in_transaction:
                self._transaction_start = event.time_fs
        elif kind is EventKind.STOP:
            self._last_rise = None
            self._last_fall = None
            if self._transaction_start is not None:
                self._busy_fs += event.time_fs - self._transaction_start
                self._transaction_start = None
        self._assembler.feed(event)

    def _transfer(self, transfer: I2cTransfer) -> None:
        counts = self._counts
        counts["transfers"] += 1
        counts["reads" if transfer.read else "writes"] += 1
        counts["repeated_starts"] += transfer.repeated_start
        counts["data_bytes"] += len(transfer.data)
        address_nack = transfer.address is not None and not transfer.address_ack
        counts["nacks"] += transfer.acks.count(False) + address_nack
        counts["address_nacks"] += address_nack
        self.transfers.publish(transfer)

    @property
    def transfer_count(self) -> int:
        """Transfers completed since the monitor was created."""
        return self._assembler.transfer_count

    def statistics(self) -> I2cStatistics:
        """The statistics since they were last cleared."""
        busy = self._busy_fs
        if self._transaction_start is not None:
            busy += max(0, self._last_fs - self._transaction_start)
        median_period = _median(self._periods)
        median_low = _median(self._lows)
        stretch = sum(int((low - median_low) * count) for low, count in self._lows.items() if low > 1.5 * median_low)
        counts = self._counts
        return I2cStatistics(
            transactions=self._assembler.transaction_count - self._transaction_base,
            transfers=counts["transfers"],
            reads=counts["reads"],
            writes=counts["writes"],
            repeated_starts=counts["repeated_starts"],
            data_bytes=counts["data_bytes"],
            nacks=counts["nacks"],
            address_nacks=counts["address_nacks"],
            metavalues=counts["metavalues"],
            scl_frequency_hz=round(10**15 / median_period) if median_period else 0,
            max_scl_frequency_hz=round(10**15 / min(self._periods)) if self._periods else 0,
            busy_fs=busy,
            observed_fs=self._last_fs - self._first_fs if self._first_fs is not None else 0,
            stretch_fs=stretch,
        )
