# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Configuration of one flash device.

Everything that differs between two QSPI NOR flashes the model supports --
geometry, JEDEC ID, power-up addressing mode, status register reset values
and busy times -- is a field of :class:`FlashConfig`, and every other module
reads it from there rather than hard-coding a number. The defaults are a
deliberately generic 16 MiB JEDEC part, so a testbench that does not care
about a specific part does not have to describe one.

The VHDL handle ``flash_t`` built by ``new_flash`` is the source of truth in
a simulation and has the same defaults; the backend receives its values when
it is created. Pin-level AC limits and output delays are used only by VHDL
and are not part of this configuration.

Times are integer femtoseconds, the resolution VHDL time has, so that no
rounding happens between the two sides.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import IntEnum
from types import MappingProxyType

KIB = 1024
MIB = 1024 * KIB

_US = 10**9
_MS = 10**12
_S = 10**15


class AddrModes(IntEnum):
    """Addressing modes advertised in SFDP. The values are what VHDL sends."""

    BOTH = 0
    THREE_ONLY = 3
    FOUR_ONLY = 4


#: Busy-time names, in the order a human thinks about them. A configuration
#: must give exactly these; ``set_timing`` rejects anything else, because
#: silently accepting "tPp" would leave the override with no effect and the
#: test quietly passing for the wrong reason.
BUSY_KEYS: tuple[str, ...] = (
    "tPP",  # page program
    "tSE",  # sector erase (4 KiB)
    "tBE32",  # block erase (32 KiB)
    "tBE64",  # block erase (64 KiB)
    "tCE",  # chip erase
    "tW",  # write status register
    "tRST",  # software reset recovery
    "tRES1",  # release from deep power-down to standby
    "tRES2",  # release from deep power-down with electronic ID read
)

#: Typical, not worst-case, busy times in femtoseconds. A testbench that wants
#: worst case overrides the one number it cares about.
DEFAULT_BUSY_FS: Mapping[str, int] = MappingProxyType(
    {
        "tPP": 700 * _US,
        "tSE": 45 * _MS,
        "tBE32": 120 * _MS,
        "tBE64": 150 * _MS,
        "tCE": 20 * _S,
        "tW": 10 * _MS,
        "tRST": 30 * _US,
        "tRES1": 3 * _US,
        "tRES2": 1800 * _US // 1000,
    }
)


def _is_power_of_two(value: int) -> bool:
    return value > 0 and value & (value - 1) == 0


@dataclass(frozen=True)
class FlashConfig:
    """
    Geometry, identification, status register defaults and busy times of one
    device. Invalid values raise :class:`ValueError` on construction.
    """

    size_bytes: int = 16 * MIB
    page_bytes: int = 256
    sector_bytes: int = 4 * KIB
    #: 0 means the device has no 32 KiB block erase
    block32_bytes: int = 32 * KIB
    block_bytes: int = 64 * KIB
    #: Addressing mode at power-up and after a reset, 3 or 4 bytes
    addr_bytes: int = 3
    addr_modes: AddrModes = AddrModes.BOTH
    jedec_id: int = 0xEF4018
    #: The one-byte ID returned by 0xAB; None derives it from the capacity code
    electronic_id: int | None = None
    sr1_default: int = 0x00
    #: QE is set, so quad commands work without writing SR2 first
    sr2_default: int = 0x02
    sr3_default: int = 0x00
    busy_fs: Mapping[str, int] = field(default_factory=lambda: dict(DEFAULT_BUSY_FS))
    #: Initial state of the busy timing; it can be switched at run time
    timing_enabled: bool = True

    def __post_init__(self) -> None:
        # A plain copy, so that the frozen instance does not alias the caller's mapping
        object.__setattr__(self, "busy_fs", dict(self.busy_fs))
        try:
            object.__setattr__(self, "addr_modes", AddrModes(self.addr_modes))
        except ValueError:
            raise ValueError(f"addr_modes={self.addr_modes} must be one of {[int(m) for m in AddrModes]}") from None
        self._validate_geometry()
        self._validate_identity()
        self._validate_busy()

    def _validate_geometry(self) -> None:
        size, page = self.size_bytes, self.page_bytes
        if not _is_power_of_two(size):
            raise ValueError(f"size_bytes={size} must be a positive power of two")
        if not _is_power_of_two(page):
            raise ValueError(f"page_bytes={page} must be a positive power of two")
        if size % page:
            raise ValueError(f"size_bytes={size} is not a multiple of page_bytes={page}")
        for name in ("sector_bytes", "block32_bytes", "block_bytes"):
            value = getattr(self, name)
            if name == "block32_bytes" and value == 0:
                continue
            if not _is_power_of_two(value) or size % value:
                raise ValueError(f"{name}={value} must be a power of two dividing the device")
        if self.addr_bytes not in (3, 4):
            raise ValueError(f"addr_bytes={self.addr_bytes} must be 3 or 4")
        if self.addr_modes is AddrModes.THREE_ONLY and self.addr_bytes != 3:
            raise ValueError(f"addr_modes=THREE_ONLY contradicts addr_bytes={self.addr_bytes}")
        if self.addr_modes is AddrModes.FOUR_ONLY and self.addr_bytes != 4:
            raise ValueError(f"addr_modes=FOUR_ONLY contradicts addr_bytes={self.addr_bytes}")

    def _validate_identity(self) -> None:
        if not 0 <= self.jedec_id <= 0xFFFFFF:
            raise ValueError(f"jedec_id=0x{self.jedec_id:x} must fit 24 bits")
        if self.electronic_id is not None and not 0 <= self.electronic_id <= 0xFF:
            raise ValueError(f"electronic_id={self.electronic_id} must be a byte value or None")
        for name in ("sr1_default", "sr2_default", "sr3_default"):
            value = getattr(self, name)
            if not 0 <= value <= 0xFF:
                raise ValueError(f"{name}={value} must be a byte value")

    def _validate_busy(self) -> None:
        missing = [key for key in BUSY_KEYS if key not in self.busy_fs]
        if missing:
            raise ValueError(f"busy_fs is missing busy times: {missing}")
        unknown = sorted(set(self.busy_fs) - set(BUSY_KEYS))
        if unknown:
            raise ValueError(f"busy_fs has unknown busy times: {unknown}; known: {list(BUSY_KEYS)}")
        for key, value in self.busy_fs.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(f"busy time {key}={value!r} must be a non-negative integer number of femtoseconds")

    def jedec_id_bytes(self) -> bytes:
        """Manufacturer, memory type, capacity: the three bytes 0x9F clocks out, most significant first."""
        return self.jedec_id.to_bytes(3, "big")

    def device_id(self) -> int:
        """
        The legacy one-byte device ID returned by 0xAB, derived from the
        capacity code so it cannot contradict the JEDEC ID unless given.
        """
        if self.electronic_id is not None:
            return self.electronic_id & 0xFF
        return ((self.jedec_id & 0xFF) - 1) & 0xFF
