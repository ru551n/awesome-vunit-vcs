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
from typing import Any

import numpy as np
import numpy.typing as npt

from ..common.backend import VHDL_INTEGER_MAX, SampleBackend, VcBackend, int32_array
from ..common.reports import ReportQueue, Severity, encode_reports
from ..common.vunit_bridge import decode_text, decode_time_fs, split_time
from .bus import Axi4Config, Axi4Control, Axi4Sample
from .checker import Axi4ProtocolChecker
from .checks import Axi4CheckId, Axi4Violation
from .errors import Axi4ValueError
from .memory_model import Endianness, MemoryModel, Permission
from .monitor import Axi4Monitor
from .slave import Axi4Slave, SlaveBurst
from .transaction import Axi4Transaction, Direction, Response

__all__ = ["Axi4MemoryBackend", "Axi4MonitorBackend", "Axi4ProtocolCheckerBackend"]


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


class _SlavePort:
    """A slave attached to a memory backend, with its own reports and the bursts waiting for data."""

    def __init__(self, name: str, slave: Axi4Slave) -> None:
        self.name = name
        self.slave = slave
        self.reports = ReportQueue()
        self.pending: deque[SlaveBurst] = deque()

    def errors(self, failures: list[str]) -> None:
        # Worded like VUnit's messages, without a prefix: the logger names the slave
        for failure in failures:
            self.reports.add(Severity.ERROR, failure)


def _endian(value: int) -> Endianness | None:
    """``endianness_arg_t'pos``: 0 little, 1 big, 2 the default of the memory."""
    return None if value == 2 else Endianness(value)


class Axi4MemoryBackend(VcBackend):
    """
    The Python object behind a VHDL AXI4 memory and the slaves using it.

    The testbench's procedures (backdoor access) report on the memory's logger and checker. Each slave
    attaches as a port and gets reports of its own, logged on its checker.

    Args:
        name: The name of the memory, used in messages.
        size_bytes: The number of addresses, 0 for the whole 64-bit space.
        default_value: The value of a byte never written.
        default_permission: The permission of a byte never allocated, a ``permissions_t'pos``.
        endian: The default byte order, an ``endianness_arg_t'pos``.

    Attributes:
        memory: The :class:`~awesome_vunit_vcs.axi4.memory_model.MemoryModel`, which a Python test may
            read and change.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        size_bytes: int = 0,
        default_value: int = 0,
        default_permission: int = Permission.READ_AND_WRITE,
        endian: int = Endianness.LITTLE,
    ) -> None:
        super().__init__(name)
        self.memory = self.guard(
            "configure",
            lambda: MemoryModel(size_bytes or None, default_value, Permission(default_permission), Endianness(endian)),
            MemoryModel(),
        )
        self._ports: list[_SlavePort] = []

    def _errors(self, failures: list[str]) -> int:
        # Worded like VUnit's messages, without a prefix: the logger names the memory
        for failure in failures:
            self.reports.add(Severity.ERROR, failure)
        return len(self.reports)

    def take_reports(self, port: int = -1) -> str:
        """The reports waiting for the memory, or for a slave port, encoded for VHDL."""
        return encode_reports((self.reports if port < 0 else self._ports[port].reports).take())

    # -- backdoor ------------------------------------------------------------

    def clear(self) -> int:
        """Forget content, permissions, expected data and buffers."""
        self.memory.clear()
        return len(self.reports)

    def num_bytes(self) -> int:
        """Where the next automatically placed buffer starts."""
        return min(self.memory.num_bytes, VHDL_INTEGER_MAX)

    def allocate(
        self,
        num_bytes: int,
        name: str | Sequence[int],
        alignment: int,
        permission: int,
        address: int = -1,
        wide: bool = False,
    ) -> int:
        """
        Allocate a buffer, at ``address`` or after the last one placed.

        Returns:
            The address of the buffer, or 0 with ``wide``, since VHDL knows it and it may not fit an integer;
            -1 on failure.
        """

        def allocate_() -> int:
            buffer = self.memory.allocate(
                num_bytes, decode_text(name), alignment, Permission(permission), None if address < 0 else address
            )
            if wide:
                return 0
            if buffer.address > VHDL_INTEGER_MAX:
                raise Axi4ValueError(f"The buffer address {buffer.address} does not fit a VHDL natural")
            return buffer.address

        return self.guard("allocate", allocate_, -1)

    def describe_address(self, address: int) -> str:
        """The address and its buffer, as VUnit words it."""
        return self.memory.describe_address(address)

    def write_bytes(self, address: int, data: Any) -> int:
        """Write bytes as the testbench does: no permission check; a byte differing from its expected one is skipped."""
        data_bytes = (np.asarray(data, dtype=np.int64).reshape(-1) & 0xFF).astype(np.uint8).tobytes()
        return self._errors(self.memory.write(address, data_bytes))

    def read_bytes(self, address: int, num_bytes: int) -> npt.NDArray[np.uint8]:
        """Read bytes without a permission check, as 8-bit values; VHDL fetches the failures after the call."""
        data, failures = self.memory.read(address, num_bytes)
        self._errors(failures)
        return np.frombuffer(data, dtype=np.uint8).copy()

    def fill(self, address: int, num_bytes: int, value: int) -> int:
        """Set a range to one value in O(1)."""
        return self._errors(self.memory.fill(address, num_bytes, value))

    def write_word(self, address: int, data: Sequence[int], endian: int) -> int:
        """Write a word given by its bytes, least significant first, in the byte order ``endian``."""
        value = int.from_bytes(bytes(int(byte) & 0xFF for byte in data), "little")
        return self._errors(self.memory.write(address, self.memory.serialize(value, len(data), _endian(endian))))

    def read_word(self, address: int, num_bytes: int, endian: int) -> npt.NDArray[np.int32]:
        """Read a word in the byte order ``endian``; its bytes least significant first."""
        data, failures = self.memory.read(address, num_bytes)
        self._errors(failures)
        value = self.memory.deserialize(data, _endian(endian))
        return int32_array(list(value.to_bytes(num_bytes, "little")))

    def write_integer(self, address: int, value: int, bytes_per_word: int, endian: int) -> int:
        """Write an integer of 1 to 4 bytes, two's complement."""
        return self._errors(self.memory.write(address, self.memory.serialize(value, bytes_per_word, _endian(endian))))

    def set_permissions(self, address: int, num_bytes: int, permission: int) -> int:
        """Give a range a ``permissions_t'pos``."""
        return self._errors(self.memory.set_permission(address, num_bytes, Permission(permission)))

    def get_permissions(self, address: int) -> int:
        """The ``permissions_t'pos`` of a byte."""
        return int(self.memory.permission(address))

    def set_expected_word(self, address: int, data: Sequence[int], endian: int) -> int:
        """The word a slave must write, its bytes least significant first."""
        value = int.from_bytes(bytes(int(byte) & 0xFF for byte in data), "little")
        return self._errors(self.memory.set_expected(address, self.memory.serialize(value, len(data), _endian(endian))))

    def set_expected_integer(self, address: int, value: int, bytes_per_word: int, endian: int) -> int:
        """The integer a slave must write."""
        return self._errors(
            self.memory.set_expected(address, self.memory.serialize(value, bytes_per_word, _endian(endian)))
        )

    def clear_expected(self, address: int, num_bytes: int) -> int:
        """Forget the expected bytes of a range."""
        return self._errors(self.memory.clear_expected(address, num_bytes))

    def has_expected(self, address: int) -> bool:
        """Whether a byte has an expected value."""
        return self.memory.has_expected(address)

    def get_expected(self, address: int) -> int:
        """The expected value of a byte."""
        return self.memory.expected(address)

    def check_expected_was_written(self, address: int = 0, num_bytes: int = -1) -> int:
        """A check failure per byte not holding its expected value, in the range or everywhere (``num_bytes`` -1)."""
        return self._errors(self.memory.check_expected_was_written(address, None if num_bytes < 0 else num_bytes))

    def expected_was_written(self, address: int = 0, num_bytes: int = -1) -> bool:
        """Whether every byte of the range holds its expected value."""
        return not self.memory.unwritten_expected(address, None if num_bytes < 0 else num_bytes)

    def write_integer_array(
        self, address: int, data: Any, bytes_per_word: int, stride: int, endian: int, expected: bool = False
    ) -> int:
        """
        Write an ``integer_array_t``, or set it as expected data, as VUnit's ``memory_utils_pkg`` lays it out:
        each row of ``width`` words at ``stride`` bytes (the row size when 0) from the previous one.
        """

        def write() -> None:
            array = np.asarray(data, dtype=np.int64)
            rows = array.reshape(array.shape[0], -1) if array.ndim > 1 else array.reshape(1, -1)
            if array.ndim == 3:
                # get(x, y, z) is a[y, x, z]; rows go y first, then z
                rows = array.transpose(2, 0, 1).reshape(-1, array.shape[1])
            row_bytes = rows.shape[1] * bytes_per_word
            for index, row in enumerate(rows):
                row_data = b"".join(self.memory.serialize(int(value), bytes_per_word, _endian(endian)) for value in row)
                row_address = address + index * (stride or row_bytes)
                if expected:
                    self._errors(self.memory.set_expected(row_address, row_data))
                else:
                    self._errors(self.memory.write(row_address, row_data))

        self.guard("write_integer_array", write, None)
        return len(self.reports)

    def load_image(self, path: str | Sequence[int], fmt: str | Sequence[int], base: int) -> int:
        """Load an image file; ``fmt`` empty infers the format from the extension. Failures are logged."""
        self.guard("load_image", lambda: self.memory.load_image(decode_text(path), decode_text(fmt) or None, base), 0)
        return len(self.reports)

    # -- slaves ----------------------------------------------------------------

    def attach(self, name: str | Sequence[int], data_width: int, is_write: bool, check_4kbyte_boundary: bool) -> int:
        """Attach a slave. Returns the port the slave passes to the other calls."""
        slave = Axi4Slave(self.memory, data_width, bool(is_write), bool(check_4kbyte_boundary))
        self._ports.append(_SlavePort(decode_text(name), slave))
        return len(self._ports) - 1

    def set_check_4kbyte_boundary(self, port: int, enabled: bool) -> None:
        """Enable or disable the 4 KB boundary check of a slave."""
        self._ports[port].slave.check_4kbyte_boundary = bool(enabled)

    def _accept(
        self, port: _SlavePort, id_: int, address: int, len_: int, size: int, burst: int, metavalue: bool
    ) -> SlaveBurst:
        accepted, failures = port.slave.accept(id_, address, len_, size, burst)
        if metavalue:
            kind = "AW" if port.slave.is_write else "AR"
            failures.insert(0, f"Metavalue on the {kind} channel of burst {accepted.describe()}, taken as 0")
        port.errors(failures)
        return accepted

    def read_burst(
        self, port: int, id_: int, address: int, len_: int, size: int, burst: int, metavalue: bool = False
    ) -> npt.NDArray[np.int32]:
        """
        Accept a read burst and read its data, in one call.

        Returns:
            ``[reports waiting, burst index, then per beat RRESP and one value per lane]``, a lane the beat
            does not use -1.
        """
        slave_port = self._ports[port]

        def read() -> npt.NDArray[np.int32]:
            accepted = self._accept(slave_port, id_, address, len_, size, burst, metavalue)
            result = slave_port.slave.read(accepted)
            slave_port.errors(result.failures)
            beats = np.concatenate((result.resps[:, None], result.data), axis=1).reshape(-1)
            return np.concatenate((int32_array([len(slave_port.reports), accepted.index]), beats)).astype(np.int32)

        empty = int32_array([0, 0] + ([int(Response.SLVERR)] + [-1] * slave_port.slave.data_bytes) * (len_ + 1))
        values = self.guard("read_burst", read, empty)
        values[0] = len(slave_port.reports) + len(self.reports)
        return values

    def accept_write(
        self, port: int, id_: int, address: int, len_: int, size: int, burst: int, metavalue: bool = False
    ) -> npt.NDArray[np.int32]:
        """Accept a write burst at its AW handshake. Returns ``[reports waiting, burst index]``."""
        slave_port = self._ports[port]

        def accept() -> int:
            accepted = self._accept(slave_port, id_, address, len_, size, burst, metavalue)
            slave_port.pending.append(accepted)
            return accepted.index

        index = self.guard("accept_write", accept, 0)
        return int32_array([len(slave_port.reports) + len(self.reports), index])

    def write_burst(self, port: int, lanes: Any) -> npt.NDArray[np.int32]:
        """
        Write the data of the oldest accepted write burst, at its write response.

        Args:
            port: The slave.
            lanes: Per beat, one value per lane: the byte, bit 8 WSTRB, bit 9 a metavalue in the byte.

        Returns:
            ``[reports waiting, BRESP]``.
        """
        slave_port = self._ports[port]

        def write() -> int:
            burst = slave_port.pending.popleft()
            values = np.asarray(lanes, dtype=np.int64).reshape(-1, slave_port.slave.data_bytes)
            strobes = (values >> 8 & 1).astype(np.bool_)
            metavalues = strobes & (values >> 9 & 1).astype(np.bool_)
            if metavalues.any() and burst.supported:
                beat, lane = (int(i) for i in np.argwhere(metavalues)[0])
                slave_port.errors(
                    [f"Metavalue in WDATA lane {lane} of beat {beat} of write burst {burst.describe()}, written as 0"]
                )
            resp, failures = slave_port.slave.write(burst, values & 0xFF, strobes)
            slave_port.errors(failures)
            return int(resp)

        resp = self.guard("write_burst", write, int(Response.SLVERR))
        return int32_array([len(slave_port.reports) + len(self.reports), resp])

    def statistics(self, port: int, clear: bool) -> npt.NDArray[np.int32]:
        """The number of bursts of each length from 0 to 256 beats the slave accepted, as VUnit's statistics."""
        counts = self._ports[port].slave.burst_lengths
        values = int32_array([min(counts[length], VHDL_INTEGER_MAX) for length in range(257)])
        if clear:
            counts.clear()
        return values

    def reset_slave(self, port: int) -> int:
        """Drop the bursts a slave accepted and did not finish, and number bursts from 0 again."""
        self._ports[port].pending.clear()
        self._ports[port].slave.reset()
        return len(self._ports[port].reports)
