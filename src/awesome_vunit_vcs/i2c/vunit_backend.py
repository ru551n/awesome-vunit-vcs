# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Backends of the I2C VHDL verification components.

Each VC creates one backend in its own Python session, as the object ``vc``.
VHDL owns the pins and simulation time and calls these methods with the typed
arguments of the bridge: a ``time`` is what ``arg_time`` sends, decoded with
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_time_fs`, and a ``text``
what ``arg_text`` sends; Python callers pass fs and ``str`` instead.

No method raises into the bridge. A failed check is an
:attr:`~awesome_vunit_vcs.common.reports.Severity.ERROR` report, logged as a
check failure on the checker of the VC; any other exception is a
:attr:`~awesome_vunit_vcs.common.reports.Severity.FAILURE` report on its logger.
Methods that return ``num_reports`` let VHDL fetch reports only when there are
some.

::

    I2cMasterBackend(name: text, speed, t_low=time, t_high=time, t_hd_dat=time, t_su_sta=time,
                     t_hd_sta=time, t_su_sto=time, t_buf=time)
    timing()                                   -> [t_low, t_high, t_hd_dat, t_su_sta, t_hd_sta,
                                                   t_su_sto, t_buf] in ps
    transfer(address, write, num_read, ten_bit, pec, stop, expect_ack) -> operation words
    transfer_ops(ops: text)                    -> operation words
    complete(results)                          -> [status, num_reports, n, read bytes..., m, acks...]

    I2cTargetBackend(name: text, address, ten_bit, general_call, pec, pec_read_bytes, stretch=time)
    set_arguments(*args, **kwargs); create_device(model: text) -> num_reports
    start(now: time)                           -> directive
    received(byte, now: time)                  -> directive
    transmitted(acked, now: time)              -> directive
    stop(now: time)                            -> num_reports
    set_stretch(stretch: time); inject_nack(index); reset()
    preload(data, address); check_memory(expected, address, message: text) -> num_reports
    read_memory(address, length)               -> integer_array_t

    I2cMonitorBackend(name: text, report_metavalues)
    set_publish(enabled); take_published() -> transfers; pop_transfer() -> transfer or empty
    check_transfer(address, read, data, message: text); statistics_values(now: time); reset(clear); finish()
    I2cProtocolCheckerBackend(name: text, speed, f_scl_max=Hz, t_hd_sta=time, ..., t_stuck=time)
    push(samples, base_time, delta_unit)       -> num_reports

A directive is ``[action, ack, byte_out, stretch in ps, num_reports]``, see
:class:`~awesome_vunit_vcs.i2c.target.Directive`.
"""

from __future__ import annotations

import importlib
from collections import deque
from collections.abc import Callable, Sequence
from typing import Any

import numpy as np
import numpy.typing as npt

from ..common.backend import VHDL_INTEGER_MAX, SampleBackend, VcBackend, int32_array
from ..common.reports import Severity
from ..common.vunit_bridge import decode_text, decode_time_fs, split_time
from .checker import I2cCheckId, I2cProtocolChecker, I2cViolation
from .devices import Eeprom24, I2cDevice, RegisterDevice
from .errors import I2cValueError
from .master import I2cStatus, Program, compile_ops, compile_transfer
from .monitor import I2cMonitor
from .target import Action, Directive, I2cTarget
from .timing import bus_limits, master_timing
from .transfer import I2cTransfer

__all__ = ["I2cMasterBackend", "I2cMonitorBackend", "I2cProtocolCheckerBackend", "I2cTargetBackend"]

#: The device models a target names without a module
DEVICE_MODELS: dict[str, type[I2cDevice]] = {
    "device": I2cDevice,
    "registers": RegisterDevice,
    "eeprom": Eeprom24,
}

_PS = 1000


def _time(value: int | Sequence[int] | None) -> int:
    return 0 if value is None else decode_time_fs(value)


def _ps(time_fs: int, what: str) -> int:
    value = -(-time_fs // _PS)
    if value > VHDL_INTEGER_MAX:
        raise I2cValueError(f"{what}={time_fs} fs exceeds the {VHDL_INTEGER_MAX} ps a VHDL integer holds")
    return value


class I2cMasterBackend(VcBackend):
    """
    The Python object behind a VHDL I2C master: compiles transfers and reads their results.

    Args:
        name: The name of the master, used in messages.
        speed: The speed mode, see :class:`~awesome_vunit_vcs.i2c.timing.SpeedMode`.
        t_low, t_high, t_hd_dat, t_su_sta, t_hd_sta, t_su_sto, t_buf: Times replacing those of
            :func:`~awesome_vunit_vcs.i2c.timing.master_timing`; 0 keeps the time of the speed mode.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        speed: int = 0,
        *,
        t_low: int | Sequence[int] | None = None,
        t_high: int | Sequence[int] | None = None,
        t_hd_dat: int | Sequence[int] | None = None,
        t_su_sta: int | Sequence[int] | None = None,
        t_hd_sta: int | Sequence[int] | None = None,
        t_su_sto: int | Sequence[int] | None = None,
        t_buf: int | Sequence[int] | None = None,
    ) -> None:
        super().__init__(name)
        overrides = {
            "t_low_fs": t_low,
            "t_high_fs": t_high,
            "t_hd_dat_fs": t_hd_dat,
            "t_su_sta_fs": t_su_sta,
            "t_hd_sta_fs": t_hd_sta,
            "t_su_sto_fs": t_su_sto,
            "t_buf_fs": t_buf,
        }
        default = master_timing(speed if 0 <= speed <= 2 else 0)
        times = {key: _time(value) for key, value in overrides.items()}
        self.timing_fs = self.guard("configure", lambda: master_timing(speed, **times), default)
        self._program: Program | None = None
        self._expect_ack = False
        self._description = ""

    def timing(self) -> npt.NDArray[np.int32]:
        """The times the master drives, in ps, in the order of the constructor."""
        timing = self.timing_fs
        return self.guard(
            "timing",
            lambda: int32_array(
                [
                    _ps(value, name)
                    for name, value in (
                        ("t_low", timing.t_low_fs),
                        ("t_high", timing.t_high_fs),
                        ("t_hd_dat", timing.t_hd_dat_fs),
                        ("t_su_sta", timing.t_su_sta_fs),
                        ("t_hd_sta", timing.t_hd_sta_fs),
                        ("t_su_sto", timing.t_su_sto_fs),
                        ("t_buf", timing.t_buf_fs),
                    )
                ]
            ),
            int32_array([5_000_000, 5_000_000, 1_000_000, 5_000_000, 5_000_000, 5_000_000, 5_000_000]),
        )

    def transfer(
        self,
        address: int,
        write: Sequence[int] = (),
        num_read: int = 0,
        ten_bit: bool = False,
        pec: bool = False,
        stop: bool = True,
        expect_ack: bool = True,
    ) -> npt.NDArray[np.int32]:
        """
        Compile a write, read or write-then-read; see
        :func:`~awesome_vunit_vcs.i2c.master.compile_transfer`.

        Args:
            expect_ack: A byte without acknowledge, a lost arbitration or a wrong PEC is a check
                failure; otherwise only the status tells.

        Returns:
            The operation words, empty after an error.
        """

        def compile_() -> npt.NDArray[np.int32]:
            self._program = compile_transfer(
                address, [int(value) for value in write], num_read, ten_bit=ten_bit, pec=pec, stop=stop
            )
            return int32_array(self._program.words)

        self._expect_ack = expect_ack
        kind = "write-read" if len(write) and num_read else "read" if num_read else "write"
        self._description = f"{kind} of 0x{address:02X}"
        self._program = None
        return self.guard("transfer", compile_, int32_array([]))

    def transfer_ops(self, ops: str | Sequence[int]) -> npt.NDArray[np.int32]:
        """Compile operations, see :func:`~awesome_vunit_vcs.i2c.master.compile_ops`."""

        def compile_() -> npt.NDArray[np.int32]:
            self._program = compile_ops(decode_text(ops))
            return int32_array(self._program.words)

        self._expect_ack = False
        self._program = None
        return self.guard("transfer_ops", compile_, int32_array([]))

    def complete(self, results: Sequence[int]) -> npt.NDArray[np.int32]:
        """
        The outcome of the last compiled transfer from the results of the master.

        Returns:
            ``[status, num_reports, n, n read bytes..., m, m acknowledge bits...]``, an acknowledge
            bit 1 for ACK.
        """
        program = self._program
        self._program = None

        def complete_() -> npt.NDArray[np.int32]:
            if program is None:
                raise I2cValueError("complete without a transfer")
            result = program.result(np.asarray(results).reshape(-1).tolist())
            if result.status is I2cStatus.ARBITRATION_LOST:
                self.reports.add(Severity.INFO, f"{self.name}: lost arbitration in a {self._description or 'transfer'}")
            if self._expect_ack and result.status is not I2cStatus.OK:
                self.error(f"{self._description}: {result.status.name.lower().replace('_', ' ')}")
            return int32_array(
                [
                    int(result.status),
                    len(self.reports),
                    len(result.data),
                    *result.data,
                    len(result.acks),
                    *(int(ack) for ack in result.acks),
                ]
            )

        return self.guard("complete", complete_, int32_array([int(I2cStatus.ARBITRATION_LOST), 0, 0, 0]))


def _directive(directive: Directive, reports: int) -> npt.NDArray[np.int32]:
    return int32_array(
        [int(directive.action), int(directive.ack), directive.byte_out, _ps(directive.stretch_fs, "stretch"), reports]
    )


class I2cTargetBackend(VcBackend):
    """
    The Python object behind a VHDL I2C target: an :class:`~awesome_vunit_vcs.i2c.target.I2cTarget`
    with a device model.

    Args:
        name: The name of the target, used in messages.
        address: The 7-bit or 10-bit address.
        ten_bit, general_call, pec, pec_read_bytes: See
            :class:`~awesome_vunit_vcs.i2c.target.I2cTarget`.
        stretch: How long to stretch SCL before every acknowledge bit, 0 for no stretching.

    Attributes:
        target: The protocol engine; ``target.device`` is the device model.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        address: int,
        ten_bit: bool = False,
        general_call: bool = False,
        pec: bool = False,
        pec_read_bytes: int = 1,
        stretch: int | Sequence[int] = 0,
    ) -> None:
        super().__init__(name)
        self._address = address
        self._ten_bit = ten_bit
        self._general_call = general_call
        self._pec = pec
        self._pec_read_bytes = pec_read_bytes
        self._arguments: tuple[tuple[Any, ...], dict[str, Any]] = ((), {})
        self.target = self.guard(
            "configure", lambda: self._make_target(I2cDevice(), _time(stretch)), I2cTarget(I2cDevice(), 0)
        )

    def _make_target(self, device: I2cDevice, stretch_fs: int) -> I2cTarget:
        target = I2cTarget(
            device,
            self._address,
            ten_bit=self._ten_bit,
            general_call=self._general_call,
            pec=self._pec,
            pec_read_bytes=self._pec_read_bytes,
            stretch_fs=stretch_fs,
        )
        target.errors.subscribe(self.error)
        return target

    def set_arguments(self, *args: Any, **kwargs: Any) -> None:
        """The arguments of the device model :meth:`create_device` creates next."""
        self._arguments = (args, kwargs)

    def create_device(self, model: str | Sequence[int]) -> int:
        """
        Create the device model and use it from now on.

        Args:
            model: ``"registers"``, ``"eeprom"``, ``"device"`` or ``"package.module:Class"`` of a
                subclass of :class:`~awesome_vunit_vcs.i2c.devices.I2cDevice`, called with the
                arguments of :meth:`set_arguments`.

        Returns:
            The number of reports waiting.
        """
        args, kwargs = self._arguments
        self._arguments = ((), {})

        def create() -> None:
            name = decode_text(model).strip()
            if name in DEVICE_MODELS:
                cls: Any = DEVICE_MODELS[name]
            elif ":" in name:
                module, _, attribute = name.partition(":")
                cls = getattr(importlib.import_module(module), attribute)
            else:
                known = ", ".join(sorted(DEVICE_MODELS))
                raise I2cValueError(f"Unknown device model {name!r}: use {known} or 'package.module:Class'")
            device = cls(*args, **kwargs)
            if not isinstance(device, I2cDevice):
                raise I2cValueError(f"{name} is not an I2cDevice")
            self.target = self._make_target(device, self.target.stretch_fs)

        self.guard("create_device", create, None)
        return len(self.reports)

    @property
    def device(self) -> I2cDevice:
        """The device model."""
        return self.target.device

    def start(self, now: int | Sequence[int]) -> npt.NDArray[np.int32]:
        """A START or repeated START."""
        return self._directive("start", lambda: self.target.start(decode_time_fs(now)))

    def received(self, value: int, now: int | Sequence[int]) -> npt.NDArray[np.int32]:
        """The target received a byte."""
        return self._directive("received", lambda: self.target.received(value, decode_time_fs(now)))

    def transmitted(self, acked: bool, now: int | Sequence[int]) -> npt.NDArray[np.int32]:
        """The master acknowledged the byte the target transmitted, or not."""
        return self._directive("transmitted", lambda: self.target.transmitted(bool(acked), decode_time_fs(now)))

    def _directive(self, method: str, fn: Callable[[], Directive]) -> npt.NDArray[np.int32]:
        directive = self.guard(method, fn, Directive(Action.IGNORE))
        return self.guard(
            method, lambda: _directive(directive, len(self.reports)), int32_array([2, 0, 0, 0, len(self.reports)])
        )

    def stop(self, now: int | Sequence[int]) -> int:
        """A STOP. Returns the number of reports waiting."""
        self.guard("stop", lambda: self.target.stop(decode_time_fs(now)), None)
        return len(self.reports)

    def reset(self) -> int:
        """Forget a transfer in progress."""
        self.target.reset()
        return len(self.reports)

    def set_stretch(self, stretch: int | Sequence[int]) -> int:
        """Stretch SCL for this long before every acknowledge bit, 0 for no stretching."""
        self.guard("set_stretch", lambda: setattr(self.target, "stretch_fs", decode_time_fs(stretch)), None)
        return len(self.reports)

    def inject_nack(self, index: int) -> int:
        """Do not acknowledge byte ``index`` of the next transfer, 0 for the address."""
        self.guard("inject_nack", lambda: self.target.inject_nack(index), None)
        return len(self.reports)

    def preload(self, data: Any, address: int) -> int:
        """Write device memory directly."""
        self.guard("preload", lambda: self.device.preload(address, _bytes(data)), None)
        return len(self.reports)

    def read_memory(self, address: int, length: int) -> npt.NDArray[np.int32]:
        """Read device memory directly."""
        return self.guard(
            "read_memory", lambda: int32_array(list(self.device.read_memory(address, length))), int32_array([])
        )

    def check_memory(self, expected: Any, address: int, message: str | Sequence[int] = "") -> int:
        """Compare device memory with ``expected``; a difference is a check failure."""

        def check() -> None:
            want = _bytes(expected)
            have = self.device.read_memory(address, len(want))
            if have != want:
                offset = next(index for index, (a, b) in enumerate(zip(want, have, strict=True)) if a != b)
                prefix = decode_text(message)
                self.error(
                    f"{prefix}{': ' if prefix else ''}memory at 0x{address + offset:X} is 0x{have[offset]:02X}, "
                    f"expected 0x{want[offset]:02X}"
                )

        self.guard("check_memory", check, None)
        return len(self.reports)


def _bytes(values: Any) -> bytes:
    array = np.array(values, dtype=np.int64).reshape(-1)
    if array.size and (int(array.min()) < 0 or int(array.max()) > 0xFF):
        raise I2cValueError("memory data must be bytes, 0 to 255")
    return array.astype(np.uint8).tobytes()


def _flat(transfer: I2cTransfer) -> list[int]:
    flags = (
        transfer.read
        | transfer.ten_bit << 1
        | transfer.repeated_start << 2
        | transfer.stopped << 3
        | transfer.address_ack << 4
    )
    nack = transfer.nack_index
    return [
        -1 if transfer.address is None else transfer.address,
        flags,
        -1 if nack is None else nack,
        *split_time(transfer.start_fs),
        len(transfer.data),
        *transfer.data,
    ]


class I2cMonitorBackend(SampleBackend):
    """
    The Python object behind a VHDL I2C monitor.

    Args:
        name: The name of the monitor, used in messages.
        report_metavalues: Report metavalues as check failures (``I2C_METAVALUE``); a monitor with a
            protocol checker leaves that to the checker.

    Attributes:
        monitor: The :class:`~awesome_vunit_vcs.i2c.monitor.I2cMonitor`; subscribe to its
            ``transfers`` to extend the monitor from Python.
    """

    def __init__(self, name: str | Sequence[int], report_metavalues: bool = True, keep_transfers: int = 1024) -> None:
        super().__init__(name)
        self.monitor = I2cMonitor(on_subscriber_error=self.subscriber_error)
        self.monitor.transfers.subscribe(self._compare)
        self.monitor.transfers.subscribe(self._keep)
        if report_metavalues:
            self.monitor.metavalues.subscribe(
                lambda event: self.error(
                    f"{I2cCheckId.METAVALUE.value}: metavalue on {'SDA' if event.sda else 'SCL'} at {event.time_fs} fs"
                )
            )
        #: Collect transfers for :meth:`take_published`; VHDL sets it while the monitor has subscribers
        self.publish_transfers = False
        self._published: list[I2cTransfer] = []
        self._kept: deque[I2cTransfer] = deque(maxlen=keep_transfers)
        self._expected: deque[tuple[int, bool, bytes, str]] = deque()

    def feed(self, words: list[int], times: list[int]) -> None:
        self.monitor.feed(words, times)

    def _keep(self, transfer: I2cTransfer) -> None:
        self._kept.append(transfer)
        if self.publish_transfers:
            self._published.append(transfer)

    def _compare(self, transfer: I2cTransfer) -> None:
        if not self._expected:
            return
        address, read, data, message = self._expected.popleft()
        differences = []
        if transfer.address != address:
            got = "none" if transfer.address is None else f"0x{transfer.address:02X}"
            differences.append(f"address {got}, expected 0x{address:02X}")
        if transfer.read != read:
            differences.append(f"{'read' if transfer.read else 'write'}, expected {'read' if read else 'write'}")
        if transfer.data != data:
            differences.append(f"data {transfer.data.hex(' ').upper()}, expected {data.hex(' ').upper()}")
        if differences:
            prefix = f"{message}: " if message else ""
            self.error(
                f"{I2cCheckId.SCOREBOARD.value}: {prefix}transfer {transfer.index} at {transfer.start_fs} fs has "
                + "; ".join(differences)
            )

    def set_publish(self, enabled: bool) -> None:
        """Collect transfers for :meth:`take_published` or not."""
        self.publish_transfers = bool(enabled)
        if not enabled:
            self._published = []

    def take_published(self) -> npt.NDArray[np.int32]:
        """The transfers since the last call while publishing, flat for VHDL, see :meth:`pop_transfer`."""
        transfers, self._published = self._published, []
        return int32_array([value for transfer in transfers for value in _flat(transfer)])

    def pop_transfer(self) -> npt.NDArray[np.int32]:
        """
        The oldest transfer kept, flat for VHDL, or an empty array: ``address`` (-1 for none),
        ``flags`` (bit 0 read, 1 10-bit, 2 repeated START, 3 STOP, 4 address ACK), the index of the
        first data byte not acknowledged (-1 for none), the start time in fs as ``hi, lo``, the number
        of data bytes and the bytes. The monitor keeps the last ``keep_transfers`` transfers.
        """
        return int32_array(_flat(self._kept.popleft()) if self._kept else [])

    def check_transfer(
        self, address: int, read: bool, data: Sequence[int] = (), message: str | Sequence[int] = ""
    ) -> None:
        """Queue the transfer the next transfer must equal: address, direction and data bytes."""
        self._expected.append((address, bool(read), bytes(int(value) for value in data), decode_text(message)))

    def transfer_count(self) -> int:
        """Transfers completed."""
        return self.monitor.transfer_count

    def statistics_values(self, now: int | Sequence[int]) -> npt.NDArray[np.int32]:
        """
        The statistics for the VHDL record: the counts, the frequencies in Hz, the busy and stretch
        times as ``hi, lo`` fs and the utilization in parts per million.
        """

        def values() -> npt.NDArray[np.int32]:
            self.monitor.advance(decode_time_fs(now))
            stats = self.monitor.statistics()
            counts = [
                stats.transactions,
                stats.transfers,
                stats.reads,
                stats.writes,
                stats.repeated_starts,
                stats.data_bytes,
                stats.nacks,
                stats.address_nacks,
                stats.metavalues,
                stats.scl_frequency_hz,
                stats.max_scl_frequency_hz,
            ]
            return int32_array(
                [
                    *(min(value, VHDL_INTEGER_MAX) for value in counts),
                    *split_time(stats.busy_fs),
                    *split_time(stats.stretch_fs),
                    round(stats.utilization * 1_000_000),
                ]
            )

        return self.guard("statistics", values, int32_array([0] * 16))

    def reset(self, clear_statistics: bool = False) -> int:
        """Drop a transfer in progress, the kept and the expected transfers."""
        self.monitor.reset()
        if clear_statistics:
            self.monitor.clear_statistics()
        self._kept.clear()
        self._published = []
        self._expected.clear()
        return len(self.reports)

    def finish(self) -> int:
        """At the end of the test: an expected transfer that never came is a check failure."""
        for address, _, _, message in self._expected:
            prefix = f"{message}: " if message else ""
            self.error(f"{I2cCheckId.SCOREBOARD.value}: {prefix}expected transfer to 0x{address:02X} never came")
        self._expected.clear()
        return len(self.reports)


class I2cProtocolCheckerBackend(SampleBackend):
    """
    The Python object behind a VHDL I2C protocol checker.

    Args:
        name: The name of the protocol checker, used in messages.
        speed: The speed mode whose limits apply, see :func:`~awesome_vunit_vcs.i2c.timing.bus_limits`.
        f_scl_max: The highest SCL frequency in Hz, 0 for that of the speed mode.
        t_hd_sta, t_low, t_high, t_su_sta, t_hd_dat, t_su_dat, t_su_sto, t_buf: Minimum times, 0 for
            those of the speed mode.
        t_stuck: How long SCL or SDA may stay low, 0 to never report it.

    Attributes:
        checker: The :class:`~awesome_vunit_vcs.i2c.checker.I2cProtocolChecker`.
    """

    def __init__(
        self,
        name: str | Sequence[int],
        speed: int = 0,
        *,
        f_scl_max: int = 0,
        t_hd_sta: int | Sequence[int] | None = None,
        t_low: int | Sequence[int] | None = None,
        t_high: int | Sequence[int] | None = None,
        t_su_sta: int | Sequence[int] | None = None,
        t_hd_dat: int | Sequence[int] | None = None,
        t_su_dat: int | Sequence[int] | None = None,
        t_su_sto: int | Sequence[int] | None = None,
        t_buf: int | Sequence[int] | None = None,
        t_stuck: int | Sequence[int] | None = 35_000_000_000_000,
    ) -> None:
        super().__init__(name)

        def create() -> I2cProtocolChecker:
            limits = bus_limits(
                speed,
                f_scl_max_hz=f_scl_max,
                t_hd_sta_fs=_time(t_hd_sta),
                t_low_fs=_time(t_low),
                t_high_fs=_time(t_high),
                t_su_sta_fs=_time(t_su_sta),
                t_hd_dat_fs=_time(t_hd_dat),
                t_su_dat_fs=_time(t_su_dat),
                t_su_sto_fs=_time(t_su_sto),
                t_buf_fs=_time(t_buf),
            )
            return I2cProtocolChecker(limits, _time(t_stuck))

        self.checker = self.guard("configure", create, I2cProtocolChecker())
        self.checker.violations.subscribe(self._violation)

    def _violation(self, violation: I2cViolation) -> None:
        self.reports.add(Severity.ERROR, f"{self.name}: {violation.message}")

    def feed(self, words: list[int], times: list[int]) -> None:
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
        """Forget the timing history and set the counts to 0."""
        self.checker.reset()
        return len(self.reports)

    def finish(self, now: int | Sequence[int]) -> int:
        """At the end of the test: a line stuck low."""
        self.guard("finish", lambda: self.checker.check_stuck(decode_time_fs(now)), None)
        return len(self.reports)
