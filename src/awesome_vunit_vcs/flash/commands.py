# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The JEDEC opcode table, as data.

Every property the state machine needs in order to execute an opcode --
how many address bytes, how many dummy cycles, how wide each phase is,
which direction the data flows, whether WEL must be set, whether the
command is legal while the device is busy -- is a field of one immutable
:class:`Command` record. The device walks those fields; it never asks "which
opcode is this".

Why: a chain of ``if opcode == 0x..`` is where flash models go to die. The
dual/quad read family alone is eight near-identical commands differing
only in lane widths and dummy cycles, and the 4-byte-address family
duplicates half the table again. Expressed as data, adding 0x3C or
0x77 is one row; expressed as control flow it is another branch to get
subtly wrong. It also means the table itself can be asserted against the
SFDP bytes the model reports, so the two cannot disagree.

Baseline is generic JEDEC with both 3- and 4-byte addressing:
:attr:`AddrLen.CURRENT` follows the current addressing mode, while 0x13,
0x0C, 0x12 and 0xDC always take 4 address bytes and 0x5A (RDSFDP) always
takes 3, per JESD216.

Supported opcodes: 0x9F RDID, 0x5A RDSFDP, 0x03 READ, 0x0B FAST_READ,
0x3B READ_DUAL_OUT, 0x6B READ_QUAD_OUT, 0xBB READ_DUAL_IO,
0xEB READ_QUAD_IO, 0x13 READ4B, 0x0C FAST_READ4B, 0x02 PP, 0x32 PP_QUAD,
0x12 PP4B, 0x20 SE, 0x52 BE32, 0xD8 BE64, 0xDC BE64_4B, 0xC7 CE,
0x60 CE_ALT, 0x06 WREN, 0x04 WRDI, 0x05 RDSR1, 0x35 RDSR2, 0x15 RDSR3,
0x01 WRSR, 0x38 QPI_ENTER, 0xFF QPI_EXIT, 0xB7 EN4B, 0xE9 EX4B, 0x66 RSTEN,
0x99 RST, 0xB9 DPD and 0xAB RELEASE_DPD. Any other opcode is ignored.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from enum import IntEnum
from typing import Any


class Op(IntEnum):
    """What executing the command actually does to the device."""

    #: Nothing; no command in the table uses it
    NOP = 0
    #: Read the array from the address
    READ_ARRAY = 1
    #: Read the JEDEC ID
    READ_ID = 2
    #: Read SFDP space from the address
    READ_SFDP = 3
    #: Read one status register
    READ_STATUS = 4
    #: Write the status registers
    WRITE_STATUS = 5
    #: Program up to one page
    PAGE_PROGRAM = 6
    #: Erase a sector, a block or the whole device
    ERASE = 7
    #: Set the write enable latch
    WRITE_ENABLE = 8
    #: Clear the write enable latch
    WRITE_DISABLE = 9
    #: Enter QPI mode
    ENTER_QPI = 10
    #: Leave QPI mode and continuous read
    EXIT_QPI = 11
    #: Enter 4-byte addressing
    ENTER_4B = 12
    #: Leave 4-byte addressing
    EXIT_4B = 13
    #: Arm a software reset
    RESET_ENABLE = 14
    #: Execute an armed software reset
    RESET = 15
    #: Enter deep power-down
    DEEP_POWER_DOWN = 16
    #: Leave deep power-down, optionally reading the electronic ID
    RELEASE_POWER_DOWN = 17


class Direction(IntEnum):
    """Direction of the data phase, from the device's point of view."""

    #: No data phase
    NONE = 0
    #: Host to device (program, write status)
    IN = 1
    #: Device to host (read, status, ID)
    OUT = 2


class AddrLen(IntEnum):
    """
    Length of the address phase.

    :attr:`CURRENT` follows the 3-/4-byte addressing mode, which is the whole
    reason this is an enum and not an int.
    """

    #: No address phase
    NONE = 0
    #: 3 address bytes
    THREE = 3
    #: 4 address bytes
    FOUR = 4
    #: The current addressing mode, 3 or 4 bytes
    CURRENT = -1


#: The :attr:`Command.erase_bytes` of a chip erase, which erases the whole device and has no address phase
ERASE_CHIP = 0


@dataclass(frozen=True)
class Command:
    """
    One row of the opcode table.

    Attributes:
        opcode: The opcode byte.
        name: The mnemonic, such as ``"PP"``.
        op: What executing the command does.
        addr: Length of the address phase.
        dummy_cycles: SCK cycles with the I/Os released before the data phase.
        opcode_lanes: Lane width of the opcode outside QPI. The device decodes
            the opcode before it knows the command, so it uses 1 outside QPI
            and 4 in QPI whatever this says.
        addr_lanes: Lane width of the address outside QPI.
        data_lanes: Lane width of the mode byte and the data outside QPI.
        direction: Direction of the data phase.
        needs_wel: The command is refused unless the write enable latch is set.
        legal_while_wip: The command is accepted while the device is busy.
        legal_while_dpd: The command is accepted in deep power-down.
        mode_byte: A mode byte is clocked on the data lanes right after the
            address; its M5:M4 field arms continuous read (XIP).
        needs_qe: The command is refused unless the Quad Enable bit is set,
            exactly as on a real part -- a driver that forgets to set QE
            should fail in simulation, not silently work.
        erase_bytes: Bytes an erase command erases, :data:`ERASE_CHIP` for
            the whole device, None for other commands.
        status_index: The status register a read-status command returns, 0
            for SR1 to 2 for SR3, None for other commands.
        busy: The busy-time name of
            :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS` the command
            starts, or None for an instantaneous command.
        addr_optional: The address phase is present but don't-care, and the
            command still executes if CS rises before it completes (0xAB).
        max_data_bytes: The most data bytes latched; later bytes are
            ignored. None means no limit, and page program wraps within its
            page instead.
    """

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
    mode_byte: bool = False
    needs_qe: bool = False
    erase_bytes: int | None = None
    status_index: int | None = None
    busy: str | None = None
    addr_optional: bool = False
    max_data_bytes: int | None = None

    def addr_bytes(self, current: int) -> int:
        """
        Resolve the address-phase length against the current mode.

        Args:
            current: The current addressing mode, 3 or 4 bytes.

        Returns:
            The number of address bytes, 0 without an address phase.
        """
        return current if self.addr is AddrLen.CURRENT else int(self.addr)

    def lanes(self, qpi: bool) -> tuple[int, int, int]:
        """
        The lane widths of the phases.

        In QPI every phase is four lanes including the opcode itself, which is
        what makes QPI a different protocol rather than just a wider read.

        Args:
            qpi: Whether the device is in QPI mode.

        Returns:
            The opcode, address and data lane widths.
        """
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


#: Every supported command. Ordered by function for reading, indexed by opcode in :data:`COMMANDS`.
#:
#: :meta hide-value:
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

#: :data:`COMMAND_TABLE` indexed by opcode.
#:
#: :meta hide-value:
COMMANDS: dict[int, Command] = {c.opcode: c for c in COMMAND_TABLE}

if len(COMMANDS) != len(COMMAND_TABLE):  # pragma: no cover - construction guard
    raise RuntimeError("duplicate opcode in COMMAND_TABLE")


def lookup(opcode: int) -> Command | None:
    """
    The command of an opcode.

    An unsupported opcode is not an error: a real device ignores it, and so
    does the model (:attr:`~awesome_vunit_vcs.flash.directive.Action.IGNORE_REST`).

    Args:
        opcode: The opcode, masked to 8 bits.

    Returns:
        The command, or None for an unsupported opcode.
    """
    return COMMANDS.get(opcode & 0xFF)


def erase_opcode_for(size_bytes: int) -> int | None:
    """
    The opcode that erases exactly ``size_bytes``.

    Used to keep the SFDP erase-type entries honest against this table.

    Args:
        size_bytes: The erase size in bytes.

    Returns:
        The first opcode in :data:`COMMAND_TABLE` erasing that size, or None.
    """
    for cmd in COMMAND_TABLE:
        if cmd.op is Op.ERASE and cmd.erase_bytes == size_bytes:
            return cmd.opcode
    return None
