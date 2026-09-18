# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Transfers of the I2C master, compiled into the operation list the VHDL master executes.

Python decides what goes on the bus, VHDL clocks it out. A transfer becomes a
list of operation words, one per START, byte, bit group or STOP:

======  =====================================================================
Bits    Field
======  =====================================================================
7..0    The byte to write, or the bits of a bit group, right aligned
10..8   The operation: 0 START, 1 write a byte, 2 read a byte, 3 STOP,
        4 write a bit group without an acknowledge bit
11      Write: end the transfer with a STOP when the byte is not acknowledged.
        Read: acknowledge the byte.
15..12  Bit group: the number of bits, 1 to 8
======  =====================================================================

The master returns one result per operation: 0 for a START, STOP or bit group,
0 (ACK) or 1 (NACK) for a written byte, the byte for a read, -1 for an
operation it did not execute, -2 where it lost arbitration and -3 where SCL
stayed low for longer than its stretch timeout.
:meth:`Program.result` turns them into an :class:`I2cResult`.
"""

from __future__ import annotations

import enum
import re
from collections.abc import Sequence
from dataclasses import dataclass

from .errors import I2cValueError
from .pec import smbus_pec

__all__ = ["I2cResult", "I2cStatus", "OpKind", "OpRole", "Program", "compile_ops", "compile_transfer", "op_word"]


class OpKind(enum.IntEnum):
    """The operations of the master."""

    START = 0
    WRITE = 1
    READ = 2
    STOP = 3
    BITS = 4


class I2cStatus(enum.IntEnum):
    """The outcome of a transfer, numbered like ``i2c_status_t`` in VHDL."""

    #: Every byte was acknowledged, and the PEC was right
    OK = 0
    #: An address byte was not acknowledged
    ADDRESS_NACK = 1
    #: A data byte was not acknowledged
    DATA_NACK = 2
    #: The master lost arbitration to another master
    ARBITRATION_LOST = 3
    #: The PEC of a read was wrong
    PEC_ERROR = 4
    #: SCL stayed low for longer than the stretch timeout of the master
    SCL_TIMEOUT = 5


#: The flag bit of an operation word
FLAG = 1 << 11
#: What the master returns for an operation it did not execute
NOT_EXECUTED = -1
#: What the master returns where it lost arbitration
ARBITRATION_LOST = -2
#: What the master returns where SCL stayed low for longer than its stretch timeout
SCL_TIMEOUT = -3


def op_word(kind: OpKind, value: int = 0, flag: bool = False, bits: int = 0) -> int:
    """
    Pack one operation.

    Raises:
        I2cValueError: The value is not a byte or the bit count is not 1 to 8.
    """
    if not 0 <= value <= 0xFF:
        raise I2cValueError(f"{value} is not a byte")
    if kind is OpKind.BITS and not 1 <= bits <= 8:
        raise I2cValueError(f"A bit group has 1 to 8 bits, not {bits}")
    return value | int(kind) << 8 | (FLAG if flag else 0) | bits << 12


@dataclass(frozen=True)
class I2cResult:
    """
    The outcome of a transfer.

    Attributes:
        status: The status.
        data: The bytes read, without a PEC byte.
        acks: For every written byte, address bytes included, True when it was acknowledged, in
            order; bytes the master did not write are left out.
    """

    status: I2cStatus
    data: bytes
    acks: tuple[bool, ...]


class OpRole(enum.Enum):
    """What an operation of a :class:`Program` is for, to read its result."""

    CONTROL = "control"
    ADDRESS = "address"
    DATA = "data"
    PEC = "pec"


@dataclass(frozen=True)
class Program:
    """
    A compiled transfer: the operation words and what each one is for.

    Attributes:
        words: The operation words for the master.
        roles: What each operation is, for reading the results.
        pec: The last read byte is a PEC over every byte of the transfer.
    """

    words: tuple[int, ...]
    roles: tuple[OpRole, ...]
    pec: bool = False

    def result(self, results: Sequence[int]) -> I2cResult:
        """
        The outcome of the transfer from the results of the master, one per operation.

        Raises:
            I2cValueError: There is not one result per operation.
        """
        values = [int(value) for value in results]
        if len(values) != len(self.words):
            raise I2cValueError(f"{len(values)} results for {len(self.words)} operations")
        status = I2cStatus.OK
        read = bytearray()
        wire = []
        acks = []
        for word, role, value in zip(self.words, self.roles, values, strict=True):
            kind = OpKind(word >> 8 & 7)
            if value in (ARBITRATION_LOST, SCL_TIMEOUT):
                status = I2cStatus.ARBITRATION_LOST if value == ARBITRATION_LOST else I2cStatus.SCL_TIMEOUT
                break
            if value == NOT_EXECUTED:
                continue
            if kind is OpKind.WRITE:
                wire.append(word & 0xFF)
                acks.append(value == 0)
                if value and status is I2cStatus.OK:
                    status = I2cStatus.ADDRESS_NACK if role is OpRole.ADDRESS else I2cStatus.DATA_NACK
            elif kind is OpKind.READ:
                wire.append(value & 0xFF)
                if role is not OpRole.PEC:
                    read.append(value & 0xFF)
        if self.pec and status is I2cStatus.OK and smbus_pec(wire) != 0:
            status = I2cStatus.PEC_ERROR
        return I2cResult(status, bytes(read), tuple(acks))


def _address_ops(address: int, ten_bit: bool, read: bool, after_write: bool) -> list[tuple[int, OpRole]]:
    """The address bytes of a transfer, after its START."""
    rw = 1 if read else 0
    if not ten_bit:
        if not 0 <= address <= 0x7F:
            raise I2cValueError(f"A 7-bit address is 0 to 0x7F, not 0x{address:X}")
        return [(op_word(OpKind.WRITE, address << 1 | rw, flag=True), OpRole.ADDRESS)]
    if not 0 <= address <= 0x3FF:
        raise I2cValueError(f"A 10-bit address is 0 to 0x3FF, not 0x{address:X}")
    high = 0xF0 | (address >> 8) << 1
    if read and after_write:
        return [(op_word(OpKind.WRITE, high | 1, flag=True), OpRole.ADDRESS)]
    ops = [
        (op_word(OpKind.WRITE, high, flag=True), OpRole.ADDRESS),
        (op_word(OpKind.WRITE, address & 0xFF, flag=True), OpRole.ADDRESS),
    ]
    if read:
        ops += [(op_word(OpKind.START), OpRole.CONTROL), (op_word(OpKind.WRITE, high | 1, flag=True), OpRole.ADDRESS)]
    return ops


def compile_transfer(
    address: int,
    write: Sequence[int] = (),
    num_read: int = 0,
    *,
    ten_bit: bool = False,
    pec: bool = False,
    stop: bool = True,
) -> Program:
    """
    Compile a write, a read, or a write followed by a read after a repeated START.

    Args:
        address: The 7-bit or 10-bit target address.
        write: The bytes to write. Without bytes to write or read, the transfer is the address
            alone, as for acknowledge polling.
        num_read: The number of bytes to read after the write. All but the last are acknowledged.
        ten_bit: ``address`` is a 10-bit address.
        pec: Append an SMBus PEC to a write, and read one more byte as the PEC of a read.
        stop: End with a STOP; without it the master releases the bus without a STOP.

    Raises:
        I2cValueError: An invalid address, byte or count.
    """
    if num_read < 0:
        raise I2cValueError(f"Negative number of bytes to read {num_read}")
    ops: list[tuple[int, OpRole]] = [(op_word(OpKind.START), OpRole.CONTROL)]
    wire: list[int] = []
    if write or not num_read:
        ops += _address_ops(address, ten_bit, read=False, after_write=False)
        ops += [(op_word(OpKind.WRITE, int(value), flag=True), OpRole.DATA) for value in write]
        wire = [word & 0xFF for word, _ in ops if word >> 8 & 7 == OpKind.WRITE]
        if pec and not num_read:
            ops.append((op_word(OpKind.WRITE, smbus_pec(wire), flag=True), OpRole.PEC))
    if num_read:
        if len(ops) > 1:
            ops.append((op_word(OpKind.START), OpRole.CONTROL))
        ops += _address_ops(address, ten_bit, read=True, after_write=len(ops) > 1)
        count = num_read + (1 if pec else 0)
        for index in range(count):
            role = OpRole.PEC if pec and index == count - 1 else OpRole.DATA
            ops.append((op_word(OpKind.READ, flag=index < count - 1), role))
    if stop:
        ops.append((op_word(OpKind.STOP), OpRole.CONTROL))
    words, roles = zip(*ops, strict=True)
    return Program(tuple(words), tuple(roles), pec=pec and num_read > 0)


_TOKEN = re.compile(r"^(S|P|R|RN|0X[0-9A-F]{1,2}|\d{1,3}|B[01]{1,8})$")


def compile_ops(text: str) -> Program:
    """
    Compile a transfer written as operations, for traffic a normal transfer cannot express.

    The operations are separated by spaces or commas:

    * ``S``: a START, or a repeated START inside a transaction
    * ``P``: a STOP
    * ``0xA0`` or ``160``: write a byte and clock its acknowledge bit. The first byte after a START
      counts as an address byte in the result.
    * ``R``: read a byte and acknowledge it; ``RN``: read a byte and do not acknowledge it
    * ``B101``: write 1 to 8 bits, MSB first, without an acknowledge bit

    A NACK does not end the transfer early, and a transfer without ``P`` releases the bus without a
    STOP. For example ``"S 0xA0 0x00 B1010"`` writes an address and a byte, then 4 bits, and stops
    without a STOP.

    Raises:
        I2cValueError: An unknown operation.
    """
    ops: list[tuple[int, OpRole]] = []
    after_start = False
    for token in re.split(r"[\s,]+", text.strip().upper()):
        if not token:
            continue
        if not _TOKEN.match(token):
            raise I2cValueError(f"Unknown I2C operation {token!r} in {text!r}")
        if token == "S":
            ops.append((op_word(OpKind.START), OpRole.CONTROL))
            after_start = True
            continue
        if token == "P":
            ops.append((op_word(OpKind.STOP), OpRole.CONTROL))
        elif token in ("R", "RN"):
            ops.append((op_word(OpKind.READ, flag=token == "R"), OpRole.DATA))
        elif token.startswith("B"):
            ops.append((op_word(OpKind.BITS, int(token[1:], 2), bits=len(token) - 1), OpRole.CONTROL))
        else:
            value = int(token, 0)
            ops.append((op_word(OpKind.WRITE, value), OpRole.ADDRESS if after_start else OpRole.DATA))
        after_start = False
    if not ops:
        raise I2cValueError("An I2C transfer needs at least one operation")
    words, roles = zip(*ops, strict=True)
    return Program(tuple(words), tuple(roles))
