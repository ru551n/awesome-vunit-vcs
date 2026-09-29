# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Device models of the MDIO PHY.

The PHY VC decodes the Clause 22 frames on the bus. A device model decides
what a register read returns and what a write does. The default model,
:class:`MdioDevice`, is a plain file of 32 registers of 16 bits. Derive from it
to model registers with side effects, such as a self-clearing reset bit or a
latched-low link status. Times are integers in femtoseconds.

::

    from awesome_vunit_vcs.mdio import MdioDevice

    class SelfClearingReset(MdioDevice):
        def write(self, register_address: int, value: int, now_fs: int) -> None:
            super().write(register_address, value & ~0x8000 if register_address == 0 else value, now_fs)
"""

from __future__ import annotations

from collections.abc import Mapping

from .errors import MdioValueError

__all__ = ["NUM_REGISTERS", "MdioDevice", "check_register_address", "check_value"]

#: The number of registers of a Clause 22 PHY
NUM_REGISTERS = 32


def check_register_address(register_address: int) -> int:
    """
    ``register_address`` if it is 0 to 31.

    Raises:
        MdioValueError: It is not.
    """
    if not 0 <= register_address < NUM_REGISTERS:
        raise MdioValueError(f"Register address {register_address} is not 0 to {NUM_REGISTERS - 1}")
    return register_address


def check_value(value: int) -> int:
    """
    ``value`` if it fits 16 bits.

    Raises:
        MdioValueError: It does not.
    """
    if not 0 <= value <= 0xFFFF:
        raise MdioValueError(f"Register value {value} does not fit 16 bits")
    return value


class MdioDevice:
    """
    The base of every device model: 32 registers of 16 bits.

    Args:
        registers: Initial register values by address; the others are 0.
        read_only: Masks of the bits a write over MDIO leaves unchanged, by register address.
            :meth:`set_register` writes every bit.

    Attributes:
        registers: The register values, indexed by register address.
    """

    def __init__(self, registers: Mapping[int, int] | None = None, read_only: Mapping[int, int] | None = None) -> None:
        self.registers = [0] * NUM_REGISTERS
        self._read_only = [0] * NUM_REGISTERS
        for address, value in (registers or {}).items():
            self.registers[check_register_address(int(address))] = check_value(int(value))
        for address, mask in (read_only or {}).items():
            self._read_only[check_register_address(int(address))] = check_value(int(mask))

    def read(self, register_address: int, now_fs: int) -> int:
        """A read frame to the PHY. Returns the 16-bit value the PHY sends."""
        return self.registers[register_address]

    def write(self, register_address: int, value: int, now_fs: int) -> None:
        """A write frame to the PHY. Bits marked read-only keep their value."""
        mask = self._read_only[register_address]
        self.registers[register_address] = (self.registers[register_address] & mask) | (value & ~mask & 0xFFFF)

    def set_register(self, register_address: int, value: int) -> None:
        """Set a register directly, without the bus and without side effects."""
        self.registers[check_register_address(register_address)] = check_value(value)

    def get_register(self, register_address: int) -> int:
        """A register value, read directly, without the bus and without side effects."""
        return self.registers[check_register_address(register_address)]
