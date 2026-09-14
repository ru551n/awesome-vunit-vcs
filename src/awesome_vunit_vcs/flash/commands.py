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
0x01 WRSR, 0x31 WRSR2, 0x11 WRSR3, 0x38 QPI_ENTER, 0xFF QPI_EXIT, 0xB7 EN4B, 0xE9 EX4B, 0x66 RSTEN,
0x99 RST, 0xB9 DPD and 0xAB RELEASE_DPD. Any other opcode is ignored.

The table is the same for every device. What one device supports and how
much an erase erases depend on its
:class:`~awesome_vunit_vcs.flash.config.FlashConfig`: :func:`supported`,
:func:`lookup` and :meth:`Command.erase_size` take the configuration into
account.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from enum import IntEnum
from typing import Any

from .config import AddrModes, FlashConfig


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


class EraseUnit(IntEnum):
    """
    What an erase command erases.

    The size in bytes of each unit comes from the configuration of the
    device, see :meth:`Command.erase_size`.
    """

    #: The whole device, without an address phase
    CHIP = 0
    #: One sector, :attr:`~awesome_vunit_vcs.flash.config.FlashConfig.sector_bytes`
    SECTOR = 1
    #: One small block, :attr:`~awesome_vunit_vcs.flash.config.FlashConfig.block32_bytes`
    BLOCK32 = 2
    #: One block, :attr:`~awesome_vunit_vcs.flash.config.FlashConfig.block_bytes`
    BLOCK = 3


#: The :attr:`Command.erase` of a chip erase, which erases the whole device and has no address phase
ERASE_CHIP = EraseUnit.CHIP


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
        erase: What an erase command erases, None for other commands. The
            size in bytes depends on the device, see :meth:`erase_size`.
        status_index: The status register a read-status command returns, or
            the first one a write-status command writes, 0 for SR1 to 2 for
            SR3, None for other commands.
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
    erase: EraseUnit | None = None
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

    def erase_size(self, config: FlashConfig) -> int | None:
        """
        The number of bytes this command erases on a device.

        Args:
            config: The configuration of the device.

        Returns:
            ``size_bytes`` for a chip erase and the configured sector or block
            size in bytes otherwise, or None when the command is not an erase or
            erases 32 KiB blocks and the device has none (``block32_bytes`` is 0).
        """
        if self.erase is None:
            return None
        size = {
            EraseUnit.CHIP: config.size_bytes,
            EraseUnit.SECTOR: config.sector_bytes,
            EraseUnit.BLOCK32: config.block32_bytes,
            EraseUnit.BLOCK: config.block_bytes,
        }[self.erase]
        return size or None

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
    _derive(_ERASE_BASE, 0x20, "SE", erase=EraseUnit.SECTOR, busy="tSE"),
    _derive(_ERASE_BASE, 0x52, "BE32", erase=EraseUnit.BLOCK32, busy="tBE32"),
    _derive(_ERASE_BASE, 0xD8, "BE64", erase=EraseUnit.BLOCK, busy="tBE64"),
    Command(
        0xDC,
        "BE64_4B",
        Op.ERASE,
        addr=AddrLen.FOUR,
        erase=EraseUnit.BLOCK,
        needs_wel=True,
        busy="tBE64",
    ),
    Command(
        0xC7,
        "CE",
        Op.ERASE,
        erase=ERASE_CHIP,
        needs_wel=True,
        busy="tCE",
    ),
    Command(
        0x60,
        "CE_ALT",
        Op.ERASE,
        erase=ERASE_CHIP,
        needs_wel=True,
        busy="tCE",
    ),
    # -- write enable / status --------------------------------------------
    Command(0x06, "WREN", Op.WRITE_ENABLE),
    Command(0x04, "WRDI", Op.WRITE_DISABLE),
    _derive(_STATUS_BASE, 0x05, "RDSR1", status_index=0),
    _derive(_STATUS_BASE, 0x35, "RDSR2", status_index=1),
    _derive(_STATUS_BASE, 0x15, "RDSR3", status_index=2),
    # 0x01 writes up to three registers starting at SR1; 0x31 and 0x11 write
    # one byte into SR2 and SR3.
    Command(
        0x01,
        "WRSR",
        Op.WRITE_STATUS,
        direction=Direction.IN,
        needs_wel=True,
        status_index=0,
        busy="tW",
        max_data_bytes=3,
    ),
    Command(
        0x31,
        "WRSR2",
        Op.WRITE_STATUS,
        direction=Direction.IN,
        needs_wel=True,
        status_index=1,
        busy="tW",
        max_data_bytes=1,
    ),
    Command(
        0x11,
        "WRSR3",
        Op.WRITE_STATUS,
        direction=Direction.IN,
        needs_wel=True,
        status_index=2,
        busy="tW",
        max_data_bytes=1,
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


def supported(cmd: Command, config: FlashConfig) -> bool:
    """
    Whether a device with this configuration supports a command.

    A device ignores an unsupported command like an opcode missing from the
    table. The 32 KiB block erase is unsupported when ``block32_bytes`` is 0.
    With :attr:`~awesome_vunit_vcs.flash.config.AddrModes.THREE_ONLY`, EN4B,
    EX4B and every command with a fixed 4-byte address are unsupported; with
    :attr:`~awesome_vunit_vcs.flash.config.AddrModes.FOUR_ONLY`, EX4B is.

    Args:
        cmd: The command.
        config: The configuration of the device.

    Returns:
        True when the device executes the command.
    """
    if cmd.erase is EraseUnit.BLOCK32 and not config.block32_bytes:
        return False
    if config.addr_modes is AddrModes.THREE_ONLY:
        return cmd.addr is not AddrLen.FOUR and cmd.op not in (Op.ENTER_4B, Op.EXIT_4B)
    if config.addr_modes is AddrModes.FOUR_ONLY:
        return cmd.op is not Op.EXIT_4B
    return True


def lookup(opcode: int, config: FlashConfig | None = None) -> Command | None:
    """
    The command of an opcode.

    An unsupported opcode is not an error: a real device ignores it, and so
    does the model (:attr:`~awesome_vunit_vcs.flash.directive.Action.IGNORE_REST`).

    Args:
        opcode: The opcode, masked to 8 bits.
        config: The configuration of the device, or None for the whole table.

    Returns:
        The command, or None for an opcode missing from the table or, with
        ``config``, a command the device does not support, see :func:`supported`.
    """
    cmd = COMMANDS.get(opcode & 0xFF)
    if cmd is None or (config is not None and not supported(cmd, config)):
        return None
    return cmd


def commands_for(config: FlashConfig) -> dict[int, Command]:
    """
    The commands a device supports, indexed by opcode.

    Args:
        config: The configuration of the device.

    Returns:
        The rows of :data:`COMMAND_TABLE` that :func:`supported` accepts.
    """
    return {cmd.opcode: cmd for cmd in COMMAND_TABLE if supported(cmd, config)}


def erase_opcode_for(size_bytes: int, config: FlashConfig | None = None) -> int | None:
    """
    The opcode that erases exactly ``size_bytes`` on a device.

    Used to keep the SFDP erase-type entries honest against this table. Chip
    erases are not considered: they have no address, so they are no erase type.

    Args:
        size_bytes: The erase size in bytes.
        config: The configuration of the device, or None for the default
            :class:`~awesome_vunit_vcs.flash.config.FlashConfig`.

    Returns:
        The first opcode in :data:`COMMAND_TABLE` the device supports that
        erases that size, or None.
    """
    config = FlashConfig() if config is None else config
    for cmd in COMMAND_TABLE:
        if cmd.erase in (None, ERASE_CHIP) or not supported(cmd, config):
            continue
        if cmd.erase_size(config) == size_bytes:
            return cmd.opcode
    return None
