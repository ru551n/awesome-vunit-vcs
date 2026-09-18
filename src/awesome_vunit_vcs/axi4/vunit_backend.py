# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Backends of the AXI4 VHDL verification components.

Each VC creates one backend in its own Python session, as the object ``vc``. VHDL owns the pins and
simulation time and calls these methods with the typed arguments of the bridge: a ``time`` is what
``arg_time`` sends, decoded with :func:`~awesome_vunit_vcs.common.vunit_bridge.decode_time_fs`, and a
``text`` what ``arg_text`` sends; Python callers pass fs and ``str`` instead. No method raises into the
bridge, see :class:`~awesome_vunit_vcs.common.backend.VcBackend`.

::

    Axi4MonitorBackend(name: text, data_width, address_width, id_width, awuser_width, wuser_width,
                       buser_width, aruser_width, ruser_width, lite, shadow_memory, per_id_statistics,
                       report_metavalues)
    push(samples, base_time, delta_unit)        -> num_reports
    set_publish(enabled); take_published()      -> transactions
    pop_transaction()                           -> transaction or empty
    check_transaction(write, address_hi, address_lo, data, id, resp, message: text)
    statistics_values(now: time)                -> the fields of axi4_statistics_t
    statistics_summary(now: time)               -> text
    reset(clear_statistics); finish()           -> num_reports

    Axi4ProtocolCheckerBackend(name: text, <the widths and lite as above>, timeout_cycles)
    push(samples, base_time, delta_unit)        -> num_reports
    set_check_enabled(check: text, enabled); check_count(check: text); reset(); finish(now: time)

A transaction travels to VHDL as ``[flags, id, address_hi, address_lo, len, size, burst, cache, prot,
qos, region, resp, address time, first data time, last data time, response time, n, n bytes]``:
``flags`` bit 0 write, bit 1 exclusive; ``address_lo`` the low 32 bits as a signed integer; each time
``hi, lo`` as :func:`~awesome_vunit_vcs.common.vunit_bridge.split_time` gives it; each byte
``value | written << 8``.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Sequence

import numpy as np
import numpy.typing as npt

from ..common.backend import VHDL_INTEGER_MAX, SampleBackend, int32_array
from ..common.reports import Severity
from ..common.vunit_bridge import decode_text, decode_time_fs, split_time
from .bus import Axi4Config, Axi4Control, Axi4Sample
from .checker import Axi4ProtocolChecker
from .checks import Axi4CheckId, Axi4Violation
from .monitor import Axi4Monitor
from .transaction import Axi4Transaction, Direction, Response

__all__ = ["Axi4MonitorBackend", "Axi4ProtocolCheckerBackend"]


def _signed32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >= 1 << 31 else value


def _flat(transaction: Axi4Transaction) -> list[int]:
    t = transaction
    data = t.data()
    strobes = t.strobes()
    return [
        int(t.is_write) | int(t.exclusive) << 1,
        t.id,
        _signed32(t.address >> 32),
        _signed32(t.address),
        t.len,
        t.size,
        int(t.burst),
        t.cache,
        t.prot,
        t.qos,
        t.region,
        int(t.resp),
        *split_time(t.address_fs),
        *split_time(t.first_data_fs),
        *split_time(t.last_data_fs),
        *split_time(t.response_fs),
        len(data),
        *(value | int(strobe) << 8 for value, strobe in zip(data, strobes, strict=True)),
    ]


def _config(
    data_width: int,
    address_width: int,
    id_width: int,
    awuser_width: int,
    wuser_width: int,
    buser_width: int,
    aruser_width: int,
    ruser_width: int,
    lite: bool,
) -> Axi4Config:
    return Axi4Config(
        data_width=data_width,
        address_width=address_width,
        id_width=id_width,
        awuser_width=awuser_width,
        wuser_width=wuser_width,
        buser_width=buser_width,
        aruser_width=aruser_width,
        ruser_width=ruser_width,
        lite=bool(lite),
    )


class _Expected:
    __slots__ = ("address", "data", "id", "message", "resp")

    def __init__(self, address: int, data: bytes, id_: int, resp: int, message: str) -> None:
        self.address = address
        self.data = data
        self.id = id_
        self.resp = resp
        self.message = message


class Axi4MonitorBackend(SampleBackend):
    """
    The Python object behind a VHDL AXI4 monitor.

    Args:
        name: The name of the monitor, used in messages.
        data_width: The width of the data bus, see :class:`~awesome_vunit_vcs.axi4.bus.Axi4Config`.
        address_width: The width of the addresses.
        id_width: The width of the IDs.
        awuser_width: The width of AWUSER.
        wuser_width: The width of WUSER.
        buser_width: The width of BUSER.
        aruser_width: The width of ARUSER.
        ruser_width: The width of RUSER.
        lite: The interface is AXI4-Lite.
        shadow_memory: Check reads against the data written before them (``AXI4_SCOREBOARD``).
        per_id_statistics: Keep the statistics of each ID too.
        report_metavalues: Report metavalues as check failures (``AXI4_METAVALUE``); a monitor with a
            protocol checker leaves that to the checker.
        keep_transactions: The transactions kept for :meth:`pop_transaction`.

    Attributes:
        monitor: The :class:`~awesome_vunit_vcs.axi4.monitor.Axi4Monitor`; subscribe to its
            ``transactions`` to extend the monitor from Python.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        data_width: int = 32,
        address_width: int = 32,
        id_width: int = 0,
        awuser_width: int = 0,
        wuser_width: int = 0,
        buser_width: int = 0,
        aruser_width: int = 0,
        ruser_width: int = 0,
        lite: bool = False,
        shadow_memory: bool = False,
        per_id_statistics: bool = False,
        report_metavalues: bool = True,
        keep_transactions: int = 1024,
    ) -> None:
        super().__init__(name)
        widths = (data_width, address_width, id_width, awuser_width, wuser_width, buser_width, aruser_width)
        config = self.guard("configure", lambda: _config(*widths, ruser_width, lite), Axi4Config())
        self.monitor = Axi4Monitor(
            config,
            shadow_memory=bool(shadow_memory),
            per_id_statistics=bool(per_id_statistics),
            on_subscriber_error=self.subscriber_error,
        )
        self.monitor.transactions.subscribe(self._compare)
        self.monitor.transactions.subscribe(self._keep)
        self.monitor.scoreboard.subscribe(self._scoreboard)
        if report_metavalues:
            self.monitor.metavalues.subscribe(self._metavalue)
        #: Collect transactions for :meth:`take_published`; VHDL sets it while the monitor has subscribers
        self.publish_transactions = False
        self._published: list[Axi4Transaction] = []
        self._kept: deque[Axi4Transaction] = deque(maxlen=keep_transactions)
        self._expected: dict[Direction, deque[_Expected]] = {direction: deque() for direction in Direction}

    def feed(self, words: list[int], times: list[int]) -> None:
        """Process sample words with their times in fs."""
        self.monitor.feed(words, times)

    def _metavalue(self, record: Axi4Sample | Axi4Control) -> None:
        if isinstance(record, Axi4Control):
            where = "ARESETn"
        else:
            name = record.channel.name
            where = f"{name}VALID, {name}READY or the {name} payload"
        self.error(f"{Axi4CheckId.METAVALUE.value}: metavalue on {where} at {record.time_fs} fs")

    def _scoreboard(self, violation: Axi4Violation) -> None:
        self.reports.add(Severity.ERROR, f"{self.name}: {violation.message}")

    def _keep(self, transaction: Axi4Transaction) -> None:
        self._kept.append(transaction)
        if self.publish_transactions:
            self._published.append(transaction)

    def _compare(self, transaction: Axi4Transaction) -> None:
        queue = self._expected[transaction.direction]
        if not queue:
            return
        expected = queue.popleft()
        differences = []
        if transaction.address != expected.address:
            differences.append(f"address 0x{transaction.address:X}, expected 0x{expected.address:X}")
        if expected.id >= 0 and transaction.id != expected.id:
            differences.append(f"ID {transaction.id}, expected {expected.id}")
        if expected.resp >= 0 and transaction.resp != expected.resp:
            differences.append(f"response {transaction.resp.name}, expected {Response(expected.resp).name}")
        data, strobes = transaction.data(), transaction.strobes()
        if len(data) != len(expected.data):
            differences.append(f"{len(data)} data bytes, expected {len(expected.data)}")
        else:
            wrong = [
                f"byte {index} 0x{got:02X}, expected 0x{want:02X}"
                for index, (got, want, strobe) in enumerate(zip(data, expected.data, strobes, strict=True))
                if strobe and got != want
            ]
            if wrong:
                differences.append(
                    "data " + ", ".join(wrong[:8]) + (f" and {len(wrong) - 8} more" if len(wrong) > 8 else "")
                )
        if differences:
            prefix = f"{expected.message}: " if expected.message else ""
            self.error(
                f"{Axi4CheckId.SCOREBOARD.value}: {prefix}the {transaction.describe()} completed at"
                f" {transaction.response_fs} fs has " + "; ".join(differences)
            )

    def set_publish(self, enabled: bool) -> None:
        """Collect transactions for :meth:`take_published` or not."""
        self.publish_transactions = bool(enabled)
        if not enabled:
            self._published = []

    def take_published(self) -> npt.NDArray[np.int32]:
        """The transactions since the last call while publishing, flat for VHDL, one after the other."""
        transactions, self._published = self._published, []
        return int32_array([value for transaction in transactions for value in _flat(transaction)])

    def pop_transaction(self) -> npt.NDArray[np.int32]:
        """The oldest transaction kept, flat for VHDL (see the module), or an empty array."""
        return int32_array(_flat(self._kept.popleft()) if self._kept else [])

    def check_transaction(
        self,
        write: bool,
        address_hi: int,
        address_lo: int,
        data: Sequence[int] = (),
        id_: int = -1,
        resp: int = -1,
        message: str | Sequence[int] = "",
    ) -> None:
        """
        Queue the transaction the next one of its direction must equal.

        Args:
            write: A write, or a read.
            address_hi: The upper 32 bits of the address.
            address_lo: The lower 32 bits of the address, signed or not.
            data: The bytes of the byte lanes of every beat, see
                :meth:`~awesome_vunit_vcs.axi4.transaction.Axi4Transaction.data`; bytes a write does not
                strobe are not compared.
            id_: The ID, -1 for any.
            resp: The response, -1 for any.
            message: Starts the message of a difference.
        """
        address = (address_hi & 0xFFFFFFFF) << 32 | (address_lo & 0xFFFFFFFF)
        direction = Direction.WRITE if write else Direction.READ
        self._expected[direction].append(
            _Expected(address, bytes(int(value) & 0xFF for value in data), id_, resp, decode_text(message))
        )

    def transaction_count(self) -> int:
        """Transactions completed."""
        return self.monitor.transaction_count

    def statistics_values(self, now: int | Sequence[int]) -> npt.NDArray[np.int32]:
        """
        The fields of the VHDL ``axi4_statistics_t``, in its order, saturated at the largest VHDL integer:
        transactions, bytes, bandwidth in Mbit/s and the most outstanding, each for writes then reads; the
        minimum, maximum and mean latency in cycles of writes (AW to B) and reads (AR to the last R beat);
        the stall cycles of AW, W, B, AR and R; the SLVERR and DECERR responses; and the cycles observed.
        """

        def values() -> npt.NDArray[np.int32]:
            self.monitor.advance(decode_time_fs(now))
            stats = self.monitor.statistics()
            write, read = stats.write, stats.read
            fields: list[float | None] = [
                write.transactions,
                read.transactions,
                write.bytes,
                read.bytes,
                None if write.bandwidth_bps is None else write.bandwidth_bps / 1e6,
                None if read.bandwidth_bps is None else read.bandwidth_bps / 1e6,
                write.outstanding_max,
                read.outstanding_max,
                write.address_to_response.minimum,
                write.address_to_response.maximum,
                write.address_to_response.mean,
                read.address_to_last_data.minimum,
                read.address_to_last_data.maximum,
                read.address_to_last_data.mean,
                *(stats.channels[name].stall_cycles for name in ("AW", "W", "B", "AR", "R")),
                sum(count for name, count in (*write.responses, *read.responses) if name in ("SLVERR", "DECERR")),
                stats.cycles,
            ]
            return int32_array([min(round(value or 0), VHDL_INTEGER_MAX) for value in fields])

        return self.guard("statistics", values, int32_array([0] * 21))

    def statistics_summary(self, now: int | Sequence[int]) -> str:
        """The human-readable statistics summary."""

        def summary() -> str:
            self.monitor.advance(decode_time_fs(now))
            return self.monitor.statistics().summary(self.name)

        return self.guard("statistics_summary", summary, "")

    def reset(self, clear_statistics: bool = False) -> int:
        """Drop the outstanding, kept and expected transactions; the shadow memory is kept."""
        self.monitor.reset()
        if clear_statistics:
            self.monitor.clear_statistics()
        self._kept.clear()
        self._published = []
        for queue in self._expected.values():
            queue.clear()
        return len(self.reports)

    def finish(self) -> int:
        """At the end of the test: an expected transaction that never came is a check failure."""
        for direction, queue in self._expected.items():
            for expected in queue:
                prefix = f"{expected.message}: " if expected.message else ""
                self.error(
                    f"{Axi4CheckId.SCOREBOARD.value}: {prefix}the expected {direction.value} at"
                    f" 0x{expected.address:X} never came"
                )
            queue.clear()
        return len(self.reports)


class Axi4ProtocolCheckerBackend(SampleBackend):
    """
    The Python object behind a VHDL AXI4 protocol checker.

    Args:
        name: The name of the protocol checker, used in messages.
        data_width: The width of the data bus, see :class:`~awesome_vunit_vcs.axi4.bus.Axi4Config`.
        address_width: The width of the addresses.
        id_width: The width of the IDs.
        awuser_width: The width of AWUSER.
        wuser_width: The width of WUSER.
        buser_width: The width of BUSER.
        aruser_width: The width of ARUSER.
        ruser_width: The width of RUSER.
        lite: The interface is AXI4-Lite.
        timeout_cycles: See :class:`~awesome_vunit_vcs.axi4.checker.Axi4ProtocolChecker`.

    Attributes:
        checker: The :class:`~awesome_vunit_vcs.axi4.checker.Axi4ProtocolChecker`.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        data_width: int = 32,
        address_width: int = 32,
        id_width: int = 0,
        awuser_width: int = 0,
        wuser_width: int = 0,
        buser_width: int = 0,
        aruser_width: int = 0,
        ruser_width: int = 0,
        lite: bool = False,
        timeout_cycles: int = 0,
    ) -> None:
        super().__init__(name)
        widths = (data_width, address_width, id_width, awuser_width, wuser_width, buser_width, aruser_width)

        def create() -> Axi4ProtocolChecker:
            return Axi4ProtocolChecker(_config(*widths, ruser_width, lite), timeout_cycles)

        self.checker = self.guard("configure", create, Axi4ProtocolChecker())
        self.checker.violations.subscribe(self._violation)

    def _violation(self, violation: Axi4Violation) -> None:
        self.reports.add(Severity.ERROR, f"{self.name}: {violation.message}")

    def feed(self, words: list[int], times: list[int]) -> None:
        """Check sample words with their times in fs."""
        self.checker.feed(words, times)

    def set_check_enabled(self, check: str | Sequence[int], enabled: bool) -> int:
        """Enable or disable a check given by name."""

        def switch() -> None:
            name = decode_text(check)
            if enabled:
                self.checker.enable(name)
            else:
                self.checker.disable(name)

        self.guard("set_check_enabled", switch, None)
        return len(self.reports)

    def check_count(self, check: str | Sequence[int]) -> int:
        """Violations of a check given by name."""
        return self.guard("check_count", lambda: self.checker.count(decode_text(check)), 0)

    def reset(self) -> int:
        """Forget the bus history and set the counts to 0."""
        self.checker.reset()
        return len(self.reports)

    def finish(self, now: int | Sequence[int]) -> int:
        """At the end of the test: what timed out by ``now``."""
        self.guard("finish", lambda: self.checker.advance(decode_time_fs(now)), None)
        return len(self.reports)
