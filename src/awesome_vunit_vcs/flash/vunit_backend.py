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
    reset()                               -> num_reports
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
    get_stat('<name>')                    -> integer

Errors never escape into the bridge. A content check that fails is a
:attr:`~awesome_vunit_vcs.common.reports.Severity.ERROR` report, which VHDL logs as a check
failure on the VC checker; any other exception (an invalid configuration,
a non-byte value, an unknown timing or stat name, a VC protocol bug) is a
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
from .device import ContentMismatch, FlashDevice
from .directive import LAYOUT_VERSION, ignore_rest

__all__ = ["FlashBackend"]

T = TypeVar("T")


def _int32(values: Any) -> npt.NDArray[np.int32]:
    """The array form every ``integer_array_t`` return value takes."""
    return np.array(values, dtype=np.int32).reshape(-1)


def _bytes(values: Any) -> bytes:
    """
    An ``integer_array_t`` of byte values from VHDL (a NumPy array, or any
    sequence of integers), checked.
    """
    array = np.array(values, dtype=np.int64).reshape(-1)
    bad = np.flatnonzero((array < 0) | (array > 0xFF))
    if bad.size:
        index = int(bad[0])
        raise ValueError(f"element {index} = {int(array[index])} is not a byte value")
    return array.astype(np.uint8).tobytes()


class FlashBackend:
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
                addr_modes=AddrModes(addr_modes),
                jedec_id=jedec_id,
                electronic_id=None if electronic_id < 0 else electronic_id,
                sr1_default=sr1_default,
                sr2_default=sr2_default,
                sr3_default=sr3_default,
                busy_fs={key: join_time(hi, lo) for key, (hi, lo) in busy.items()},
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
        """The packed directive layout; VHDL checks it against its own constant."""
        return LAYOUT_VERSION

    def num_reports(self) -> int:
        return len(self.reports)

    def take_reports(self) -> str:
        return encode_reports(self.reports.take())

    # -- the wire ------------------------------------------------------------

    def cs_assert(self, hi: int, lo: int) -> int:
        """CS fell at time (hi, lo). Returns the directive for the first byte."""
        return self._guard("cs_assert", lambda: self.device.cs_assert(join_time(hi, lo)), ignore_rest())

    def xfer(self, byte_in: int, hi: int = -1, lo: int = 0) -> int:
        """
        One byte moved on the wire; ``byte_in`` is -1 when the VC clocked a
        byte out. ``hi < 0`` means no time, which is what VHDL sends unless
        the previous directive was volatile.
        """
        return self._guard(
            "xfer",
            lambda: self.device.xfer(byte_in, None if hi < 0 else join_time(hi, lo)),
            ignore_rest(),
        )

    def cs_deassert(self, trailing_bits: int, hi: int, lo: int) -> npt.NDArray[np.int32]:
        """CS rose. Returns ``[busy_hi, busy_lo, num_reports]``, the busy time being 0 when the device is not busy."""
        busy_fs = self._guard("cs_deassert", lambda: self.device.cs_deassert(trailing_bits, join_time(hi, lo)), 0)
        return _int32([*split_time(busy_fs), self.num_reports()])

    # -- control plane -------------------------------------------------------

    def reset(self) -> int:
        """Power-on reset of the volatile state. The array is untouched: a reset is not an erase."""
        return self._control("reset", self.device.reset_state)

    def preload(self, data: Any, addr: int) -> int:
        return self._control("preload", lambda: self.device.preload(addr, _bytes(data)))

    def preload_fill(self, addr: int, num_bytes: int, value: int) -> int:
        return self._control("preload_fill", lambda: self.device.preload_fill(addr, num_bytes, value))

    def load_image(self, path: str, fmt: str, base: int) -> int:
        """Load a .hex/.srec/.s19/.bin/.json image; ``fmt`` "auto" picks the format from the extension."""
        return self._control("load_image", lambda: self.device.load_image(path, None if fmt == "auto" else fmt, base))

    def read_back(self, addr: int, num_bytes: int) -> npt.NDArray[np.int32]:
        """Content as the array holds it; an empty array when the request fails."""
        data = self._guard("read_back", lambda: self.device.read_back(addr, num_bytes), b"")
        return np.frombuffer(data, dtype=np.uint8).astype(np.int32)

    def check_content(self, expected: Any, addr: int) -> int:
        return self._control("check_content", lambda: self.device.check_content(addr, _bytes(expected)))

    def check_content_fill(self, addr: int, num_bytes: int, value: int) -> int:
        return self._control("check_content_fill", lambda: self.device.check_content_fill(addr, num_bytes, value))

    def written_regions(self) -> npt.NDArray[np.int32]:
        """Flat ``[addr, len, addr, len, ...]`` of everything the device programmed or erased, coalesced."""
        no_regions: list[tuple[int, int]] = []
        regions = self._guard("written_regions", self.device.written_regions, no_regions)
        return _int32([value for region in regions for value in region])

    def set_timing_enable(self, enable: bool) -> int:
        """``False`` collapses every busy time to zero."""
        return self._control("set_timing_enable", lambda: self.device.set_timing_enable(bool(enable)))

    def set_timing(self, name: str, hi: int, lo: int) -> int:
        return self._control("set_timing", lambda: self.device.set_timing(name, join_time(hi, lo)))

    def set_protection(self, addr: int, num_bytes: int, locked: bool) -> int:
        """Lock or unlock a region. A program or erase touching a locked region is silently ignored."""
        return self._control("set_protection", lambda: self.device.set_protection(addr, num_bytes, bool(locked)))

    def get_stat(self, name: str) -> int:
        """One counter or piece of observable state; 0 and a failure report for an unknown name."""
        return self._guard("get_stat", lambda: self.device.get_stat(name), 0)
