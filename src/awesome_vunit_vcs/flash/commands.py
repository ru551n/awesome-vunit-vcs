# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The JEDEC opcode table, as data.

Every property the state machine needs in order to execute an opcode --
how many address bytes, how many dummy cycles, how wide each phase is,
which direction the data flows, whether WEL must be set, whether the
command is legal while the device is busy -- is a field of one immutable
`Command` record. `device.py` walks those fields; it never asks "which
opcode is this".

Why: a chain of `if opcode == 0x..` is where flash models go to die. The
dual/quad read family alone is eight near-identical commands differing
only in lane widths and dummy cycles, and the 4-byte-address family
duplicates half the table again. Expressed as data, adding `0x3C` or
`0x77` is one row; expressed as control flow it is another branch to get
subtly wrong. It also means the table itself can be asserted against the
SFDP bytes the model reports, so the two cannot disagree.

Baseline is generic JEDEC with BOTH 3- and 4-byte addressing:
`AddrLen.CURRENT` follows `mode.addr_bytes`, while `0x13`/`0x0C`/`0x12`/
`0xDC` pin 4 bytes and `0x5A` (RDSFDP) pins 3 regardless of mode, per
JESD216.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from enum import IntEnum
from typing import Any


class Op(IntEnum):
    """What executing the command actually does to the device."""

    NOP = 0
    READ_ARRAY = 1
    READ_ID = 2
    READ_SFDP = 3
    READ_STATUS = 4
    WRITE_STATUS = 5
    PAGE_PROGRAM = 6
    ERASE = 7
    WRITE_ENABLE = 8
    WRITE_DISABLE = 9
    ENTER_QPI = 10
    EXIT_QPI = 11
    ENTER_4B = 12
    EXIT_4B = 13
    RESET_ENABLE = 14
    RESET = 15
    DEEP_POWER_DOWN = 16
    RELEASE_POWER_DOWN = 17


class Direction(IntEnum):
    """Direction of the data phase, from the device's point of view."""

    NONE = 0
    IN = 1  # host -> device (program, write status)
    OUT = 2  # device -> host (read, status, id)


class AddrLen(IntEnum):
    """Length of the address phase. `CURRENT` follows the 3-/4-byte mode
    bit, which is the whole reason this is an enum and not an int."""

    NONE = 0
    THREE = 3
    FOUR = 4
    CURRENT = -1


# Erase size sentinel: the whole device, address phase absent.
ERASE_CHIP = 0


@dataclass(frozen=True)
class Command:
    """One row of the opcode table."""

    opcode: int
    name: str
    op: Op
    addr: AddrLen = AddrLen.NONE
    dummy_cycles: int = 0
    opcode_lanes: int = 1
    addr_lanes: int = 1
    data_lanes: int = 1
    direction: Direction = Direction.NONE
    needs_wel: bool = False
    legal_while_wip: bool = False
    legal_while_dpd: bool = False
    # A mode byte is clocked on the data lanes right after the address; its
    # M5:M4 field arms continuous read (XIP).
    mode_byte: bool = False
    # Quad-lane commands are refused unless the Quad Enable bit is set,
    # exactly as on a real part -- a driver that forgets to set QE should
    # fail in simulation, not silently work.
    needs_qe: bool = False
    erase_bytes: int | None = None
    # Index into the status-register file for the RDSRn family.
    status_index: int | None = None
    # Key into timing.py's busy table, or None for an instantaneous command.
    busy: str | None = None
    # Address phase present but semantically don't-care, and the command
    # still executes if CS rises early (0xAB release from deep power-down).
    addr_optional: bool = False
    # Data-in commands that latch a bounded buffer: page program is one
    # page, WRSR is three status bytes.
    max_data_bytes: int | None = None

    def addr_bytes(self, current: int) -> int:
        """Resolve the address-phase length against the current mode."""
        return current if self.addr is AddrLen.CURRENT else int(self.addr)

    def lanes(self, qpi: bool) -> tuple[int, int, int]:
        """(opcode, address, data) lane widths. In QPI every phase is four
        lanes including the opcode itself, which is what makes QPI a
        different protocol rather than just a wider read."""
        if qpi:
            return 4, 4, 4
        return self.opcode_lanes, self.addr_lanes, self.data_lanes


# Bases of the command families that share most fields. A row derives from
# one with `_derive`, which keeps every row a complete, type checked Command.
_READ_BASE = Command(0, "", Op.READ_ARRAY, addr=AddrLen.CURRENT, direction=Direction.OUT)
_ERASE_BASE = Command(0, "", Op.ERASE, addr=AddrLen.CURRENT, needs_wel=True, direction=Direction.NONE)
_STATUS_BASE = Command(0, "", Op.READ_STATUS, direction=Direction.OUT, legal_while_wip=True)


def _derive(base: Command, opcode: int, name: str, **overrides: Any) -> Command:
    return replace(base, opcode=opcode, name=name, **overrides)


#: The table. Ordered by function for reading, indexed by opcode below.
COMMAND_TABLE: tuple[Command, ...] = (
    # -- identification ---------------------------------------------------
    Command(0x9F, "RDID", Op.READ_ID, direction=Direction.OUT),
    Command(
        0x5A,
        "RDSFDP",
        Op.READ_SFDP,
        addr=AddrLen.THREE,  # JESD216: always 3 bytes, even in 4-byte mode
        dummy_cycles=8,
        direction=Direction.OUT,
    ),
    # -- reads, 3-/4-byte current addressing ------------------------------
    _derive(_READ_BASE, 0x03, "READ"),
    _derive(_READ_BASE, 0x0B, "FAST_READ", dummy_cycles=8),
    _derive(_READ_BASE, 0x3B, "READ_DUAL_OUT", dummy_cycles=8, data_lanes=2),
    _derive(_READ_BASE, 0x6B, "READ_QUAD_OUT", dummy_cycles=8, data_lanes=4, needs_qe=True),
    _derive(_READ_BASE, 0xBB, "READ_DUAL_IO", addr_lanes=2, data_lanes=2, mode_byte=True),
    _derive(
        _READ_BASE, 0xEB, "READ_QUAD_IO", addr_lanes=4, data_lanes=4, dummy_cycles=4, mode_byte=True, needs_qe=True
    ),
    # -- reads, explicit 4-byte addressing --------------------------------
    Command(0x13, "READ4B", Op.READ_ARRAY, addr=AddrLen.FOUR, direction=Direction.OUT),
    Command(
        0x0C,
        "FAST_READ4B",
        Op.READ_ARRAY,
        addr=AddrLen.FOUR,
        dummy_cycles=8,
        direction=Direction.OUT,
    ),
    # -- program ----------------------------------------------------------
    Command(
        0x02,
        "PP",
        Op.PAGE_PROGRAM,
        addr=AddrLen.CURRENT,
        direction=Direction.IN,
        needs_wel=True,
        busy="tPP",
    ),
    Command(
        0x32,
        "PP_QUAD",
        Op.PAGE_PROGRAM,
        addr=AddrLen.CURRENT,
        data_lanes=4,
        direction=Direction.IN,
        needs_wel=True,
        needs_qe=True,
        busy="tPP",
    ),
    Command(
        0x12,
        "PP4B",
        Op.PAGE_PROGRAM,
        addr=AddrLen.FOUR,
        direction=Direction.IN,
        needs_wel=True,
        busy="tPP",
    ),
    # -- erase ------------------------------------------------------------
    _derive(_ERASE_BASE, 0x20, "SE", erase_bytes=4096, busy="tSE"),
    _derive(_ERASE_BASE, 0x52, "BE32", erase_bytes=32768, busy="tBE32"),
    _derive(_ERASE_BASE, 0xD8, "BE64", erase_bytes=65536, busy="tBE64"),
    Command(
        0xDC,
        "BE64_4B",
        Op.ERASE,
        addr=AddrLen.FOUR,
        erase_bytes=65536,
        needs_wel=True,
        busy="tBE64",
    ),
    Command(
        0xC7,
        "CE",
        Op.ERASE,
        erase_bytes=ERASE_CHIP,
        needs_wel=True,
        busy="tCE",
    ),
    Command(
        0x60,
        "CE_ALT",
        Op.ERASE,
        erase_bytes=ERASE_CHIP,
        needs_wel=True,
        busy="tCE",
    ),
    # -- write enable / status --------------------------------------------
    Command(0x06, "WREN", Op.WRITE_ENABLE),
    Command(0x04, "WRDI", Op.WRITE_DISABLE),
    _derive(_STATUS_BASE, 0x05, "RDSR1", status_index=0),
    _derive(_STATUS_BASE, 0x35, "RDSR2", status_index=1),
    _derive(_STATUS_BASE, 0x15, "RDSR3", status_index=2),
    Command(
        0x01,
        "WRSR",
        Op.WRITE_STATUS,
        direction=Direction.IN,
        needs_wel=True,
        busy="tW",
        max_data_bytes=3,
    ),
    # -- mode control -------------------------------------------------------
    Command(0x38, "QPI_ENTER", Op.ENTER_QPI, needs_qe=True),
    # 0xFF is both "leave QPI" and the SPI-mode continuous-read reset, which
    # is why it must be legal while the device is busy.
    Command(0xFF, "QPI_EXIT", Op.EXIT_QPI, legal_while_wip=True),
    Command(0xB7, "EN4B", Op.ENTER_4B),
    Command(0xE9, "EX4B", Op.EXIT_4B),
    # -- reset and power ----------------------------------------------------
    Command(0x66, "RSTEN", Op.RESET_ENABLE, legal_while_wip=True),
    Command(0x99, "RST", Op.RESET, legal_while_wip=True, busy="tRST"),
    Command(0xB9, "DPD", Op.DEEP_POWER_DOWN),
    Command(
        0xAB,
        "RELEASE_DPD",
        Op.RELEASE_POWER_DOWN,
        addr=AddrLen.THREE,  # three don't-care bytes before the electronic ID
        addr_optional=True,
        direction=Direction.OUT,
        legal_while_dpd=True,
        busy="tRES1",
    ),
)

COMMANDS: dict[int, Command] = {c.opcode: c for c in COMMAND_TABLE}

if len(COMMANDS) != len(COMMAND_TABLE):  # pragma: no cover - construction guard
    raise RuntimeError("duplicate opcode in COMMAND_TABLE")


def lookup(opcode: int) -> Command | None:
    """The command for an opcode, or None for an unsupported one. An
    unsupported opcode is not an error: a real device ignores it, and so
    does the model (`Action.IGNORE_REST`)."""
    return COMMANDS.get(opcode & 0xFF)


def erase_opcode_for(size_bytes: int) -> int | None:
    """The opcode that erases exactly `size_bytes`, used to keep the SFDP
    erase-type entries honest against this table."""
    for cmd in COMMAND_TABLE:
        if cmd.op is Op.ERASE and cmd.erase_bytes == size_bytes:
            return cmd.opcode
    return None
