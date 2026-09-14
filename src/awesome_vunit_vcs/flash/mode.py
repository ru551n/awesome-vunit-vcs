# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Protocol mode: SPI vs QPI, 3- vs 4-byte addressing, and continuous read.

These three pieces of state change how the *next* transaction is decoded,
which is why they live in one small object instead of being scattered
through the state machine. Two of them are notorious sources of silent
misbehaviour in flash models:

* 4-byte addressing. `EN4B`/`EX4B` (and some parts' status bit) switch the
  length of the address phase for every "current addressing mode" opcode.
  Getting this wrong shifts every subsequent address by a byte and still
  looks like plausible data.

* Continuous read / XIP. After a `0xEB`-class command the host clocks a
  mode byte. If `M5:M4 == 0b10`, the NEXT transaction has **no opcode at
  all** -- CS falls and the device is already in its address phase. A model
  that ignores the mode byte will decode the first address byte as an
  opcode, which is usually an unsupported opcode, which is silently
  ignored: the failure surfaces as "the DUT's XIP reads return 0xFF", a
  long way from the cause.

Anything other than `0b10` in `M5:M4` leaves (or exits) continuous read,
which is exactly how a host exits XIP without a dedicated command.
"""

from __future__ import annotations

from dataclasses import dataclass

# The mode byte's continuous-read pattern, in bits 5:4.
MODE_BYTE_CONTINUOUS = 0b10
MODE_BYTE_SHIFT = 4
MODE_BYTE_MASK = 0b11


def is_continuous(mode_byte: int) -> bool:
    """True when this mode byte asks the device to stay in continuous read."""
    return (mode_byte >> MODE_BYTE_SHIFT) & MODE_BYTE_MASK == MODE_BYTE_CONTINUOUS


@dataclass
class ProtocolMode:
    """Volatile protocol state. `default_addr_bytes` comes from the device
    configuration and is what a reset restores -- a 32 MiB part may legitimately
    power up in 4-byte mode."""

    default_addr_bytes: int = 3
    addr_bytes: int = 3
    qpi: bool = False
    # Opcode of the command that latched continuous read, or None. The
    # opcode is kept (rather than the command object) so the state is a
    # plain integer and trivially printable in a failure message.
    continuous_opcode: int | None = None

    @classmethod
    def from_default(cls, default_addr_bytes: int) -> ProtocolMode:
        return cls(default_addr_bytes=default_addr_bytes, addr_bytes=default_addr_bytes)

    @property
    def continuous_read(self) -> bool:
        return self.continuous_opcode is not None

    def set_addr_bytes(self, count: int) -> None:
        if count not in (3, 4):
            raise ValueError(f"addr_bytes={count} must be 3 or 4")
        self.addr_bytes = count

    def latch_mode_byte(self, opcode: int, mode_byte: int) -> None:
        """Apply the mode byte clocked after the address of a command that
        has one. Entering and leaving are the same decision, evaluated
        every transaction."""
        self.continuous_opcode = opcode if is_continuous(mode_byte) else None

    def exit_continuous(self) -> None:
        """Leave continuous read. Driven by the 0xFF mode reset and by a
        device reset, neither of which carries a mode byte."""
        self.continuous_opcode = None

    def reset(self) -> None:
        """Hardware/software reset: QPI off, addressing back to the
        configured power-up mode, no XIP."""
        self.qpi = False
        self.addr_bytes = self.default_addr_bytes
        self.continuous_opcode = None
