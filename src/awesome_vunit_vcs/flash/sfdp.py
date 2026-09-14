# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A minimal but structurally valid JESD216 SFDP image.

Enough for a discovery driver to walk: the "SFDP" signature, one parameter
header for the JEDEC Basic Flash Parameter Table, and a 9-dword basic table
whose density, erase-type and fast-read fields are *computed from the
configuration and the opcode table* rather than typed in. That is the point of
the module -- an SFDP blob copied from a datasheet drifts away from the
model it is supposed to describe, and a driver that trusts SFDP then
mis-drives the model with no test failing. Here the two cannot disagree,
because the erase sizes and opcodes in DWORD 8 and 9 are literally looked up
in :data:`~awesome_vunit_vcs.flash.commands.COMMAND_TABLE`, resolved against
the configuration.

Layout, with offsets in bytes::

    0x00  SFDP header        (8 bytes)
    0x08  parameter header 0 (8 bytes, JEDEC basic, points at 0x10)
    0x10  basic flash parameter table (9 dwords)

Everything outside that reads 0xFF, like the unimplemented rest of any real
part's SFDP space.
"""

from __future__ import annotations

from .commands import erase_opcode_for
from .config import AddrModes, FlashConfig
from .errors import FlashValueError

#: The four signature bytes at offset 0
SFDP_SIGNATURE = b"SFDP"
#: Byte offset of the SFDP header
SFDP_HEADER_OFFSET = 0x00
#: Byte offset of the first parameter header
PARAM_HEADER_OFFSET = 0x08
#: Byte offset of the basic flash parameter table
PARAM_TABLE_OFFSET = 0x10
#: Length of the basic flash parameter table in dwords
BASIC_TABLE_DWORDS = 9

# JESD216 (1.0) revision numbers. Kept at 1.0 because the table below is the
# original 9-dword basic table; claiming a later minor revision would
# promise dwords that are not here.
#: JESD216 major revision
SFDP_MAJOR = 0x01
#: JESD216 minor revision
SFDP_MINOR = 0x00

#: A dword whose bits are all reserved or unsupported
UNUSED_DWORD = 0xFFFFFFFF


def _log2_exact(value: int, what: str) -> int:
    if value <= 0 or value & (value - 1):
        raise FlashValueError(f"{what}={value} must be a power of two")
    return value.bit_length() - 1


def _dword(fields: list[tuple[int, int, int]], default: int = 0) -> int:
    """Assemble a dword from ``(shift, width, value)`` triples, checking each
    value fits. ``default`` seeds the reserved bits (0xFFFFFFFF where JESD216
    says reserved-ones)."""
    word = default
    for shift, width, value in fields:
        mask = (1 << width) - 1
        if not 0 <= value <= mask:
            raise FlashValueError(f"SFDP field at shift {shift} does not fit {width} bits")
        word = (word & ~(mask << shift)) | (value << shift)
    return word & 0xFFFFFFFF


def _erase_type(size_bytes: int | None, config: FlashConfig) -> tuple[int, int]:
    """``(size exponent, opcode)`` for one erase-type slot, or the
    "unsupported" encoding (0, 0xFF) when the device has no such
    granularity."""
    if not size_bytes:
        return 0, 0xFF
    opcode = erase_opcode_for(size_bytes, config)
    if opcode is None:
        return 0, 0xFF
    return _log2_exact(size_bytes, "erase size"), opcode


def basic_parameter_table(config: FlashConfig) -> list[int]:
    """
    The JEDEC basic flash parameter table of a configuration.

    It advertises the 4 KiB erase opcode when an erase of exactly 4 KiB
    exists, the addressing modes of
    :attr:`~awesome_vunit_vcs.flash.config.FlashConfig.addr_modes`, the
    density, the (1-1-2), (1-2-2), (1-1-4), (1-4-4) and (4-4-4) fast reads,
    and erase types for ``sector_bytes`` (0x20), ``block32_bytes`` (0x52,
    unsupported when 0) and ``block_bytes`` (0xD8).

    Args:
        config: The device configuration.

    Returns:
        The 9 dwords, DWORD 1 first.
    """
    size_bytes = config.size_bytes
    sector = config.sector_bytes
    block32 = config.block32_bytes or None
    block = config.block_bytes
    erase_4kib_op = erase_opcode_for(4096, config)
    # 0b01 = a 4 KiB erase exists; 0b11 = it does not, and its opcode is 0xFF
    erase_4kib = 0b11 if erase_4kib_op is None else 0b01
    # 0b01 = both 3- and 4-byte addressing; 0b00 = 3 only; 0b10 = 4 only.
    addr_modes = {AddrModes.THREE_ONLY: 0b00, AddrModes.FOUR_ONLY: 0b10}.get(config.addr_modes, 0b01)

    dword1 = _dword(
        [
            (0, 2, erase_4kib),  # uniform 4 KiB erase availability
            (2, 1, 1),  # write granularity >= 64 bytes (page buffer)
            (3, 1, 0),  # volatile status write enable not required
            (4, 1, 0),  # write enable opcode = 0x06
            (5, 3, 0b111),  # reserved
            (8, 8, 0xFF if erase_4kib_op is None else erase_4kib_op),  # 4 KiB erase opcode
            (16, 1, 1),  # supports (1-1-2)
            (17, 2, addr_modes),
            (19, 1, 0),  # no DTR
            (20, 1, 1),  # supports (1-2-2)
            (21, 1, 1),  # supports (1-4-4)
            (22, 1, 1),  # supports (1-1-4)
            (23, 1, 1),  # reserved
            (24, 8, 0xFF),  # reserved
        ]
    )

    # Densities up to 2 Gbit are expressed as (bits - 1) with bit 31 clear.
    bits = size_bytes * 8
    dword2 = (1 << 31) | _log2_exact(bits, "density") if bits > (1 << 31) else bits - 1

    dword3 = _dword(
        [
            (0, 5, 4),  # (1-4-4) dummy clocks, 0xEB
            (5, 3, 2),  # (1-4-4) mode clocks: one byte over four lanes
            (8, 8, 0xEB),
            (16, 5, 8),  # (1-1-4) dummy clocks, 0x6B
            (21, 3, 0),
            (24, 8, 0x6B),
        ]
    )
    dword4 = _dword(
        [
            (0, 5, 8),  # (1-1-2) dummy clocks, 0x3B
            (5, 3, 0),
            (8, 8, 0x3B),
            (16, 5, 0),  # (1-2-2) has no dummy clocks, 0xBB
            (21, 3, 4),  # mode byte over two lanes = four clocks
            (24, 8, 0xBB),
        ]
    )
    dword5 = _dword(
        [
            (0, 1, 0),  # (2-2-2) not supported
            (4, 1, 1),  # (4-4-4) supported: QPI
        ],
        default=UNUSED_DWORD,
    )
    dword6 = UNUSED_DWORD  # (2-2-2) parameters: unsupported
    dword7 = _dword(
        [
            (16, 5, 4),  # (4-4-4) dummy clocks
            (21, 3, 2),  # (4-4-4) mode clocks
            (24, 8, 0xEB),
        ],
        default=0x0000FFFF,
    )

    e1_size, e1_op = _erase_type(sector, config)
    e2_size, e2_op = _erase_type(block32, config)
    e3_size, e3_op = _erase_type(block, config)
    e4_size, e4_op = _erase_type(None, config)
    dword8 = _dword([(0, 8, e1_size), (8, 8, e1_op), (16, 8, e2_size), (24, 8, e2_op)])
    dword9 = _dword([(0, 8, e3_size), (8, 8, e3_op), (16, 8, e4_size), (24, 8, e4_op)])

    return [dword1, dword2, dword3, dword4, dword5, dword6, dword7, dword8, dword9]


def build(config: FlashConfig) -> bytes:
    """
    The whole SFDP image of a configuration.

    Args:
        config: The device configuration.

    Returns:
        The SFDP header, one parameter header and the basic parameter table,
        52 bytes.

    """
    table = basic_parameter_table(config)
    image = bytearray()
    # -- SFDP header ---------------------------------------------------
    image += SFDP_SIGNATURE
    image.append(SFDP_MINOR)
    image.append(SFDP_MAJOR)
    image.append(0x00)  # NPH: number of parameter headers, minus one
    image.append(0xFF)  # access protocol / reserved
    # -- parameter header 0: JEDEC basic flash parameters ---------------
    image.append(0x00)  # ID LSB
    image.append(SFDP_MINOR)
    image.append(SFDP_MAJOR)
    image.append(len(table))  # length in dwords
    image += PARAM_TABLE_OFFSET.to_bytes(3, "little")
    image.append(0xFF)  # ID MSB -> 0xFF00 = JEDEC
    assert len(image) == PARAM_TABLE_OFFSET
    for dword in table:
        image += dword.to_bytes(4, "little")
    return bytes(image)


def read(image: bytes, addr: int, length: int) -> bytes:
    """
    Read SFDP space.

    The unimplemented space reads 0xFF and there is no wrap -- a driver
    walking off the end gets 0xFF, exactly like silicon.

    Args:
        image: The SFDP image, see :func:`build`.
        addr: The first byte to read.
        length: The number of bytes to read.

    Returns:
        ``length`` bytes.
    """
    out = bytearray()
    for offset in range(addr, addr + length):
        out.append(image[offset] if 0 <= offset < len(image) else 0xFF)
    return bytes(out)
