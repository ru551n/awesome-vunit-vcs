# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The opcode table itself: coverage, self-consistency, and the two
resolutions the state machine depends on (current addressing, QPI lanes)."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash.commands import (
    COMMAND_TABLE,
    COMMANDS,
    AddrLen,
    Direction,
    Op,
    erase_opcode_for,
    lookup,
)

REQUIRED = {
    0x9F: "RDID",
    0x5A: "RDSFDP",
    0x03: "READ",
    0x0B: "FAST_READ",
    0x3B: "READ_DUAL_OUT",
    0x6B: "READ_QUAD_OUT",
    0xBB: "READ_DUAL_IO",
    0xEB: "READ_QUAD_IO",
    0x02: "PP",
    0x32: "PP_QUAD",
    0x20: "SE",
    0x52: "BE32",
    0xD8: "BE64",
    0xC7: "CE",
    0x60: "CE_ALT",
    0x06: "WREN",
    0x04: "WRDI",
    0x05: "RDSR1",
    0x35: "RDSR2",
    0x15: "RDSR3",
    0x01: "WRSR",
    0x38: "QPI_ENTER",
    0xFF: "QPI_EXIT",
    0xB7: "EN4B",
    0xE9: "EX4B",
    0x13: "READ4B",
    0x0C: "FAST_READ4B",
    0x12: "PP4B",
    0xDC: "BE64_4B",
    0x66: "RSTEN",
    0x99: "RST",
    0xB9: "DPD",
    0xAB: "RELEASE_DPD",
}


@pytest.mark.parametrize(("opcode", "name"), sorted(REQUIRED.items()))
def test_required_opcode_present(opcode: int, name: str) -> None:
    cmd = lookup(opcode)
    assert cmd is not None and cmd.name == name


def test_unsupported_opcode_is_none_not_an_error() -> None:
    assert lookup(0x77) is None
    assert lookup(0x00) is None
    assert lookup(0x1FF) is COMMANDS[0xFF]  # masked to a byte


def test_every_entry_is_internally_consistent() -> None:
    for cmd in COMMAND_TABLE:
        assert 0 <= cmd.opcode <= 0xFF
        assert cmd.opcode_lanes in (1, 2, 4)
        assert cmd.addr_lanes in (1, 2, 4)
        assert cmd.data_lanes in (1, 2, 4)
        assert 0 <= cmd.dummy_cycles < 64, "must fit the directive's 6-bit field"
        if cmd.direction is Direction.NONE:
            assert cmd.status_index is None
        if cmd.op is Op.ERASE:
            assert cmd.busy is not None and cmd.needs_wel
        if cmd.needs_wel:
            assert cmd.op in (Op.PAGE_PROGRAM, Op.ERASE, Op.WRITE_STATUS)
        if 4 in (cmd.addr_lanes, cmd.data_lanes):
            assert cmd.needs_qe, f"{cmd.name} uses four lanes without requiring QE"


def test_only_status_reads_and_resets_are_legal_while_busy() -> None:
    legal = {c.name for c in COMMAND_TABLE if c.legal_while_wip}
    assert legal == {"RDSR1", "RDSR2", "RDSR3", "QPI_EXIT", "RSTEN", "RST"}


def test_current_addressing_follows_the_mode() -> None:
    assert COMMANDS[0x03].addr_bytes(3) == 3
    assert COMMANDS[0x03].addr_bytes(4) == 4
    # 4-byte opcodes never follow the mode...
    assert COMMANDS[0x13].addr_bytes(3) == 4
    assert COMMANDS[0x12].addr_bytes(3) == 4
    # ... and neither does RDSFDP, which JESD216 pins at three bytes.
    assert COMMANDS[0x5A].addr_bytes(4) == 3
    assert COMMANDS[0x06].addr_bytes(4) == 0


def test_qpi_widens_every_phase_including_the_opcode() -> None:
    assert COMMANDS[0x03].lanes(qpi=False) == (1, 1, 1)
    assert COMMANDS[0x03].lanes(qpi=True) == (4, 4, 4)
    assert COMMANDS[0x3B].lanes(qpi=False) == (1, 1, 2)
    assert COMMANDS[0xEB].lanes(qpi=False) == (1, 4, 4)


def test_only_the_io_reads_carry_a_mode_byte() -> None:
    assert {c.name for c in COMMAND_TABLE if c.mode_byte} == {
        "READ_DUAL_IO",
        "READ_QUAD_IO",
    }


def test_erase_opcode_lookup_is_unambiguous() -> None:
    assert erase_opcode_for(4096) == 0x20
    assert erase_opcode_for(32768) == 0x52
    assert erase_opcode_for(65536) == 0xD8
    assert erase_opcode_for(1024) is None


def test_address_lengths_are_a_closed_set() -> None:
    assert {c.addr for c in COMMAND_TABLE} <= {
        AddrLen.NONE,
        AddrLen.THREE,
        AddrLen.FOUR,
        AddrLen.CURRENT,
    }
