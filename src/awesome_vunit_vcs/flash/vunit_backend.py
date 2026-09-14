# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Backend of the flash VHDL verification component.

Each ``flash`` instance creates one :class:`FlashBackend` in its own Python
session, as the object ``vc``. The session has the identity of the VC, so
instances never share state and there is no instance registry: the object
itself is the handle. Nothing here touches simulator signals; VHDL owns pins
and time and tells the model the time at CS edges and byte boundaries.

The calls VHDL makes (``hi``/``lo`` are the halves of a time in
femtoseconds, ``t = hi * 2**30 + lo``, see :mod:`awesome_vunit_vcs.common.vunit_bridge`)::

    FlashBackend('<name>', size_bytes=..., page_bytes=..., sector_bytes=...,
                 block32_bytes=..., block_bytes=..., addr_bytes=..., addr_modes=0|3|4,
                 jedec_id=..., electronic_id=-1, sr1_default=..., sr2_default=...,
                 sr3_default=..., busy={'tPP': (hi, lo), ...}, timing_enabled=True)
    layout_version()                      -> integer
    num_reports()                         -> integer
    take_reports()                        -> string
    cs_assert(hi, lo)                     -> packed directive
    xfer(byte)  or  xfer(byte, hi, lo)    -> packed directive
    cs_deassert(trailing_bits, hi, lo)    -> integer_array_t [busy_hi, busy_lo, num_reports]
    reset(clear_statistics)               -> num_reports
    preload(data, addr)                   -> num_reports (data: integer_array_t)
    preload_fill(addr, num_bytes, value)  -> num_reports
    load_image('<path>', '<fmt>', base)   -> num_reports (fmt 'auto' picks by extension)
    read_back(addr, num_bytes)            -> integer_array_t
    check_content(expected, addr)         -> num_reports (expected: integer_array_t)
    check_content_fill(addr, num_bytes, value) -> num_reports
    written_regions()                     -> integer_array_t [addr, len, ...]
    set_timing_enable(enable)             -> num_reports
    set_timing('<name>', hi, lo)          -> num_reports
    set_protection(addr, num_bytes, locked) -> num_reports
    get_stat('<name>')  or  get_stat('<name>', hi, lo) -> integer
    clear_statistics()                    -> num_reports

Addresses and lengths are in bytes.

Errors never escape into the bridge. A content check that fails is a
:class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`, an
:attr:`~awesome_vunit_vcs.common.reports.Severity.ERROR` report, which VHDL logs as a check
failure on the VC checker; any other exception (a
:class:`~awesome_vunit_vcs.flash.errors.FlashValueError` for an invalid configuration,
a non-byte value, an unknown timing or stat name or a VC protocol bug) is a
:attr:`~awesome_vunit_vcs.common.reports.Severity.FAILURE` report on the VC logger. Every
report starts with the name of the VC. Calls that return ``num_reports``
let VHDL fetch the reports only when there are some.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any, TypeVar

import numpy as np
import numpy.typing as npt

from ..common.reports import ReportQueue, Severity, encode_reports
from ..common.vunit_bridge import join_time, split_time
from .config import AddrModes, FlashConfig
from .device import FlashDevice
from .directive import LAYOUT_VERSION, ignore_rest
from .errors import ContentMismatch, FlashValueError

__all__ = ["FlashBackend"]

T = TypeVar("T")


def _int32(values: Any) -> npt.NDArray[np.int32]:
    """The array form every ``integer_array_t`` return value takes."""
    return np.array(values, dtype=np.int32).reshape(-1)


def _join_time(hi: int, lo: int) -> int:
    """The time in fs of the halves VHDL sends, checked."""
    try:
        return join_time(hi, lo)
    except ValueError as exc:
        raise FlashValueError(str(exc)) from exc


def _addr_modes(value: int) -> AddrModes:
    """The addressing modes VHDL sends, checked."""
    try:
        return AddrModes(value)
    except ValueError:
        known = [int(mode) for mode in AddrModes]
        raise FlashValueError(f"addr_modes={value} must be one of {known}") from None


def _bytes(values: Any) -> bytes:
    """
    An ``integer_array_t`` of byte values from VHDL (a NumPy array, or any
    sequence of integers), checked.
    """
    array = np.array(values, dtype=np.int64).reshape(-1)
    bad = np.flatnonzero((array < 0) | (array > 0xFF))
    if bad.size:
        index = int(bad[0])
        raise FlashValueError(f"element {index} = {int(array[index])} is not a byte value")
    return array.astype(np.uint8).tobytes()


class FlashBackend:
    """
    The Python object behind a VHDL flash, ``vc`` in the session of the flash.

    The arguments are the fields of
    :class:`~awesome_vunit_vcs.flash.config.FlashConfig` as VHDL sends them.
    An invalid configuration does not raise: it queues a failure report, and
    the backend uses a default configuration so the calls that follow stay
    harmless.

    Args:
        name: The name of the flash, used in messages.
        size_bytes: Capacity in bytes.
        page_bytes: Page size in bytes.
        sector_bytes: Sector size in bytes.
        block32_bytes: 32 KiB block size in bytes, 0 for none.
        block_bytes: Block size in bytes.
        addr_bytes: Addressing mode at power-up, 3 or 4 bytes.
        addr_modes: A value of :class:`~awesome_vunit_vcs.flash.config.AddrModes`, 0, 3 or 4.
        jedec_id: The 24-bit JEDEC ID.
        electronic_id: The one-byte electronic ID, negative to derive it
            from the JEDEC ID.
        sr1_default: Status register 1 after power-up and reset.
        sr2_default: Status register 2 after power-up and reset.
        sr3_default: Status register 3 after power-up and reset.
        busy: Every busy-time name of
            :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`, mapped to the
            ``(hi, lo)`` halves of its time in fs.
        timing_enabled: Whether busy times apply initially.

    Attributes:
        name: The name of the flash.
        reports: The :class:`~awesome_vunit_vcs.common.reports.ReportQueue`
            VHDL fetches with :meth:`take_reports`.
        device: The :class:`~awesome_vunit_vcs.flash.device.FlashDevice`.
    """

    def __init__(
        self,
        name: str,
        *,
        size_bytes: int,
        page_bytes: int,
        sector_bytes: int,
        block32_bytes: int,
        block_bytes: int,
        addr_bytes: int,
        addr_modes: int,
        jedec_id: int,
        electronic_id: int,
        sr1_default: int,
        sr2_default: int,
        sr3_default: int,
        busy: Mapping[str, tuple[int, int]],
        timing_enabled: bool,
    ) -> None:
        self.name = name
        self.reports = ReportQueue()

        def config() -> FlashConfig:
            return FlashConfig(
                size_bytes=size_bytes,
                page_bytes=page_bytes,
                sector_bytes=sector_bytes,
                block32_bytes=block32_bytes,
                block_bytes=block_bytes,
                addr_bytes=addr_bytes,
                addr_modes=_addr_modes(addr_modes),
                jedec_id=jedec_id,
                electronic_id=None if electronic_id < 0 else electronic_id,
                sr1_default=sr1_default,
                sr2_default=sr2_default,
                sr3_default=sr3_default,
                busy_fs={key: _join_time(hi, lo) for key, (hi, lo) in busy.items()},
                timing_enabled=bool(timing_enabled),
            )

        # An invalid configuration is reported, and a default device keeps
        # the calls that follow harmless
        self.device = FlashDevice(self._guard("__init__", config, None) or FlashConfig())

    def _guard(self, method: str, fn: Callable[[], T], fallback: T) -> T:
        try:
            return fn()
        except ContentMismatch as exc:
            self.reports.add(Severity.ERROR, f"{self.name}: {exc}")
        except Exception as exc:
            self.reports.add(Severity.FAILURE, f"{self.name}: {method} raised {type(exc).__name__}: {exc}")
        return fallback

    def _control(self, method: str, fn: Callable[[], object]) -> int:
        self._guard(method, fn, None)
        return self.num_reports()

    # -- handshake and reports ---------------------------------------------

    def layout_version(self) -> int:
        """
        The packed directive layout; VHDL checks it against its own constant.

        Returns:
            :data:`~awesome_vunit_vcs.flash.directive.LAYOUT_VERSION`.
        """
        return LAYOUT_VERSION

    def num_reports(self) -> int:
        """
        The number of reports waiting.

        Returns:
            The number of reports :meth:`take_reports` would return.
        """
        return len(self.reports)

    def take_reports(self) -> str:
        """
        Take the waiting reports.

        Returns:
            The reports, encoded by :func:`~awesome_vunit_vcs.common.reports.encode_reports`.
        """
        return encode_reports(self.reports.take())

    # -- the wire ------------------------------------------------------------

    def cs_assert(self, hi: int, lo: int) -> int:
        """
        CS fell.

        Args:
            hi: The upper half of the simulation time in fs.
            lo: The lower half of the simulation time in fs.

        Returns:
            The packed directive for the first byte, or the ignore-rest
            directive after a failure report.
        """
        return self._guard("cs_assert", lambda: self.device.cs_assert(_join_time(hi, lo)), ignore_rest())

    def xfer(self, byte_in: int, hi: int = -1, lo: int = 0) -> int:
        """
        One byte moved on the wire.

        Args:
            byte_in: The byte received from the host, or -1 when the VC clocked
                a byte out.
            hi: The upper half of the simulation time in fs, or negative for no
                time, which is what VHDL sends unless the previous directive was
                volatile.
            lo: The lower half of the simulation time in fs.

        Returns:
            The packed directive for the next byte, or the ignore-rest
            directive after a failure report.
        """
        return self._guard(
            "xfer",
            lambda: self.device.xfer(byte_in, None if hi < 0 else _join_time(hi, lo)),
            ignore_rest(),
        )

    def cs_deassert(self, trailing_bits: int, hi: int, lo: int) -> npt.NDArray[np.int32]:
        """
        CS rose; the device executes the command.

        Args:
            trailing_bits: SCK cycles after the last whole byte.
            hi: The upper half of the simulation time in fs.
            lo: The lower half of the simulation time in fs.

        Returns:
            ``[busy_hi, busy_lo, num_reports]``, the halves of the busy time in
            fs being 0 when the command did not make the device busy.
        """
        busy_fs = self._guard("cs_deassert", lambda: self.device.cs_deassert(trailing_bits, _join_time(hi, lo)), 0)
        return _int32([*split_time(busy_fs), self.num_reports()])

    # -- control plane -------------------------------------------------------

    def reset(self, clear_statistics: bool = False) -> int:
        """
        Power-on reset of the volatile state, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.reset_state`.

        The array is untouched: a reset is not an erase. A reset while CS is
        low makes the device ignore the rest of that transaction.

        Args:
            clear_statistics: Also set the counters to 0 and forget the written
                regions, as :meth:`clear_statistics` does.

        Returns:
            The number of reports waiting.
        """

        def run() -> None:
            self.device.reset_state()
            if clear_statistics:
                self.device.clear_statistics()

        return self._control("reset", run)

    def preload(self, data: Any, addr: int) -> int:
        """
        Seed content, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.preload`.

        Args:
            data: Byte values, an ``integer_array_t``. A value outside 0 to 255
                is a failure report and nothing is written.
            addr: The address of the first byte. A range that is not inside
                the device is a failure report and nothing is written.

        Returns:
            The number of reports waiting.
        """
        return self._control("preload", lambda: self.device.preload(addr, _bytes(data)))

    def preload_fill(self, addr: int, num_bytes: int, value: int) -> int:
        """
        Seed a constant region, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.preload_fill`.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes, at least 1.
            value: The byte value. A value outside 0 to 255 is a failure report
                and nothing is written.

        Returns:
            The number of reports waiting.
        """
        return self._control("preload_fill", lambda: self.device.preload_fill(addr, num_bytes, value))

    def load_image(self, path: str, fmt: str, base: int) -> int:
        """
        Load an image file, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.load_image`.

        Args:
            path: The image file.
            fmt: The format, see :func:`~awesome_vunit_vcs.flash.images.format_for`;
                ``"auto"`` picks the format from the extension.
            base: The load address of a raw binary, an offset for the other formats.

        Returns:
            The number of reports waiting.
        """
        return self._control("load_image", lambda: self.device.load_image(path, None if fmt == "auto" else fmt, base))

    def read_back(self, addr: int, num_bytes: int) -> npt.NDArray[np.int32]:
        """
        Content as the array holds it.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes.

        Returns:
            The byte values, an empty array (and a failure report) when the
            range is not inside the device.
        """
        data = self._guard("read_back", lambda: self.device.read_back(addr, num_bytes), b"")
        return np.frombuffer(data, dtype=np.uint8).astype(np.int32)

    def check_content(self, expected: Any, addr: int) -> int:
        """
        Check content, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.check_content`.

        A mismatch is an error report, which VHDL logs on the VC checker.

        Args:
            expected: Byte values, an ``integer_array_t``.
            addr: The address of the first byte.

        Returns:
            The number of reports waiting.
        """
        return self._control("check_content", lambda: self.device.check_content(addr, _bytes(expected)))

    def check_content_fill(self, addr: int, num_bytes: int, value: int) -> int:
        """
        Check a constant region, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.check_content_fill`.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes, at least 1.
            value: The expected byte value. A value outside 0 to 255 is a
                failure report.

        Returns:
            The number of reports waiting.
        """
        return self._control("check_content_fill", lambda: self.device.check_content_fill(addr, num_bytes, value))

    def written_regions(self) -> npt.NDArray[np.int32]:
        """
        What the device programmed or erased, see :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.written_regions`.

        Returns:
            A flat ``[addr, length, addr, length, ...]`` array in bytes, coalesced.
        """
        no_regions: list[tuple[int, int]] = []
        regions = self._guard("written_regions", self.device.written_regions, no_regions)
        return _int32([value for region in regions for value in region])

    def clear_statistics(self) -> int:
        """
        Reset the counters and forget the written regions, see
        :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.clear_statistics`.

        Returns:
            The number of reports waiting.
        """
        return self._control("clear_statistics", self.device.clear_statistics)

    def set_timing_enable(self, enable: bool) -> int:
        """
        Enable or disable busy times; ``False`` collapses every busy time to zero.

        Disabling also ends a busy period that is running, from the last time
        VHDL sent, see
        :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.set_timing_enable`.

        Args:
            enable: Whether busy times apply.

        Returns:
            The number of reports waiting.
        """
        return self._control("set_timing_enable", lambda: self.device.set_timing_enable(bool(enable)))

    def set_timing(self, name: str, hi: int, lo: int) -> int:
        """
        Override one busy time. An unknown name or a negative time is a failure report.

        Args:
            name: A busy-time name of :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`.
            hi: The upper half of the busy time in fs.
            lo: The lower half of the busy time in fs.

        Returns:
            The number of reports waiting.
        """
        return self._control("set_timing", lambda: self.device.set_timing(name, _join_time(hi, lo)))

    def set_protection(self, addr: int, num_bytes: int, locked: bool) -> int:
        """
        Lock or unlock a region. A program or erase touching a locked region is silently ignored.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes.
            locked: True to lock, False to unlock.

        Returns:
            The number of reports waiting.
        """
        return self._control("set_protection", lambda: self.device.set_protection(addr, num_bytes, bool(locked)))

    def get_stat(self, name: str, hi: int = -1, lo: int = 0) -> int:
        """
        One counter or piece of observable state.

        This call returns the value rather than the number of reports, so VHDL
        checks :meth:`num_reports` afterwards to see a failure.

        Args:
            name: A name listed by :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.get_stat`.
            hi: The upper half of the simulation time in fs, or negative for no
                time. With a time, the device time first advances to it, see
                :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.advance_time`,
                so ``wip``, ``sr1`` and ``busy_remaining_us`` are current;
                without, they are evaluated at the last time VHDL sent.
            lo: The lower half of the simulation time in fs.

        Returns:
            The value. 0, with a failure report, for an unknown name, invalid
            time halves or a value a VHDL integer cannot hold.
        """

        def stat() -> int:
            if hi >= 0:
                self.device.advance_time(_join_time(hi, lo))
            value = self.device.get_stat(name)
            if not -(2**31) <= value < 2**31:
                raise FlashValueError(f"stat {name!r} = {value} does not fit a signed 32-bit integer")
            return value

        return self._guard("get_stat", stat, 0)
