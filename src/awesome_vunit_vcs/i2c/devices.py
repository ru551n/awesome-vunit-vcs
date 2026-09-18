# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Device models of the I2C target.

The target VC handles the bus: START and STOP, addressing, acknowledge bits,
PEC and clock stretching. A device model decides what the bytes mean. It
derives from :class:`I2cDevice` and overrides the methods it needs; the target
calls them once per byte. Times are integers in femtoseconds.

::

    from awesome_vunit_vcs.i2c import I2cDevice

    class Counter(I2cDevice):
        def __init__(self) -> None:
            super().__init__()
            self.value = 0

        def read(self, now_fs: int) -> int:
            self.value = (self.value + 1) & 0xFF
            return self.value
"""

from __future__ import annotations

from collections.abc import Sequence

from ..common.vunit_bridge import decode_time_fs
from .errors import I2cValueError

__all__ = ["Eeprom24", "I2cDevice", "RegisterDevice"]


class I2cDevice:
    """
    The base of every device model. The default device acknowledges everything and reads 0xFF.

    Attributes:
        address: The address of the target, set by the target before the first transfer.
        ten_bit: ``address`` is a 10-bit address, set by the target.
    """

    def __init__(self) -> None:
        self.address = 0
        self.ten_bit = False

    def responds_to(self, address: int) -> bool:
        """Whether the device answers ``address``; a 7-bit or 10-bit address as the target has."""
        return address == self.address

    def start(self, address: int, read: bool, now_fs: int) -> bool:
        """
        A transfer to the device starts. Called after the last address byte.

        Args:
            address: The address the transfer carries.
            read: The R/W bit is R.
            now_fs: The simulation time.

        Returns:
            Whether to acknowledge the address.
        """
        return True

    def write(self, value: int, now_fs: int) -> bool:
        """The master wrote a byte. Returns whether to acknowledge it."""
        return True

    def read(self, now_fs: int) -> int:
        """The master reads a byte. Returns it."""
        return 0xFF

    def read_ack(self, acked: bool, now_fs: int) -> None:
        """The master acknowledged the byte read last, or not, which ends the read."""

    def end(self, stopped: bool, now_fs: int) -> None:
        """
        The transfer ended.

        Args:
            stopped: It ended with a STOP; otherwise with a repeated START.
            now_fs: The simulation time.
        """

    def preload(self, address: int, data: bytes) -> None:
        """
        Write memory of the device directly, without the bus.

        Raises:
            I2cValueError: The device has no memory.
        """
        raise I2cValueError(f"{type(self).__name__} has no memory to preload")

    def read_memory(self, address: int, length: int) -> bytes:
        """
        Read memory of the device directly, without the bus.

        Raises:
            I2cValueError: The device has no memory.
        """
        raise I2cValueError(f"{type(self).__name__} has no memory to read")


class _Memory(I2cDevice):
    def __init__(self, size_bytes: int, fill: int) -> None:
        super().__init__()
        if size_bytes < 1:
            raise I2cValueError(f"size_bytes={size_bytes} must be at least 1")
        if not 0 <= fill <= 0xFF:
            raise I2cValueError(f"fill={fill} is not a byte")
        self.memory = bytearray([fill]) * size_bytes

    def _span(self, address: int, length: int) -> None:
        if address < 0 or length < 0 or address + length > len(self.memory):
            raise I2cValueError(f"{length} bytes at 0x{address:X} are outside the {len(self.memory)} bytes of memory")

    def preload(self, address: int, data: bytes) -> None:
        """Write memory directly, without the bus."""
        self._span(address, len(data))
        self.memory[address : address + len(data)] = data

    def read_memory(self, address: int, length: int) -> bytes:
        """Read memory directly, without the bus."""
        self._span(address, length)
        return bytes(self.memory[address : address + length])


class RegisterDevice(_Memory):
    """
    A register map: the first bytes of a write select a register, the rest write registers.

    A read returns registers from the selected one on. With ``auto_increment`` every byte moves to the
    next register, wrapping at the end of the map.

    Args:
        size_bytes: The number of registers, one byte each.
        address_bytes: How many bytes select the register, most significant first.
        auto_increment: Move to the next register after every byte.
        fill: The initial value of every register.
    """

    def __init__(self, size_bytes: int = 256, address_bytes: int = 1, auto_increment: bool = True, fill: int = 0):
        super().__init__(size_bytes, fill)
        if not 1 <= address_bytes <= 4:
            raise I2cValueError(f"address_bytes={address_bytes} must be 1 to 4")
        self.address_bytes = address_bytes
        self.auto_increment = auto_increment
        #: The selected register
        self.pointer = 0
        self._pointer_bytes = 0

    def start(self, address: int, read: bool, now_fs: int) -> bool:
        """Acknowledge; a write selects a register with its first bytes."""
        self._pointer_bytes = 0 if not read else self.address_bytes
        return True

    def write(self, value: int, now_fs: int) -> bool:
        """Select a register, or write the selected one."""
        if self._pointer_bytes < self.address_bytes:
            if self._pointer_bytes == 0:
                self.pointer = 0
            self.pointer = (self.pointer << 8 | value) % len(self.memory)
            self._pointer_bytes += 1
            return True
        self.memory[self.pointer] = value
        self._advance()
        return True

    def read(self, now_fs: int) -> int:
        """The selected register."""
        value = self.memory[self.pointer]
        self._advance()
        return value

    def _advance(self) -> None:
        if self.auto_increment:
            self.pointer = (self.pointer + 1) % len(self.memory)


class Eeprom24(_Memory):
    """
    A 24Cxx serial EEPROM.

    * A write selects the memory address with its first ``address_bytes`` bytes. Parts with more
      memory than those bytes address take the upper address bits from the low bits of the device
      address, so a 24C16 (2048 bytes, 1 address byte) answers the 8 addresses from its own on.
    * The data bytes of a write go to a page buffer. The address wraps within the page, so bytes
      beyond the page overwrite its start.
    * The STOP starts the internal write cycle. For ``t_wr_fs`` the device does not acknowledge its
      address, so a master polls it with its address until it does. A repeated START instead of the
      STOP abandons the write.
    * A read returns bytes from the current address on, wrapping at the end of the memory.

    Args:
        size_bytes: The memory size.
        page_bytes: The page size.
        address_bytes: How many bytes of a write select the memory address.
        t_wr_fs: The write cycle time in fs, 5 ms by default, or as ``kwarg_time`` sends it from VHDL.
        fill: The initial value of every byte, 0xFF like an erased part.
    """

    def __init__(
        self,
        size_bytes: int = 256,
        page_bytes: int = 8,
        address_bytes: int = 1,
        t_wr_fs: int | Sequence[int] = 5_000_000_000_000,
        fill: int = 0xFF,
    ) -> None:
        super().__init__(size_bytes, fill)
        if not 1 <= address_bytes <= 2:
            raise I2cValueError(f"address_bytes={address_bytes} must be 1 or 2")
        if page_bytes < 1 or size_bytes % page_bytes:
            raise I2cValueError(f"page_bytes={page_bytes} must divide size_bytes={size_bytes}")
        try:
            t_wr_fs = decode_time_fs(t_wr_fs)
        except ValueError as exc:
            raise I2cValueError(f"t_wr_fs: {exc}") from None
        self.page_bytes = page_bytes
        self.address_bytes = address_bytes
        self.t_wr_fs = t_wr_fs
        self.block_bits = max(0, (size_bytes - 1).bit_length() - 8 * address_bytes)
        if self.block_bits > 3:
            raise I2cValueError(f"{size_bytes} bytes need more than 3 device address bits with {address_bytes}")
        #: The current memory address
        self.pointer = 0
        #: The time the write cycle ends, in fs
        self.busy_until_fs = 0
        #: Completed write cycles
        self.write_cycles = 0
        self._block = 0
        self._address_count = 0
        self._latch: dict[int, int] = {}

    def responds_to(self, address: int) -> bool:
        """The device address and the ones its block bits add."""
        return self.address <= address < self.address + (1 << self.block_bits)

    def start(self, address: int, read: bool, now_fs: int) -> bool:
        """Acknowledge unless the write cycle is running."""
        if now_fs < self.busy_until_fs:
            return False
        self._block = address - self.address
        self._address_count = self.address_bytes if read else 0
        self._latch = {}
        return True

    def write(self, value: int, now_fs: int) -> bool:
        """Take an address byte or latch a data byte."""
        if self._address_count < self.address_bytes:
            if self._address_count == 0:
                self.pointer = self._block << 8 * self.address_bytes
            shift = 8 * (self.address_bytes - 1 - self._address_count)
            self.pointer = (self.pointer | value << shift) % len(self.memory)
            self._address_count += 1
            return True
        self._latch[self.pointer] = value
        page = self.pointer - self.pointer % self.page_bytes
        self.pointer = page + (self.pointer + 1) % self.page_bytes
        return True

    def read(self, now_fs: int) -> int:
        """The byte at the current address."""
        value = self.memory[self.pointer]
        self.pointer = (self.pointer + 1) % len(self.memory)
        return value

    def end(self, stopped: bool, now_fs: int) -> None:
        """A STOP after data starts the write cycle."""
        if stopped and self._latch:
            for address, value in self._latch.items():
                self.memory[address] = value
            self.busy_until_fs = now_fs + self.t_wr_fs
            self.write_cycles += 1
        self._latch = {}
