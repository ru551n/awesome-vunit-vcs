# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The AXI4 monitor: transactions, statistics and a shadow memory from sample words, without a simulator.

::

    from awesome_vunit_vcs.axi4 import Axi4Config, Axi4Monitor

    monitor = Axi4Monitor(Axi4Config(data_width=64, id_width=4))
    monitor.transactions.subscribe(print)
    monitor.feed(words, times_fs)
"""

from __future__ import annotations

from collections.abc import Callable, Iterable

from ..common.events import Publisher
from .bus import Axi4Config, Axi4Control, Axi4Sample, Channel, ControlKind, SampleDecoder
from .checks import Axi4CheckId, Axi4Violation
from .memory import ShadowMemory
from .performance import Axi4PerformanceMonitor, Axi4Statistics
from .transaction import Axi4Transaction, Direction, TransactionTracker

__all__ = ["Axi4Monitor"]


class Axi4Monitor:
    """
    Reconstruct the transactions of an AXI4 or AXI4-Lite interface and measure its performance.

    Args:
        config: The widths of the interface, 32-bit data and address without IDs by default.
        shadow_memory: Check every read against the data written before it, see
            :class:`~awesome_vunit_vcs.axi4.memory.ShadowMemory`; mismatches are published on
            ``scoreboard`` as ``AXI4_SCOREBOARD`` violations.
        per_id_statistics: Also keep the statistics of each ID.
        on_subscriber_error: Called with the subscriber and the exception when a subscriber raises.
            Without it the exception propagates from :meth:`feed`.

    Attributes:
        transactions: Publishes every :class:`~awesome_vunit_vcs.axi4.transaction.Axi4Transaction` when
            it completes.
        samples: Publishes every :class:`~awesome_vunit_vcs.axi4.bus.Axi4Sample` outside reset.
        metavalues: Publishes every sample or control record with a metavalue on VALID, READY,
            ARESETn, or on the payload of a channel while VALID is 1 (data lanes not included).
        scoreboard: Publishes the ``AXI4_SCOREBOARD`` violations of the shadow memory.
        memory: The shadow memory, None without ``shadow_memory``.
        performance: The :class:`~awesome_vunit_vcs.axi4.performance.Axi4PerformanceMonitor`.
    """

    def __init__(
        self,
        config: Axi4Config | None = None,
        shadow_memory: bool = False,
        per_id_statistics: bool = False,
        on_subscriber_error: Callable[[Callable[..., None], BaseException], None] | None = None,
    ) -> None:
        self.config = config or Axi4Config()
        self.transactions: Publisher[Axi4Transaction] = Publisher(on_subscriber_error)
        self.samples: Publisher[Axi4Sample] = Publisher(on_subscriber_error)
        self.metavalues: Publisher[Axi4Sample | Axi4Control] = Publisher(on_subscriber_error)
        self.scoreboard: Publisher[Axi4Violation] = Publisher(on_subscriber_error)
        self.memory = ShadowMemory() if shadow_memory else None
        self.performance = Axi4PerformanceMonitor(per_id_statistics)
        self._decoder = SampleDecoder(self.config)
        self._tracker = TransactionTracker(self.config, self._transaction)
        self._in_reset = False
        self._counts = {Direction.WRITE: 0, Direction.READ: 0}

    @property
    def transaction_count(self) -> int:
        """Transactions completed, both directions."""
        return sum(self._counts.values())

    def outstanding(self, direction: Direction) -> int:
        """The outstanding transactions of a direction."""
        return self._tracker.outstanding(direction)

    def reset(self) -> None:
        """Drop the outstanding transactions; statistics and the shadow memory are kept."""
        self._decoder.reset()
        self._tracker.reset()
        self._outstanding_changed(self.performance.now_fs)

    def clear_statistics(self) -> None:
        """Set the statistics to 0."""
        self.performance.clear()

    def advance(self, now_fs: int) -> None:
        """The bus was idle up to ``now_fs``; the statistics window extends to it."""
        self.performance.advance(now_fs)

    def statistics(self) -> Axi4Statistics:
        """A snapshot of the performance statistics."""
        return self.performance.statistics()

    def feed(self, words: Iterable[int], times: Iterable[int]) -> None:
        """Process sample words with their times in fs."""
        for record in self._decoder.decode(list(words), list(times)):
            if isinstance(record, Axi4Control):
                self._control(record)
            else:
                self._sample(record)

    def _control(self, control: Axi4Control) -> None:
        self.performance.advance(control.time_fs)
        if control.resetn_metavalue:
            self.metavalues.publish(control)
        if control.kind == ControlKind.PERIOD:
            self.performance.period_fs = control.period_fs
        elif control.kind == ControlKind.RESET:
            if control.in_reset and not self._in_reset:
                self._tracker.reset()
                self._outstanding_changed(control.time_fs)
            self._in_reset = control.in_reset

    def _sample(self, sample: Axi4Sample) -> None:
        if sample.in_reset:
            self.performance.advance(sample.time_fs)
            return
        if sample.valid_metavalue or sample.ready_metavalue or (sample.valid and sample.payload_metavalue):
            self.metavalues.publish(sample)
        self.performance.sample(sample)
        self.samples.publish(sample)
        if sample.handshake:
            self._tracker.handshake(sample)
            if sample.channel != Channel.W:
                self._outstanding_changed(sample.time_fs)

    def _outstanding_changed(self, time_fs: int) -> None:
        for direction in Direction:
            count = self._tracker.outstanding(direction)
            by_id = self._tracker.outstanding_ids(direction) if self.performance.per_id else None
            self.performance.outstanding(direction, count, time_fs, by_id)

    def _transaction(self, transaction: Axi4Transaction) -> None:
        self._counts[transaction.direction] += 1
        self.performance.transaction(transaction)
        if self.memory is not None:
            if transaction.is_write:
                self.memory.commit(transaction)
            else:
                differences = self.memory.check(transaction)
                if differences:
                    shown = "; ".join(differences[:8])
                    more = f"; and {len(differences) - 8} more" if len(differences) > 8 else ""
                    self.scoreboard.publish(
                        Axi4Violation(
                            Axi4CheckId.SCOREBOARD,
                            f"{Axi4CheckId.SCOREBOARD.value}: the {transaction.describe()} with its last beat at"
                            f" {transaction.last_data_fs} fs differs from the shadow memory: {shown}{more}",
                            transaction.last_data_fs,
                        )
                    )
        self.transactions.publish(transaction)
