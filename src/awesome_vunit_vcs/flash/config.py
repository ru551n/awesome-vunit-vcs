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

Sizes are in bytes. Times are integer femtoseconds (fs), the resolution VHDL
time has, so that no rounding happens between the two sides.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import IntEnum
from types import MappingProxyType

from .errors import FlashValueError

#: One kibibyte, in bytes
KIB = 1024
#: One mebibyte, in bytes
MIB = 1024 * KIB

_US = 10**9
_MS = 10**12
_S = 10**15


class AddrModes(IntEnum):
    """
    Addressing modes of a device, advertised in SFDP. The values are what VHDL sends.

    A 3-byte-only device ignores EN4B (0xB7), EX4B (0xE9) and every opcode
    with a fixed 4-byte address as unknown opcodes. A 4-byte-only device
    ignores EX4B, so it never leaves 4-byte addressing.
    """

    #: 3- and 4-byte addressing
    BOTH = 0
    #: 3-byte addressing only; requires ``addr_bytes=3``
    THREE_ONLY = 3
    #: 4-byte addressing only; requires ``addr_bytes=4``
    FOUR_ONLY = 4


#: Busy-time names, in the order a human thinks about them. ``tPP`` is page
#: program, ``tSE`` sector erase (0x20), ``tBE32`` small block erase (0x52),
#: ``tBE64`` block erase (0xD8), ``tCE`` chip erase, ``tW`` write status register,
#: ``tRST`` software reset recovery, ``tRES1`` release from deep power-down and
#: ``tRES2`` release from deep power-down with an electronic ID read.
#:
#: :attr:`FlashConfig.busy_fs` must give exactly these names, and
#: :meth:`~awesome_vunit_vcs.flash.timing.Timing.set_busy` rejects any other,
#: because silently accepting "tPp" would leave the override with no effect
#: and the test quietly passing for the wrong reason.
BUSY_KEYS: tuple[str, ...] = (
    "tPP",  # page program
    "tSE",  # sector erase
    "tBE32",  # small block erase
    "tBE64",  # block erase
    "tCE",  # chip erase
    "tW",  # write status register
    "tRST",  # software reset recovery
    "tRES1",  # release from deep power-down to standby
    "tRES2",  # release from deep power-down with electronic ID read
)

#: Typical rather than worst-case busy times in femtoseconds. ``tPP`` is 0.7 ms,
#: ``tSE`` 45 ms, ``tBE32`` 120 ms, ``tBE64`` 150 ms, ``tCE`` 20 s, ``tW`` 10 ms,
#: ``tRST`` 30 us, ``tRES1`` 3 us and ``tRES2`` 1.8 us (us is microseconds). A
#: testbench that wants worst case overrides the one number it cares about.
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
    Geometry, identification, status register defaults and busy times of one device.

    Attributes:
        size_bytes: Capacity in bytes, a power of two. The default is 16 MiB.
        page_bytes: Page size in bytes, a power of two dividing ``size_bytes``.
            One page program writes at most one page.
        sector_bytes: The bytes 0x20 erases, a power of two dividing the
            device, at least ``page_bytes`` and less than the block sizes.
        block32_bytes: The bytes 0x52 erases, a power of two dividing the
            device between ``sector_bytes`` and ``block_bytes``, or 0 for a
            device without this erase, which then ignores 0x52 as an
            unknown opcode.
        block_bytes: The bytes 0xD8 and 0xDC erase, a power of two dividing
            the device, larger than the other erase sizes and at most
            ``size_bytes``.
        addr_bytes: Addressing mode at power-up and after a reset, 3 or 4 bytes.
        addr_modes: The addressing modes advertised in SFDP, see :class:`AddrModes`.
        jedec_id: The 24-bit manufacturer, memory type and capacity ID that
            0x9F returns.
        electronic_id: The one-byte ID returned by 0xAB, or None to derive it
            from the capacity code, see :meth:`device_id`.
        sr1_default: Status register 1 after power-up and reset. WIP (bit 0)
            and WEL (bit 1) are derived and ignored here.
        sr2_default: Status register 2 after power-up and reset. The default
            sets QE (bit 1), so quad commands work without writing SR2 first.
        sr3_default: Status register 3 after power-up and reset. ADS (bit 0)
            follows the addressing mode and is ignored here.
        busy_fs: Busy time of each name in :data:`BUSY_KEYS`, in fs. The
            mapping must have exactly those keys, with non-negative integer
            values; it is copied.
        timing_enabled: Initial state of the busy timing; it can be switched at
            run time.

    Raises:
        FlashValueError: A value is out of range: a size that is not a power of two
            or does not divide the device, an erase size below ``page_bytes``
            or out of order, ``addr_bytes`` other than 3 or 4 or
            contradicting ``addr_modes``, a JEDEC ID wider than 24 bits, an
            electronic ID or status register default that is not a byte, or
            busy times with missing, unknown or negative entries.
    """

    size_bytes: int = 16 * MIB
    page_bytes: int = 256
    sector_bytes: int = 4 * KIB
    block32_bytes: int = 32 * KIB
    block_bytes: int = 64 * KIB
    addr_bytes: int = 3
    addr_modes: AddrModes = AddrModes.BOTH
    jedec_id: int = 0xEF4018
    electronic_id: int | None = None
    sr1_default: int = 0x00
    sr2_default: int = 0x02
    sr3_default: int = 0x00
    busy_fs: Mapping[str, int] = field(default_factory=lambda: dict(DEFAULT_BUSY_FS))
    timing_enabled: bool = True

    def __post_init__(self) -> None:
        # A plain copy, so that the frozen instance does not alias the caller's mapping
        object.__setattr__(self, "busy_fs", dict(self.busy_fs))
        try:
            object.__setattr__(self, "addr_modes", AddrModes(self.addr_modes))
        except ValueError:
            raise FlashValueError(
                f"addr_modes={self.addr_modes} must be one of {[int(m) for m in AddrModes]}"
            ) from None
        self._validate_geometry()
        self._validate_identity()
        self._validate_busy()

    def _validate_geometry(self) -> None:
        size, page = self.size_bytes, self.page_bytes
        if not _is_power_of_two(size):
            raise FlashValueError(f"size_bytes={size} must be a positive power of two")
        if not _is_power_of_two(page):
            raise FlashValueError(f"page_bytes={page} must be a positive power of two")
        if size % page:
            raise FlashValueError(f"size_bytes={size} is not a multiple of page_bytes={page}")
        for name in ("sector_bytes", "block32_bytes", "block_bytes"):
            value = getattr(self, name)
            if name == "block32_bytes" and value == 0:
                continue
            if not _is_power_of_two(value) or size % value:
                raise FlashValueError(f"{name}={value} must be a power of two dividing the device")
            if value < page:
                raise FlashValueError(f"{name}={value} must be at least page_bytes={page}")
        sector, block32, block = self.sector_bytes, self.block32_bytes, self.block_bytes
        if block32 and not sector < block32 < block:
            raise FlashValueError(
                f"block32_bytes={block32} must be larger than sector_bytes={sector} "
                f"and smaller than block_bytes={block}"
            )
        if not sector < block:
            raise FlashValueError(f"sector_bytes={sector} must be smaller than block_bytes={block}")
        if self.addr_bytes not in (3, 4):
            raise FlashValueError(f"addr_bytes={self.addr_bytes} must be 3 or 4")
        if self.addr_modes is AddrModes.THREE_ONLY and self.addr_bytes != 3:
            raise FlashValueError(f"addr_modes=THREE_ONLY contradicts addr_bytes={self.addr_bytes}")
        if self.addr_modes is AddrModes.FOUR_ONLY and self.addr_bytes != 4:
            raise FlashValueError(f"addr_modes=FOUR_ONLY contradicts addr_bytes={self.addr_bytes}")

    def _validate_identity(self) -> None:
        if not 0 <= self.jedec_id <= 0xFFFFFF:
            raise FlashValueError(f"jedec_id=0x{self.jedec_id:x} must fit 24 bits")
        if self.electronic_id is not None and not 0 <= self.electronic_id <= 0xFF:
            raise FlashValueError(f"electronic_id={self.electronic_id} must be a byte value or None")
        for name in ("sr1_default", "sr2_default", "sr3_default"):
            value = getattr(self, name)
            if not 0 <= value <= 0xFF:
                raise FlashValueError(f"{name}={value} must be a byte value")

    def _validate_busy(self) -> None:
        missing = [key for key in BUSY_KEYS if key not in self.busy_fs]
        if missing:
            raise FlashValueError(f"busy_fs is missing busy times: {missing}")
        unknown = sorted(set(self.busy_fs) - set(BUSY_KEYS))
        if unknown:
            raise FlashValueError(f"busy_fs has unknown busy times: {unknown}; known: {list(BUSY_KEYS)}")
        for key, value in self.busy_fs.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise FlashValueError(
                    f"busy time {key}={value!r} must be a non-negative integer number of femtoseconds"
                )

    def jedec_id_bytes(self) -> bytes:
        """
        The JEDEC ID as 0x9F clocks it out.

        Returns:
            Manufacturer, memory type and capacity, three bytes, most significant first.
        """
        return self.jedec_id.to_bytes(3, "big")

    def device_id(self) -> int:
        """
        The legacy one-byte electronic ID returned by 0xAB.

        Returns:
            :attr:`electronic_id` when given, otherwise the capacity code (the
            last byte of :attr:`jedec_id`) minus one, so that it cannot
            contradict the JEDEC ID. The default 0xEF4018 gives 0x17.
        """
        if self.electronic_id is not None:
            return self.electronic_id & 0xFF
        return ((self.jedec_id & 0xFF) - 1) & 0xFF
