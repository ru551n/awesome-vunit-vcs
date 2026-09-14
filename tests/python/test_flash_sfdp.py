# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""SFDP: structurally valid, and -- the part that actually matters --
agreeing with the configuration and the opcode table it was built from."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash import sfdp
from awesome_vunit_vcs.flash.commands import COMMANDS
from awesome_vunit_vcs.flash.config import MIB, AddrModes, FlashConfig


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
        assert COMMANDS[opcode].erase_bytes == 1 << exponent
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


def test_a_config_whose_sector_size_has_no_opcode_is_rejected() -> None:
    with pytest.raises(ValueError, match="erase opcode"):
        sfdp.basic_parameter_table(FlashConfig(sector_bytes=1024))


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
