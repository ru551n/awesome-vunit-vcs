# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The device state machine: one QSPI NOR flash instance.

The VC drives exactly three entry points -- ``cs_assert``, ``xfer`` and
``cs_deassert`` -- and the first two hand back a directive saying what to do
with the *next* byte. The device therefore has to know, at all times, which
phase of which command it is in; that is what :class:`Phase` is.

Three rules shape almost all of the code below, and all three are real
device behavior rather than modelling convenience:

1. **Nothing happens until CS rises.** Program data is latched into a page
   buffer, WRSR bytes into a list, WREN into nothing at all -- the
   instruction executes on the rising edge of CS. This is what makes the
   trailing-partial-byte abort expressible: if the host raises CS in the
   middle of a byte, a program or write-status instruction is simply not
   executed, and the model must agree.

2. **Refusals are silent.** An unsupported opcode, a program without WEL, a
   read while busy, a quad command without QE, an erase of a protected
   block: every one of these does nothing and reports nothing, apart from a
   counter of :meth:`FlashDevice.get_stat`. Raising here would be much
   friendlier to whoever is debugging -- and utterly wrong, because the DUT's
   firmware gets no such courtesy from silicon.

3. **There is no busy flag.** WIP is ``now_fs < deadline``, evaluated whenever
   someone asks. See :mod:`~awesome_vunit_vcs.flash.timing`.

Python raises only for things that are *impossible on a wire*: a preload
past the end of the device, an unknown timing name, a receive directive
answered with "I was transmitting". Those are testbench or VC bugs, not
device behavior, and the backend turns them into a failure report on the
VC logger. A content check that fails raises :class:`ContentMismatch`,
which the backend reports as a check failure instead.

Addresses and lengths are in bytes. All times are integer femtoseconds (fs).
"""

from __future__ import annotations

from collections.abc import Callable
from enum import IntEnum

from . import images
from . import sfdp as sfdp_mod
from .array import FlashArray
from .commands import ERASE_CHIP, Command, Direction, Op, commands_for
from .config import FlashConfig
from .directive import FLAG_VOLATILE, Action, ignore_rest, pack
from .mode import ProtocolMode
from .protection import Protection
from .timing import Timing

#: The bits of SR1, SR2 and SR3 that a status write (0x01, 0x31, 0x11) may change. These are SR1 bits 7..2
#: (SRP, SEC, TB, BP2..BP0), SR2 bits 6, 1 and 0 (CMP, QE, SRL) and SR3 bits
#: 7..5 and 2.
#: WIP and WEL are read-only status, the lock bits are one-time-programmable,
#: and ADS follows EN4B/EX4B.
WRSR_MASK = (0xFC, 0x43, 0xE4)

#: The Quad Enable bit of SR2
SR2_QE = 0x02
#: The complement protect bit of SR2
SR2_CMP = 0x40
#: The current address mode bit of SR3, set in 4-byte addressing
SR3_ADS = 0x01


class ContentMismatch(Exception):
    """The array does not hold the expected content (raised by the content checks only)."""


class Phase(IntEnum):
    """Where in a transaction the device is."""

    #: CS is high
    IDLE = 0
    #: The next byte is an opcode
    OPCODE = 1
    #: The next byte is an address byte
    ADDRESS = 2
    #: The next byte is the mode byte
    MODE_BYTE = 3
    #: The next byte is data, in or out
    DATA = 4
    #: The terminal state for anything refused or without a data phase
    IGNORE = 5


_COUNTERS = (
    "cmd_count",
    "xfer_count",
    "unknown_opcode_count",
    "program_count",
    "erase_count",
    "chip_erase_count",
    "wrsr_count",
    "reset_count",
    "protect_reject_count",
    "abort_count",
    "wel_reject_count",
    "wip_reject_count",
    "qe_reject_count",
    "dpd_reject_count",
    "bytes_programmed",
    "bytes_erased",
    "bytes_read",
    "continuous_read_entries",
)

# The counters `ignored_command_count` rolls up: every way a command can be
# silently dropped.
_IGNORE_REASONS = (
    "unknown_opcode_count",
    "wel_reject_count",
    "wip_reject_count",
    "qe_reject_count",
    "dpd_reject_count",
    "protect_reject_count",
    "abort_count",
)


class FlashDevice:
    """
    One modelled flash chip.

    Args:
        config: The configuration of the device.

    Attributes:
        config: The :class:`~awesome_vunit_vcs.flash.config.FlashConfig`.
        size_bytes: Capacity in bytes.
        page_bytes: Page size in bytes.
        addr_mask: ``size_bytes - 1``; wire addresses are wrapped with it.
        array: The :class:`~awesome_vunit_vcs.flash.array.FlashArray` holding the content.
        protection: The :class:`~awesome_vunit_vcs.flash.protection.Protection` state.
        timing: The :class:`~awesome_vunit_vcs.flash.timing.Timing` busy times and WIP deadline.
        mode: The :class:`~awesome_vunit_vcs.flash.mode.ProtocolMode`.
        sfdp_image: The SFDP image, see :func:`~awesome_vunit_vcs.flash.sfdp.build`.
        jedec_bytes: The three bytes 0x9F returns.
        electronic_id: The byte 0xAB returns.
        stats: The counters of :meth:`get_stat` by name. They are never reset.
        now_fs: The latest simulation time in fs VHDL passed.
        wel: The write enable latch.
        dpd: Whether the device is in deep power-down.
    """

    def __init__(self, config: FlashConfig) -> None:
        self.config = config
        self.size_bytes = config.size_bytes
        self.page_bytes = config.page_bytes
        self.addr_mask = self.size_bytes - 1
        self.array = FlashArray(self.size_bytes, self.page_bytes)
        self.protection = Protection(self.size_bytes)
        self.timing = Timing(config.busy_fs, enabled=config.timing_enabled)
        self.mode = ProtocolMode.from_default(config.addr_bytes)
        self.sfdp_image = sfdp_mod.build(config)
        self._commands = commands_for(config)
        self.jedec_bytes = config.jedec_id_bytes()
        self.electronic_id = config.device_id()
        self.stats: dict[str, int] = dict.fromkeys(_COUNTERS, 0)
        self.now_fs = 0
        self._sr = [0, 0, 0]
        self.reset_state()

    # -- lifecycle ---------------------------------------------------------

    def reset_state(self) -> None:
        """
        Power-on or hardware reset of everything volatile.

        The status registers return to their defaults, WEL, deep power-down,
        WIP, QPI and continuous read are cleared, the addressing mode returns
        to the power-up mode and any transaction in progress is dropped. The
        array, the testbench's explicit lock map and the counters survive,
        because a reset is not an erase and the lock map models something
        off-chip.
        """
        self._sr = [
            self.config.sr1_default & 0xFF,
            self.config.sr2_default & 0xFF,
            self.config.sr3_default & 0xFF,
        ]
        self.wel = False
        self.dpd = False
        self._reset_armed = False
        self.mode.reset()
        self.protection.reset()
        self.timing.clear_busy()
        self._sync_protection()
        self._clear_transaction()
        self._cs_active = False

    def _clear_transaction(self) -> None:
        self._phase = Phase.IDLE
        self._cmd: Command | None = None
        self._addr_needed = 0
        self._addr_seen = 0
        self._addr_value = 0
        self._data_count = 0
        self._pp_latch: bytearray | None = None
        self._pp_touched: bytearray | None = None
        self._pp_base = 0
        self._wrsr: list[int] = []
        self._out_addr = 0
        self._id_index = 0

    def _sync_protection(self) -> None:
        sr1 = self._sr[0]
        self.protection.set_status_bits(
            bp=(sr1 >> 2) & 0b111,
            tb=(sr1 >> 5) & 1,
            sec=(sr1 >> 6) & 1,
            cmp_=(self._sr[1] >> 6) & 1,
        )

    # -- derived status ----------------------------------------------------

    @property
    def qe(self) -> bool:
        """Whether the Quad Enable bit of SR2 is set."""
        return bool(self._sr[1] & SR2_QE)

    def wip(self, now_fs: int | None = None) -> bool:
        """
        Whether a program, erase or other busy period is in progress.

        Args:
            now_fs: The simulation time in fs, or None for :attr:`now_fs`, the
                latest time VHDL passed.

        Returns:
            True while the busy deadline has not passed.
        """
        return self.timing.is_busy(self.now_fs if now_fs is None else now_fs)

    def status_byte(self, index: int) -> int:
        """
        A status register, assembled at read time.

        WIP and ADS are derived, not stored, so they can never go stale. WIP is
        evaluated at :attr:`now_fs`.

        Args:
            index: 0 for SR1, 1 for SR2, any other value for SR3.

        Returns:
            The register value.
        """
        if index == 0:
            return (self._sr[0] & 0xFC) | (1 if self.wip() else 0) | (0x02 if self.wel else 0x00)
        if index == 1:
            return self._sr[1]
        return (self._sr[2] & ~SR3_ADS) | (SR3_ADS if self.mode.addr_bytes == 4 else 0)

    # -- VC entry points ---------------------------------------------------

    def cs_assert(self, now_fs: int) -> int:
        """
        CS fell.

        Args:
            now_fs: The simulation time in fs.

        Returns:
            The packed directive for the first byte of the transaction --
            which, in continuous read, is already an address byte rather than
            an opcode.
        """
        self.now_fs = int(now_fs)
        self._cs_active = True
        self._clear_transaction()
        if self.mode.continuous_read:
            cmd = self._commands.get(self.mode.continuous_opcode or 0)
            if cmd is not None:
                self.stats["cmd_count"] += 1
                return self._start_command(cmd)
        self._phase = Phase.OPCODE
        opcode_lanes = 4 if self.mode.qpi else 1
        # volatile: the command about to be decoded may be legal only while
        # not busy, so the device wants the freshest time it can get.
        return pack(Action.RECEIVE, lanes=opcode_lanes, flags=FLAG_VOLATILE)

    def xfer(self, byte_in: int, now_fs: int | None = None) -> int:
        """
        One byte moved on the wire.

        Args:
            byte_in: The byte received from the host, masked to 8 bits, or -1
                when the VC was clocking a byte *out*.
            now_fs: The simulation time in fs, or None to keep :attr:`now_fs`.
                VHDL passes it after a volatile directive.

        Returns:
            The packed directive for the next byte.

        Raises:
            RuntimeError: CS is not asserted.
            ValueError: The device expected to receive a byte and ``byte_in`` is negative.
        """
        if not self._cs_active:
            raise RuntimeError(f"xfer(byte_in={byte_in}) without cs_assert: CS is not asserted")
        if now_fs is not None:
            self.now_fs = int(now_fs)
        self.stats["xfer_count"] += 1
        phase = self._phase
        if phase is Phase.OPCODE:
            return self._on_opcode(byte_in)
        if phase is Phase.ADDRESS:
            return self._on_address(self._require_in(byte_in, "address"))
        if phase is Phase.MODE_BYTE:
            return self._on_mode_byte(self._require_in(byte_in, "mode byte"))
        if phase is Phase.DATA:
            assert self._cmd is not None
            if self._cmd.direction is Direction.IN:
                return self._on_data_in(self._require_in(byte_in, "data"))
            return self._on_data_out()
        return ignore_rest()

    def cs_deassert(self, trailing_bits: int, now_fs: int) -> int:
        """
        CS rose. Executes whatever the transaction asked for.

        A non-zero ``trailing_bits`` aborts a page program or write-status --
        the real device requires a whole number of data bytes and simply does
        not execute the instruction otherwise. A command whose address phase
        did not complete is not executed either, except 0xAB. A command that
        does not go busy leaves a running busy period alone.

        Args:
            trailing_bits: The number of clocks past the last whole byte.
            now_fs: The simulation time in fs.

        Returns:
            The busy time in fs, 0 when nothing went busy.
        """
        self.now_fs = int(now_fs)
        self._cs_active = False
        cmd = self._cmd
        self._phase = Phase.IDLE
        if cmd is None:
            return 0
        busy_key = self._execute(cmd, int(trailing_bits))
        self._cmd = None
        if busy_key is None:
            # Do NOT touch the deadline: a status poll while an erase is
            # running must not cancel the erase.
            return 0
        return self.timing.start_busy(self.now_fs, busy_key)

    # -- phase handlers ------------------------------------------------------

    @staticmethod
    def _require_in(byte_in: int, what: str) -> int:
        if byte_in is None or int(byte_in) < 0:
            raise ValueError(
                f"the model asked the VC to receive a {what} byte but was "
                f"given byte_in={byte_in}; the VC drove the bus instead"
            )
        return int(byte_in) & 0xFF

    def _on_opcode(self, byte_in: int) -> int:
        opcode = self._require_in(byte_in, "opcode")
        self.stats["cmd_count"] += 1
        cmd = self._commands.get(opcode)
        if cmd is None:
            self.stats["unknown_opcode_count"] += 1
            return self._refuse()
        return self._start_command(cmd)

    def _start_command(self, cmd: Command) -> int:
        """Legality gate, then first phase. Every refusal here is silent:
        the device consumes clocks and does nothing."""
        if self.dpd and not cmd.legal_while_dpd:
            self.stats["dpd_reject_count"] += 1
            return self._refuse()
        if not cmd.legal_while_wip and self.wip():
            self.stats["wip_reject_count"] += 1
            return self._refuse()
        if cmd.needs_qe and not self.qe:
            self.stats["qe_reject_count"] += 1
            return self._refuse()
        if cmd.needs_wel and not self.wel:
            self.stats["wel_reject_count"] += 1
            return self._refuse()
        self._cmd = cmd
        self._addr_needed = cmd.addr_bytes(self.mode.addr_bytes)
        self._addr_seen = 0
        self._addr_value = 0
        if self._addr_needed:
            self._phase = Phase.ADDRESS
            _, addr_lanes, _ = cmd.lanes(self.mode.qpi)
            return pack(Action.RECEIVE, lanes=addr_lanes)
        return self._after_address()

    def _on_address(self, byte_in: int) -> int:
        assert self._cmd is not None
        self._addr_value = (self._addr_value << 8) | byte_in
        self._addr_seen += 1
        if self._addr_seen < self._addr_needed:
            _, addr_lanes, _ = self._cmd.lanes(self.mode.qpi)
            return pack(Action.RECEIVE, lanes=addr_lanes)
        return self._after_address()

    def _after_address(self) -> int:
        cmd = self._cmd
        assert cmd is not None
        if cmd.mode_byte:
            self._phase = Phase.MODE_BYTE
            _, _, data_lanes = cmd.lanes(self.mode.qpi)
            return pack(Action.RECEIVE, lanes=data_lanes)
        return self._enter_data()

    def _on_mode_byte(self, byte_in: int) -> int:
        assert self._cmd is not None
        was_continuous = self.mode.continuous_read
        self.mode.latch_mode_byte(self._cmd.opcode, byte_in)
        if self.mode.continuous_read and not was_continuous:
            self.stats["continuous_read_entries"] += 1
        return self._enter_data()

    def _enter_data(self) -> int:
        """Start the data phase. ``dummy_cycles`` is emitted as the prefix of
        the first data directive, never as a phase, per the FFI contract."""
        cmd = self._cmd
        assert cmd is not None
        self._phase = Phase.DATA
        self._data_count = 0
        _, _, data_lanes = cmd.lanes(self.mode.qpi)
        dummy = cmd.dummy_cycles
        if cmd.direction is Direction.OUT:
            self._prepare_read()
            return pack(
                Action.TRANSMIT,
                lanes=data_lanes,
                pre_dummy_cycles=dummy,
                byte_out=self._next_out_byte(),
                flags=self._out_flags(),
            )
        if cmd.direction is Direction.IN:
            self._prepare_write()
            return pack(Action.RECEIVE, lanes=data_lanes, pre_dummy_cycles=dummy)
        # No data phase at all (WREN, erase, reset...): the command is
        # complete and executes when CS rises.
        self._phase = Phase.IGNORE
        return ignore_rest()

    def _refuse(self) -> int:
        self._cmd = None
        self._phase = Phase.IGNORE
        return ignore_rest()

    # -- data out ------------------------------------------------------------

    def _prepare_read(self) -> None:
        cmd = self._cmd
        assert cmd is not None
        if cmd.op is Op.READ_ARRAY:
            self._out_addr = self._addr_value & self.addr_mask
        elif cmd.op is Op.READ_SFDP:
            self._out_addr = self._addr_value
        self._id_index = 0

    def _out_flags(self) -> int:
        """``volatile`` tells the VC to pass the time on the next xfer. Only
        status reads need it -- their WIP bit is a function of time."""
        cmd = self._cmd
        return FLAG_VOLATILE if cmd is not None and cmd.op is Op.READ_STATUS else 0

    def _next_out_byte(self) -> int:
        cmd = self._cmd
        assert cmd is not None
        op = cmd.op
        if op is Op.READ_ARRAY:
            value = self.array.read_byte(self._out_addr)
            # Reads wrap at the end of the array rather than stopping.
            self._out_addr = (self._out_addr + 1) & self.addr_mask
            self.stats["bytes_read"] += 1
            return value
        if op is Op.READ_STATUS:
            assert cmd.status_index is not None
            return self.status_byte(cmd.status_index)
        if op is Op.READ_ID:
            value = self.jedec_bytes[self._id_index % len(self.jedec_bytes)]
            self._id_index += 1
            return value
        if op is Op.READ_SFDP:
            value = sfdp_mod.read(self.sfdp_image, self._out_addr, 1)[0]
            self._out_addr += 1
            return value
        if op is Op.RELEASE_POWER_DOWN:
            return self.electronic_id
        return 0xFF

    def _on_data_out(self) -> int:
        cmd = self._cmd
        assert cmd is not None
        self._data_count += 1
        _, _, data_lanes = cmd.lanes(self.mode.qpi)
        return pack(
            Action.TRANSMIT,
            lanes=data_lanes,
            byte_out=self._next_out_byte(),
            flags=self._out_flags(),
        )

    # -- data in -------------------------------------------------------------

    def _prepare_write(self) -> None:
        cmd = self._cmd
        assert cmd is not None
        if cmd.op is Op.PAGE_PROGRAM:
            addr = self._addr_value & self.addr_mask
            self._pp_base = addr & ~(self.page_bytes - 1)
            self._pp_offset = addr & (self.page_bytes - 1)
            # The latch is SRAM: last write to an offset wins. The NOR AND
            # happens once, when the latch is committed to the array.
            self._pp_latch = bytearray([0xFF]) * self.page_bytes
            self._pp_touched = bytearray(self.page_bytes)
        else:
            self._wrsr = []

    def _on_data_in(self, byte_in: int) -> int:
        cmd = self._cmd
        assert cmd is not None
        if cmd.op is Op.PAGE_PROGRAM:
            assert self._pp_latch is not None and self._pp_touched is not None
            # Past the end of the page the address wraps to the START of the
            # SAME page -- not to the next page. Clocking 300 bytes
            # overwrites the first 44 of them.
            offset = (self._pp_offset + self._data_count) % self.page_bytes
            self._pp_latch[offset] = byte_in
            self._pp_touched[offset] = 1
        elif cmd.op is Op.WRITE_STATUS:
            if len(self._wrsr) < (cmd.max_data_bytes or 1):
                self._wrsr.append(byte_in)
        self._data_count += 1
        _, _, data_lanes = cmd.lanes(self.mode.qpi)
        return pack(Action.RECEIVE, lanes=data_lanes)

    # -- execution at CS rise -------------------------------------------------

    def _execute(self, cmd: Command, trailing_bits: int) -> str | None:
        """Run the command. Returns the busy-time key, or None if the
        device does not go busy."""
        if cmd.op not in (Op.RESET_ENABLE, Op.RESET):
            # Any other instruction between 0x66 and 0x99 disarms the reset.
            self._reset_armed = False
        if trailing_bits and cmd.direction is Direction.IN:
            # Partial trailing byte: a page program or write-status
            # instruction is not executed at all.
            self.stats["abort_count"] += 1
            return None
        if self._addr_needed and self._addr_seen < self._addr_needed and not cmd.addr_optional:
            # The address phase never completed, so there is no address to
            # act on. Silently do nothing, as silicon does.
            self.stats["abort_count"] += 1
            return None
        return self._dispatch(cmd)

    def _dispatch(self, cmd: Command) -> str | None:
        op = cmd.op
        if op is Op.WRITE_ENABLE:
            self.wel = True
            return None
        if op is Op.WRITE_DISABLE:
            self.wel = False
            return None
        if op is Op.PAGE_PROGRAM:
            return self._do_program(cmd)
        if op is Op.ERASE:
            return self._do_erase(cmd)
        if op is Op.WRITE_STATUS:
            return self._do_write_status(cmd)
        if op is Op.ENTER_QPI:
            self.mode.qpi = True
            return None
        if op is Op.EXIT_QPI:
            # 0xFF is both "leave QPI" and the SPI-mode continuous-read
            # reset, so it must do both.
            self.mode.qpi = False
            self.mode.exit_continuous()
            return None
        if op is Op.ENTER_4B:
            self.mode.set_addr_bytes(4)
            return None
        if op is Op.EXIT_4B:
            self.mode.set_addr_bytes(3)
            return None
        if op is Op.RESET_ENABLE:
            self._reset_armed = True
            return None
        if op is Op.RESET:
            if not self._reset_armed:
                return None  # 0x99 without a preceding 0x66 does nothing
            self.stats["reset_count"] += 1
            self.reset_state()
            return "tRST"
        if op is Op.DEEP_POWER_DOWN:
            self.dpd = True
            return None
        if op is Op.RELEASE_POWER_DOWN:
            self.dpd = False
            # tRES2 is the longer "released and read the ID" path; tRES1 is
            # the bare release.
            return "tRES2" if self._data_count else "tRES1"
        return None

    def _do_program(self, cmd: Command) -> str | None:
        latch, touched = self._pp_latch, self._pp_touched
        self.wel = False
        if latch is None or touched is None or not any(touched):
            return None
        runs: list[tuple[int, int]] = []
        i = 0
        while i < self.page_bytes:
            if touched[i]:
                j = i
                while j < self.page_bytes and touched[j]:
                    j += 1
                runs.append((i, j))
                i = j
            else:
                i += 1
        if any(self.protection.is_protected(self._pp_base + s, e - s) for s, e in runs):
            self.stats["protect_reject_count"] += 1
            return None
        for s, e in runs:
            self.array.program(self._pp_base + s, bytes(latch[s:e]))
            self.stats["bytes_programmed"] += e - s
        self.stats["program_count"] += 1
        return cmd.busy

    def _do_erase(self, cmd: Command) -> str | None:
        self.wel = False
        size = cmd.erase_size(self.config)
        assert size is not None, "the device only decodes the erases it supports"
        if cmd.erase is ERASE_CHIP:
            start, length = 0, self.size_bytes
        else:
            start = (self._addr_value & self.addr_mask) & ~(size - 1)
            length = min(size, self.size_bytes - start)
        if self.protection.is_protected(start, length):
            self.stats["protect_reject_count"] += 1
            return None
        self.array.erase(start, length)
        self.stats["erase_count"] += 1
        if cmd.erase is ERASE_CHIP:
            self.stats["chip_erase_count"] += 1
        self.stats["bytes_erased"] += length
        return cmd.busy

    def _do_write_status(self, cmd: Command) -> str | None:
        self.wel = False
        if not self._wrsr:
            return None
        first = cmd.status_index or 0
        for index, value in enumerate(self._wrsr, start=first):
            mask = WRSR_MASK[index]
            self._sr[index] = (self._sr[index] & ~mask) | (value & mask)
        self._sync_protection()
        self.stats["wrsr_count"] += 1
        return cmd.busy

    # -- control plane --------------------------------------------------------

    @property
    def ignored_command_count(self) -> int:
        """
        Every command this device silently dropped, whatever the reason.

        The sum of ``unknown_opcode_count``, ``wel_reject_count``,
        ``wip_reject_count``, ``qe_reject_count``, ``dpd_reject_count``,
        ``protect_reject_count`` and ``abort_count``. The granular counters say
        *why*; this says *how many*, which is the number to reach for when a
        controller misbehaves and nobody yet knows which rule it broke. A
        silent refusal leaves no trace on the wire, so without a counter there
        is nothing at all to look at.
        """
        return sum(self.stats[key] for key in _IGNORE_REASONS)

    def get_stat(self, name: str) -> int:
        """
        One counter or one integer of observable state.

        Counters, since the device was created:

        * ``cmd_count``: opcodes decoded, including unsupported and refused
          ones, plus transactions continuing a continuous read.
        * ``xfer_count``: bytes moved on the wire (``xfer`` calls).
        * ``unknown_opcode_count``: unsupported opcodes.
        * ``program_count``: page programs committed to the array.
        * ``erase_count``: erases executed, including chip erases.
        * ``chip_erase_count``: chip erases executed.
        * ``wrsr_count``: status register writes (0x01, 0x31 and 0x11) executed.
        * ``reset_count``: software resets (0x66 then 0x99) executed.
        * ``protect_reject_count``: programs and erases refused because they
          touch a protected region.
        * ``abort_count``: commands not executed because CS rose within a data
          byte of a program or status write, or before the address phase
          completed.
        * ``wel_reject_count``, ``wip_reject_count``, ``qe_reject_count`` and
          ``dpd_reject_count``: commands refused without WEL, while busy,
          without QE and in deep power-down.
        * ``bytes_programmed``: bytes committed by page programs.
        * ``bytes_erased``: bytes erased.
        * ``bytes_read``: array bytes the read commands prepared for
          transmission. The model prepares each byte when the previous one
          completes, so this includes a byte read ahead that CS may cut off.
        * ``continuous_read_entries``: times continuous read was entered.

        Derived values:

        * ``ignored_command_count``: see :attr:`ignored_command_count`.
        * ``wip``, ``wel``, ``qe``, ``qpi``, ``dpd`` and ``continuous_read``:
          1 when set, 0 otherwise.
        * ``addr_bytes``: the current addressing mode, 3 or 4.
        * ``sr1``, ``sr2`` and ``sr3``: the status registers.
        * ``busy_deadline_fs``: the time in fs at which WIP clears.
        * ``timing_enabled``: 1 when busy times apply.
        * ``materialized_pages`` and ``run_count``: the memory use of the array.

        ``wip`` and ``sr1`` are evaluated at :attr:`now_fs`, the latest time
        VHDL passed, not at the time of the call.

        Args:
            name: The name of the counter or value.

        Returns:
            The value.

        Raises:
            KeyError: ``name`` is not a known name -- a typo'd stat silently
                returning 0 would make a test pass for the wrong reason.
        """
        if name in self.stats:
            return self.stats[name]
        derived: dict[str, Callable[[], int]] = {
            "ignored_command_count": lambda: self.ignored_command_count,
            "wip": lambda: int(self.wip()),
            "wel": lambda: int(self.wel),
            "qe": lambda: int(self.qe),
            "qpi": lambda: int(self.mode.qpi),
            "dpd": lambda: int(self.dpd),
            "addr_bytes": lambda: self.mode.addr_bytes,
            "continuous_read": lambda: int(self.mode.continuous_read),
            "sr1": lambda: self.status_byte(0),
            "sr2": lambda: self.status_byte(1),
            "sr3": lambda: self.status_byte(2),
            "busy_deadline_fs": self.timing.deadline_fs,
            "timing_enabled": lambda: int(self.timing.enabled),
            "materialized_pages": lambda: self.array.materialized_pages,
            "run_count": lambda: self.array.run_count,
        }
        if name not in derived:
            raise KeyError(f"unknown stat {name!r}; known: {sorted(set(self.stats) | set(derived))}")
        return int(derived[name]())

    # -- test-facing control plane ---------------------------------------------

    def _check_range(self, method: str, addr: int, num_bytes: int, *, min_bytes: int = 0) -> None:
        """Raise unless ``[addr, addr + num_bytes)`` lies inside the device and
        ``num_bytes`` is at least ``min_bytes``; shared by every content and
        protection call so they agree on what fits."""
        if num_bytes < min_bytes:
            raise ValueError(f"{method}: num_bytes={num_bytes} must be at least {min_bytes}")
        if not 0 <= addr < self.size_bytes or addr + num_bytes > self.size_bytes:
            raise ValueError(
                f"{method}: [0x{addr:x}, +{num_bytes}) is not inside the device [0, 0x{self.size_bytes:x})"
            )

    @staticmethod
    def _check_byte(method: str, value: int) -> None:
        if not 0 <= value <= 0xFF:
            raise ValueError(f"{method}: value={value} is not a byte value")

    #
    # These never model the wire: they are how a testbench seeds content,
    # inspects it, and constrains the model. They bypass NOR semantics on
    # purpose -- `preload` writes 0x00 over 0xFF and over anything else,
    # because it represents "the part came out of the programmer like this",
    # not a program cycle. Only `xfer`-driven programs go through AND.

    def preload(self, addr: int, data: bytes) -> None:
        """
        Seed content, overwriting.

        Not a program: no NOR AND, no WEL, no protection check, not recorded
        as a written region.

        Args:
            addr: The address of the first byte, inside the device.
            data: The bytes.

        Raises:
            ValueError: The range is not inside the device.
        """
        self._check_range("preload", addr, len(data))
        self.array.write_raw(addr, bytes(data))

    def preload_fill(self, addr: int, num_bytes: int, value: int) -> None:
        """
        Seed a constant region, as :meth:`preload` does.

        O(1) regardless of size -- filling the whole 16 MiB device materializes nothing.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes, at least 1.
            value: The byte value, 0 to 255.

        Raises:
            ValueError: The region is not inside the device, ``num_bytes`` is
                less than 1 or ``value`` is not a byte value.
        """
        self._check_range("preload_fill", addr, num_bytes, min_bytes=1)
        self._check_byte("preload_fill", value)
        self.array.fill(addr, num_bytes, value)

    def load_image(self, path: str, fmt: str | None = None, base: int = 0) -> int:
        """
        Load an image file, as :meth:`preload` does.

        Sparse formats stay sparse: bytes the image does not describe keep
        their content. Segments are written in file order, so a later one wins
        where they overlap.

        Args:
            path: The image file.
            fmt: The format, see :func:`~awesome_vunit_vcs.flash.images.format_for`;
                None infers it from the extension.
            base: The load address of a raw binary, an offset for the other formats.

        Returns:
            The number of bytes the image described.

        Raises:
            ValueError: See :func:`~awesome_vunit_vcs.flash.images.load`, or a
                segment is not inside the device.
            OSError: The file cannot be read.
        """
        total = 0
        for segment in images.load(path, fmt, base):
            if segment.data is not None:
                self.array.write_raw(segment.addr, segment.data)
            else:
                assert segment.fill is not None
                self.array.fill(segment.addr, segment.length, segment.fill)
            total += segment.size
        return total

    def read_back(self, addr: int, num_bytes: int) -> bytes:
        """
        Content as the array holds it, with no protocol in the way.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes.

        Returns:
            The bytes.

        Raises:
            ValueError: The range is not inside the device.
        """
        self._check_range("read_back", addr, num_bytes)
        return self.array.read(addr, num_bytes)

    def check_content(self, addr: int, expected: bytes) -> None:
        """
        Check that the array holds the expected bytes.

        The backend turns a mismatch into a check failure on the VC checker.

        Args:
            addr: The address of the first byte.
            expected: The expected bytes.

        Raises:
            ContentMismatch: A byte differs. The message gives the address and
                values of the first mismatch and the number of bad bytes.
            ValueError: The range is not inside the device.
        """
        self._check_range("check_content", addr, len(expected))
        actual = self.array.read(addr, len(expected))
        if actual == bytes(expected):
            return
        offset = next(i for i, (a, b) in enumerate(zip(actual, expected, strict=True)) if a != b)
        got, want = actual[offset], expected[offset]
        raise ContentMismatch(
            f"flash content mismatch at 0x{addr + offset:08x}: "
            f"expected 0x{want:02x}, got 0x{got:02x} "
            f"(first of {sum(a != b for a, b in zip(actual, expected, strict=True))} bad bytes "
            f"in [0x{addr:08x}, +{len(expected)}))"
        )

    def check_content_fill(self, addr: int, num_bytes: int, value: int) -> None:
        """
        :meth:`check_content` against a constant, without building the constant.

        Checking 1 MiB of 0xFF must not allocate 1 MiB of expectation.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes, at least 1.
            value: The expected byte value, 0 to 255.

        Raises:
            ContentMismatch: A byte differs. The message gives the address and
                value of the first mismatch.
            ValueError: The range is not inside the device, ``num_bytes`` is
                less than 1 or ``value`` is not a byte value.
        """
        self._check_range("check_content_fill", addr, num_bytes, min_bytes=1)
        self._check_byte("check_content_fill", value)
        actual = self.array.read(addr, num_bytes)
        want = value
        for offset, got in enumerate(actual):
            if got != want:
                raise ContentMismatch(
                    f"flash content mismatch at 0x{addr + offset:08x}: expected fill 0x{want:02x}, got 0x{got:02x}"
                )

    def written_regions(self) -> list[tuple[int, int]]:
        """
        The regions the *device* modified by program or erase.

        Preloading and image loading are excluded: they model how the part
        arrived, not what the DUT did to it. The regions accumulate for the
        life of the device; a reset does not clear them.

        Returns:
            Sorted, coalesced ``(addr, length)`` pairs in bytes.
        """
        return self.array.written_regions()

    def set_protection(self, addr: int, num_bytes: int, locked: bool) -> None:
        """
        Lock or unlock a region, see :meth:`~awesome_vunit_vcs.flash.protection.Protection.set_region`.

        A program or erase touching a locked region is silently ignored.

        Args:
            addr: The first byte.
            num_bytes: The number of bytes.
            locked: True to lock, False to unlock.

        Raises:
            ValueError: The region is not inside the device.
        """
        self._check_range("set_protection", addr, num_bytes)
        self.protection.set_region(addr, num_bytes, bool(locked))

    def set_timing(self, name: str, duration_fs: int) -> None:
        """
        Override one busy time, see :meth:`~awesome_vunit_vcs.flash.timing.Timing.set_busy`.

        Args:
            name: A busy-time name of :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`.
            duration_fs: The busy time in fs.

        Raises:
            KeyError: ``name`` is not a busy-time name.
            ValueError: ``duration_fs`` is negative.
        """
        self.timing.set_busy(name, duration_fs)

    def set_timing_enable(self, enable: bool) -> None:
        """
        Enable or disable busy times, see :meth:`~awesome_vunit_vcs.flash.timing.Timing.set_enable`.

        Args:
            enable: True to apply the busy times, False to use 0 for all of them.
        """
        self.timing.set_enable(enable)
