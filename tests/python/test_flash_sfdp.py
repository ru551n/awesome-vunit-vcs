# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""SFDP: structurally valid, and -- the part that actually matters --
agreeing with the configuration and the opcode table it was built from."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash import sfdp
from awesome_vunit_vcs.flash.commands import COMMANDS, lookup
from awesome_vunit_vcs.flash.config import KIB, MIB, AddrModes, FlashConfig


def dwords(config: FlashConfig) -> list[int]:
    return sfdp.basic_parameter_table(config)


def test_signature_and_header() -> None:
    image = sfdp.build(FlashConfig())
    assert image[0:4] == b"SFDP"
    assert image[4] == sfdp.SFDP_MINOR
    assert image[5] == sfdp.SFDP_MAJOR
    assert image[6] == 0x00  # one parameter header (NPH is "minus one")


def test_parameter_header_points_at_the_basic_table() -> None:
    image = sfdp.build(FlashConfig())
    header = image[sfdp.PARAM_HEADER_OFFSET : sfdp.PARAM_HEADER_OFFSET + 8]
    assert header[0] == 0x00 and header[7] == 0xFF  # JEDEC basic, ID 0xFF00
    assert header[3] == sfdp.BASIC_TABLE_DWORDS
    pointer = int.from_bytes(header[4:7], "little")
    assert pointer == sfdp.PARAM_TABLE_OFFSET
    assert len(image) == pointer + 4 * sfdp.BASIC_TABLE_DWORDS


@pytest.mark.parametrize(
    "config",
    [
        FlashConfig(),
        FlashConfig(size_bytes=4 * MIB, jedec_id=0xEF4016),
        FlashConfig(size_bytes=32 * MIB, jedec_id=0x20BA19),
    ],
    ids=["16mib", "4mib", "32mib"],
)
def test_density_agrees_with_the_config(config: FlashConfig) -> None:
    density = dwords(config)[1]
    assert density >> 31 == 0, "these parts are all under 2 Gbit"
    assert density + 1 == config.size_bytes * 8


def test_erase_types_agree_with_the_command_table() -> None:
    table = dwords(FlashConfig())
    types = [
        (table[7] & 0xFF, (table[7] >> 8) & 0xFF),
        ((table[7] >> 16) & 0xFF, (table[7] >> 24) & 0xFF),
        (table[8] & 0xFF, (table[8] >> 8) & 0xFF),
    ]
    assert types[0] == (12, 0x20)  # 4 KiB
    assert types[1] == (15, 0x52)  # 32 KiB
    assert types[2] == (16, 0xD8)  # 64 KiB
    for exponent, opcode in types:
        assert COMMANDS[opcode].erase_size(FlashConfig()) == 1 << exponent
    # The unused fourth slot is the "no such erase type" encoding.
    assert ((table[8] >> 16) & 0xFF, (table[8] >> 24) & 0xFF) == (0, 0xFF)


def test_dword1_advertises_what_the_model_implements() -> None:
    table = dwords(FlashConfig())
    dword1 = table[0]
    assert dword1 & 0b11 == 0b01  # uniform 4 KiB erase
    assert (dword1 >> 8) & 0xFF == 0x20  # and its opcode
    assert (dword1 >> 16) & 1  # 1-1-2 (0x3B)
    assert (dword1 >> 20) & 1  # 1-2-2 (0xBB)
    assert (dword1 >> 21) & 1  # 1-4-4 (0xEB)
    assert (dword1 >> 22) & 1  # 1-1-4 (0x6B)
    assert (dword1 >> 17) & 0b11 == 0b01  # both 3- and 4-byte addressing


def test_fast_read_dummy_cycles_match_the_command_table() -> None:
    table = dwords(FlashConfig())
    assert (table[2] & 0x1F, (table[2] >> 8) & 0xFF) == (COMMANDS[0xEB].dummy_cycles, 0xEB)
    assert ((table[2] >> 16) & 0x1F, (table[2] >> 24) & 0xFF) == (
        COMMANDS[0x6B].dummy_cycles,
        0x6B,
    )
    assert (table[3] & 0x1F, (table[3] >> 8) & 0xFF) == (COMMANDS[0x3B].dummy_cycles, 0x3B)
    assert ((table[3] >> 16) & 0x1F, (table[3] >> 24) & 0xFF) == (
        COMMANDS[0xBB].dummy_cycles,
        0xBB,
    )


def test_qpi_support_is_advertised() -> None:
    table = dwords(FlashConfig())
    assert (table[4] >> 4) & 1  # supports 4-4-4
    assert not table[4] & 1  # does not claim 2-2-2, which the model lacks


def test_reads_past_the_table_return_0xff() -> None:
    image = sfdp.build(FlashConfig())
    assert sfdp.read(image, len(image), 4) == b"\xff" * 4
    tail = sfdp.read(image, len(image) - 2, 4)
    assert tail[2:] == b"\xff\xff"
    assert sfdp.read(image, 0, 4) == b"SFDP"


def erase_types(table: list[int]) -> list[tuple[int, int]]:
    return [
        (table[7] & 0xFF, (table[7] >> 8) & 0xFF),
        ((table[7] >> 16) & 0xFF, (table[7] >> 24) & 0xFF),
        (table[8] & 0xFF, (table[8] >> 8) & 0xFF),
        ((table[8] >> 16) & 0xFF, (table[8] >> 24) & 0xFF),
    ]


def test_erase_types_follow_a_non_default_geometry() -> None:
    config = FlashConfig(sector_bytes=8 * KIB, block32_bytes=16 * KIB, block_bytes=128 * KIB)
    table = dwords(config)
    assert erase_types(table) == [(13, 0x20), (14, 0x52), (17, 0xD8), (0, 0xFF)]
    for exponent, opcode in erase_types(table)[:3]:
        assert COMMANDS[opcode].erase_size(config) == 1 << exponent
    # No opcode erases exactly 4 KiB, so DWORD 1 says so
    assert table[0] & 0b11 == 0b11
    assert (table[0] >> 8) & 0xFF == 0xFF


def test_a_1kib_sector_is_advertised_with_its_opcode() -> None:
    config = FlashConfig(sector_bytes=1 * KIB)
    assert erase_types(dwords(config))[0] == (10, 0x20)


@pytest.mark.parametrize(
    ("config", "field"),
    [
        (FlashConfig(), 0b01),
        (FlashConfig(addr_modes=AddrModes.THREE_ONLY), 0b00),
        (FlashConfig(size_bytes=32 * MIB, addr_bytes=4, addr_modes=AddrModes.FOUR_ONLY), 0b10),
    ],
    ids=["both", "three_only", "four_only"],
)
def test_dword1_advertises_the_configured_addressing(config: FlashConfig, field: int) -> None:
    assert (dwords(config)[0] >> 17) & 0b11 == field


def test_a_config_without_32kib_blocks_advertises_no_such_erase_type() -> None:
    table = dwords(FlashConfig(block32_bytes=0))
    assert ((table[7] >> 16) & 0xFF, (table[7] >> 24) & 0xFF) == (0, 0xFF)


@pytest.mark.parametrize(
    "config",
    [
        FlashConfig(),
        FlashConfig(addr_modes=AddrModes.THREE_ONLY),
        FlashConfig(size_bytes=32 * MIB, addr_bytes=4, addr_modes=AddrModes.FOUR_ONLY),
        FlashConfig(block32_bytes=0),
    ],
    ids=["both", "three_only", "four_only", "no_block32"],
)
def test_every_advertised_opcode_is_supported_by_the_device(config: FlashConfig) -> None:
    table = dwords(config)
    opcodes = [(table[0] >> 8) & 0xFF, table[2] >> 8 & 0xFF, table[2] >> 24, table[3] >> 8 & 0xFF, table[3] >> 24]
    opcodes += [opcode for _, opcode in erase_types(table) if opcode != 0xFF]
    for opcode in opcodes:
        assert lookup(opcode, config) is not None, f"SFDP advertises unsupported 0x{opcode:02X}"


def _le32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def test_the_default_config_matches_jesd216_byte_for_byte() -> None:
    """
    The whole SFDP image of the default FlashConfig: 16 MiB, 4 KiB sectors,
    32 and 64 KiB blocks, 3-byte addressing at power-up with both modes.

    Every value is written from the JESD216 (revision 1.0) field
    definitions, not from the model, so a wrong field in sfdp.py fails here.
    """
    header = bytes(
        [
            0x53, 0x46, 0x44, 0x50,  # signature "SFDP"
            0x00,  # SFDP minor revision: JESD216 1.0
            0x01,  # SFDP major revision
            0x00,  # number of parameter headers, zero based: one header
            0xFF,  # unused in JESD216 1.0 (access protocol 0xFF, legacy, in later revisions)
        ]
    )  # fmt: skip
    parameter_header = bytes(
        [
            0x00,  # parameter ID LSB: 0x00, the JEDEC basic flash parameter table
            0x00,  # parameter table minor revision
            0x01,  # parameter table major revision
            0x09,  # parameter table length: 9 DWORDs, the JESD216 1.0 basic table
            0x10, 0x00, 0x00,  # parameter table pointer, 3 bytes little endian: 0x000010
            0xFF,  # parameter ID MSB: 0xFF, so the ID is 0xFF00 (JEDEC)
        ]
    )  # fmt: skip
    # DWORD 1
    #   bits 1:0   01    4 KiB erase supported uniformly
    #   bit 2      1     write granularity of 64 bytes or more (256-byte page buffer)
    #   bit 3      0     block protect bits not solely volatile
    #   bit 4      0     required to be 0 when bit 3 is 0 (would select 0x50 or 0x06)
    #   bits 7:5   111   unused
    #   bits 15:8  0x20  4 KiB erase opcode
    #   bit 16     1     (1-1-2) fast read
    #   bits 18:17 01    3- or 4-byte addressing
    #   bit 19     0     no double transfer rate clocking
    #   bit 20     1     (1-2-2) fast read
    #   bit 21     1     (1-4-4) fast read
    #   bit 22     1     (1-1-4) fast read
    #   bit 23     1     unused
    #   bits 31:24 0xFF  unused
    dword1 = 0xFFF320E5
    # DWORD 2: bit 31 = 0, bits 30:0 = density in bits - 1 = 16 MiB * 8 - 1
    dword2 = 0x07FFFFFF
    # DWORD 3
    #   bits 4:0   4     (1-4-4) wait states (dummy clocks)
    #   bits 7:5   2     (1-4-4) mode clocks: the mode byte over four lanes
    #   bits 15:8  0xEB  (1-4-4) opcode
    #   bits 20:16 8     (1-1-4) wait states
    #   bits 23:21 0     (1-1-4) mode clocks
    #   bits 31:24 0x6B  (1-1-4) opcode
    dword3 = 0x6B08EB44
    # DWORD 4
    #   bits 4:0   8     (1-1-2) wait states
    #   bits 7:5   0     (1-1-2) mode clocks
    #   bits 15:8  0x3B  (1-1-2) opcode
    #   bits 20:16 0     (1-2-2) wait states
    #   bits 23:21 4     (1-2-2) mode clocks: the mode byte over two lanes
    #   bits 31:24 0xBB  (1-2-2) opcode
    dword4 = 0xBB803B08
    # DWORD 5
    #   bit 0      0     no (2-2-2) fast read
    #   bits 3:1   111   reserved
    #   bit 4      1     (4-4-4) fast read
    #   bits 31:5  all 1 reserved
    dword5 = 0xFFFFFFFE
    # DWORD 6
    #   bits 15:0  0xFFFF reserved
    #   bits 31:16 0xFFFF (2-2-2) wait states, mode clocks and opcode; not
    #                     supported (DWORD 5 bit 0), so all ones
    dword6 = 0xFFFFFFFF
    # DWORD 7
    #   bits 15:0  0xFFFF reserved
    #   bits 20:16 4     (4-4-4) wait states
    #   bits 23:21 2     (4-4-4) mode clocks
    #   bits 31:24 0xEB  (4-4-4) opcode
    dword7 = 0xEB44FFFF
    # DWORD 8
    #   bits 7:0   12    erase type 1 size, 2**12 = 4 KiB
    #   bits 15:8  0x20  erase type 1 opcode
    #   bits 23:16 15    erase type 2 size, 2**15 = 32 KiB
    #   bits 31:24 0x52  erase type 2 opcode
    dword8 = 0x520F200C
    # DWORD 9
    #   bits 7:0   16    erase type 3 size, 2**16 = 64 KiB
    #   bits 15:8  0xD8  erase type 3 opcode
    #   bits 23:16 0     erase type 4 size: 0, the erase type does not exist
    #   bits 31:24 0xFF  erase type 4 opcode, unused
    dword9 = 0xFF00D810
    table = b"".join(_le32(dword) for dword in (dword1, dword2, dword3, dword4, dword5, dword6, dword7, dword8, dword9))
    expected = header + parameter_header + table
    assert len(expected) == 52

    image = sfdp.build(FlashConfig())
    assert image[0:8].hex(" ") == header.hex(" "), "SFDP header"
    assert image[8:16].hex(" ") == parameter_header.hex(" "), "parameter header"
    for index in range(9):
        offset = 16 + 4 * index
        got = int.from_bytes(image[offset : offset + 4], "little")
        want = int.from_bytes(expected[offset : offset + 4], "little")
        assert got == want, f"DWORD {index + 1}: 0x{got:08X} != 0x{want:08X}"
    assert image == expected
