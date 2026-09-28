# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The protocol engine of the I2C target: addressing, acknowledge bits, PEC and clock stretching.

The VHDL target calls it once per START, byte and STOP and gets a
:class:`Directive` back: whether to acknowledge the byte it just received, for
how long to stretch the clock before the acknowledge bit, and whether to
receive, transmit or ignore the next byte. What the bytes mean is up to the
:class:`~awesome_vunit_vcs.i2c.devices.I2cDevice`.

Bytes of a transfer are numbered from 0, the first address byte; a 10-bit
address takes bytes 0 and 1.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

from ..common.events import Publisher
from .devices import I2cDevice
from .errors import I2cValueError
from .pec import pec_update

__all__ = ["Action", "Directive", "I2cTarget"]


class Action(enum.IntEnum):
    """What the target does with the next byte."""

    RECEIVE = 0
    TRANSMIT = 1
    #: Leave the bus alone until the next START or STOP
    IGNORE = 2


@dataclass(frozen=True)
class Directive:
    """
    What the VHDL target does next.

    Attributes:
        action: What to do with the next byte.
        ack: Acknowledge the byte just received.
        byte_out: The byte to transmit when ``action`` is TRANSMIT.
        stretch_fs: Hold SCL low for this long after the last bit of the byte just received, before
            the acknowledge bit.
    """

    action: Action
    ack: bool = False
    byte_out: int = 0
    stretch_fs: int = 0


_IGNORE = Directive(Action.IGNORE)


class _Phase(enum.Enum):
    IDLE = "idle"
    ADDRESS = "address"
    ADDRESS2 = "second address byte"
    WRITE = "write"
    READ = "read"


class I2cTarget:
    """
    Answer the transfers to one address with a device model.

    Args:
        device: The device model.
        address: The 7-bit or 10-bit address.
        ten_bit: ``address`` is a 10-bit address.
        general_call: Answer the general call address 0 as a write to the device.
        pec: SMBus Packet Error Checking. The last byte of a write before a STOP is a PEC: the
            written bytes reach the device at the STOP when it is right, and are dropped with an error
            otherwise. A read sends ``pec_read_bytes`` data bytes and then the PEC.
        pec_read_bytes: The data bytes of a read before the PEC.
        stretch_fs: How long to hold SCL low before the acknowledge bit of every byte the target
            acknowledges, 0 for no clock stretching.

    Attributes:
        errors: Publishes a message for every wrong PEC.
    """

    def __init__(
        self,
        device: I2cDevice,
        address: int,
        *,
        ten_bit: bool = False,
        general_call: bool = False,
        pec: bool = False,
        pec_read_bytes: int = 1,
        stretch_fs: int = 0,
    ) -> None:
        if not 0 <= address <= (0x3FF if ten_bit else 0x7F):
            raise I2cValueError(f"0x{address:X} is not a {'10' if ten_bit else '7'}-bit address")
        if pec_read_bytes < 0:
            raise I2cValueError(f"Negative pec_read_bytes={pec_read_bytes}")
        self.device = device
        device.address = address
        device.ten_bit = ten_bit
        self.address = address
        self.ten_bit = ten_bit
        self.general_call = general_call
        self.pec = pec
        self.pec_read_bytes = pec_read_bytes
        self.stretch_fs = stretch_fs
        self.errors: Publisher[str] = Publisher()
        self._nacks: set[int] = set()
        self.reset()

    def reset(self) -> None:
        """Forget a transfer in progress without ending it in the device."""
        self._in_transaction = False
        self._phase = _Phase.IDLE
        self._addressed = False
        self._index = 0
        self._crc = 0
        self._pending: list[int] = []
        self._read_count = 0
        self._ten_bit_selected = False

    def inject_nack(self, index: int) -> None:
        """
        Do not acknowledge byte ``index`` of the next transfer that reaches it, whatever the device says.

        Raises:
            I2cValueError: A negative index.
        """
        if index < 0:
            raise I2cValueError(f"Negative byte index {index}")
        self._nacks.add(index)

    def _ack(self, ack: bool) -> bool:
        if self._index in self._nacks:
            self._nacks.discard(self._index)
            return False
        return ack

    # Called by the VHDL target through its backend
    def start(self, now_fs: int) -> Directive:
        """A START or repeated START."""
        if self._addressed:
            self._end(stopped=False, now_fs=now_fs)
        if not self._in_transaction:
            self._crc = 0
            self._ten_bit_selected = False
        self._in_transaction = True
        self._phase = _Phase.ADDRESS
        self._index = 0
        return Directive(Action.RECEIVE)

    def stop(self, now_fs: int) -> None:
        """A STOP."""
        if self._addressed:
            self._end(stopped=True, now_fs=now_fs)
        self._in_transaction = False
        self._phase = _Phase.IDLE
        self._ten_bit_selected = False

    def received(self, value: int, now_fs: int) -> Directive:
        """The target received a byte; returns whether to acknowledge it and what comes next."""
        self._crc = pec_update(self._crc, value)
        phase = self._phase
        if phase is _Phase.ADDRESS:
            return self._address(value, now_fs)
        self._index += 1
        if phase is _Phase.ADDRESS2:
            address = (self.address & 0x300) | value
            if not self.device.responds_to(address):
                self._ten_bit_selected = False
                self._phase = _Phase.IDLE
                return _IGNORE
            self._ten_bit_selected = True
            return self._begin(address, read=False, now_fs=now_fs)
        if phase is _Phase.WRITE:
            if self.pec:
                self._pending.append(value)
                ack = True
            else:
                ack = self.device.write(value, now_fs)
            if self._ack(ack):
                return Directive(Action.RECEIVE, ack=True, stretch_fs=self.stretch_fs)
            self._phase = _Phase.IDLE
            return _IGNORE
        return _IGNORE

    def transmitted(self, acked: bool, now_fs: int) -> Directive:
        """The master acknowledged the byte the target transmitted, or not."""
        if self._phase is not _Phase.READ:
            return _IGNORE
        self.device.read_ack(acked, now_fs)
        if not acked:
            return _IGNORE
        return Directive(Action.TRANSMIT, byte_out=self._next_read(now_fs))

    def _address(self, value: int, now_fs: int) -> Directive:
        seven_bit = value >> 1
        read = bool(value & 1)
        if value & 0xF8 == 0xF0:
            if not self.ten_bit or (seven_bit & 3) != self.address >> 8:
                self._ten_bit_selected = False
                self._phase = _Phase.IDLE
                return _IGNORE
            if read:
                if not self._ten_bit_selected:
                    self._phase = _Phase.IDLE
                    return _IGNORE
                return self._begin(self.address, read=True, now_fs=now_fs)
            self._phase = _Phase.ADDRESS2
            if self._ack(True):
                return Directive(Action.RECEIVE, ack=True, stretch_fs=self.stretch_fs)
            self._phase = _Phase.IDLE
            return _IGNORE
        if seven_bit == 0 and not read and self.general_call:
            return self._begin(0, read=False, now_fs=now_fs)
        if not self.ten_bit and self.device.responds_to(seven_bit):
            return self._begin(seven_bit, read, now_fs)
        self._phase = _Phase.IDLE
        return _IGNORE

    def _begin(self, address: int, read: bool, now_fs: int) -> Directive:
        if not self._ack(self.device.start(address, read, now_fs)):
            self._phase = _Phase.IDLE
            return _IGNORE
        self._addressed = True
        self._pending = []
        self._read_count = 0
        if read:
            self._phase = _Phase.READ
            return Directive(Action.TRANSMIT, ack=True, byte_out=self._next_read(now_fs), stretch_fs=self.stretch_fs)
        self._phase = _Phase.WRITE
        return Directive(Action.RECEIVE, ack=True, stretch_fs=self.stretch_fs)

    def _next_read(self, now_fs: int) -> int:
        if not self.pec or self._read_count < self.pec_read_bytes:
            value = self.device.read(now_fs) & 0xFF
        elif self._read_count == self.pec_read_bytes:
            value = self._crc
        else:
            value = 0xFF
        self._read_count += 1
        self._crc = pec_update(self._crc, value)
        return value

    def _end(self, stopped: bool, now_fs: int) -> None:
        pending, self._pending = self._pending, []
        if stopped and pending:
            if self._crc == 0:
                pending.pop()
            else:
                self.errors.publish(
                    f"I2C_PEC: wrong PEC 0x{pending[-1]:02X} of a write to 0x{self.address:02X}, "
                    f"the CRC over the transaction is 0x{self._crc:02X}, not 0; the write is dropped"
                )
                pending = []
        for value in pending:
            self.device.write(value, now_fs)
        self.device.end(stopped, now_fs)
        self._addressed = False
