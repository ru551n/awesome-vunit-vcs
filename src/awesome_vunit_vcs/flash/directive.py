# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The packed directive: the single 32-bit integer every `cs_assert` /
`xfer` call hands back to the VHDL verification component.

Authoritative layout: the ``flash`` VC documentation. The VC has the
same field table hand-written in ``vhdl/flash/flash_pkg.vhd``, so the two
sides can only agree by both matching that document -- `LAYOUT_VERSION`
is the run-time guard that they still do.

Why one packed integer rather than several calls: VUnit's Python bridge
returns exactly one value per call, and a directive is needed on the
critical path of every single byte. Packing six fields into one integer
turns "what do I do with the next byte" into one FFI round trip instead
of six.

Every field describes the SAME, next action -- one tense throughout.
`pre_dummy_cycles` is a prefix on that action, never a phase of its own,
which is what lets `0x6B` (address x1 -> 8 dummy -> data x4) be a single
directive and also covers the commands where dummy cycles precede a
*receive*.

The whole layout is capped at 30 bits because VHDL's `integer` is signed
32-bit: a packed value at or above 2**31 is simply not representable on the
other side of the bridge.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

# Bumped whenever any field width, shift or order below changes. The VC
# asserts this against its own constant at instance-creation time, so a
# drift fails at time 0 rather than as an inexplicable wrong byte later.
LAYOUT_VERSION = 1


class Action(IntEnum):
    """What the VC should do with the next byte on the wire."""

    RECEIVE = 0
    TRANSMIT = 1
    IGNORE_REST = 2  # drive nothing, consume clocks until CS rises


# field -> (shift, width), exactly as tabulated in the FFI contract.
ACTION_SHIFT, ACTION_BITS = 0, 2
LANES_SHIFT, LANES_BITS = 2, 3
PRE_DUMMY_SHIFT, PRE_DUMMY_BITS = 5, 6
BYTE_OUT_SHIFT, BYTE_OUT_BITS = 11, 8
FLAGS_SHIFT, FLAGS_BITS = 19, 2
N_BYTES_SHIFT, N_BYTES_BITS = 21, 9

# flags bit 0: "the value I am about to produce depends on simulation time,
# so pass the time on the next xfer". Set for status-register reads, whose WIP
# bit is derived from a deadline rather than stored.
FLAG_VOLATILE = 1 << 0

VALID_LANES = (1, 2, 4)

# The layout occupies bits 0..29, so a packed directive never exceeds
# 2**30 - 1. This is not cosmetic: VHDL's `integer` is *signed* 32-bit, so
# any value at or above 2**31 cannot cross the bridge at all. The VC
# asserts the same bound in its own decode, so a violation fails on both
# sides rather than arriving as a negative integer.
PACKED_MAX = 2**30 - 1


def _field(value: int, name: str, width: int) -> int:
    value = int(value)
    if value < 0 or value >= (1 << width):
        raise ValueError(f"directive field {name}={value} does not fit in {width} bits")
    return value


def pack(
    action: Action | int,
    *,
    lanes: int = 1,
    pre_dummy_cycles: int = 0,
    byte_out: int = 0,
    flags: int = 0,
    n_bytes: int = 1,
) -> int:
    """Pack one directive into the non-negative integer the VC receives.

    Every field is range-checked: a silently truncated field would show up
    in simulation as a plausible-but-wrong byte, which is the single most
    expensive kind of bug this interface can have.
    """
    if lanes not in VALID_LANES:
        raise ValueError(f"lanes={lanes} must be one of {VALID_LANES}")
    packed = (
        (_field(int(action), "action", ACTION_BITS) << ACTION_SHIFT)
        | (_field(lanes, "lanes", LANES_BITS) << LANES_SHIFT)
        | (_field(pre_dummy_cycles, "pre_dummy_cycles", PRE_DUMMY_BITS) << PRE_DUMMY_SHIFT)
        | (_field(byte_out, "byte_out", BYTE_OUT_BITS) << BYTE_OUT_SHIFT)
        | (_field(flags, "flags", FLAGS_BITS) << FLAGS_SHIFT)
        | (_field(n_bytes, "n_bytes", N_BYTES_BITS) << N_BYTES_SHIFT)
    )
    # Belt and braces: the field widths above cannot produce a value over
    # PACKED_MAX, so this only ever fires if someone widens a field without
    # re-reading why the total is capped at 30 bits.
    if packed > PACKED_MAX:
        raise ValueError(
            f"packed directive 0x{packed:x} exceeds the contract's 30-bit budget "
            f"(max 0x{PACKED_MAX:x}); VHDL's signed 32-bit integer cannot carry it"
        )
    return packed


@dataclass(frozen=True)
class Directive:
    """Unpacked form. Only the model's own tests need this; the VC unpacks
    with its own VHDL constants."""

    action: Action
    lanes: int
    pre_dummy_cycles: int
    byte_out: int
    flags: int
    n_bytes: int

    @property
    def volatile(self) -> bool:
        return bool(self.flags & FLAG_VOLATILE)


def unpack(packed: int) -> Directive:
    """Inverse of `pack`. Raises on a negative or oversized word rather
    than masking it away."""
    if packed < 0 or packed > PACKED_MAX:
        raise ValueError(f"packed directive {packed} is outside the contract's [0, 0x{PACKED_MAX:x}] range")
    return Directive(
        action=Action((packed >> ACTION_SHIFT) & ((1 << ACTION_BITS) - 1)),
        lanes=(packed >> LANES_SHIFT) & ((1 << LANES_BITS) - 1),
        pre_dummy_cycles=(packed >> PRE_DUMMY_SHIFT) & ((1 << PRE_DUMMY_BITS) - 1),
        byte_out=(packed >> BYTE_OUT_SHIFT) & ((1 << BYTE_OUT_BITS) - 1),
        flags=(packed >> FLAGS_SHIFT) & ((1 << FLAGS_BITS) - 1),
        n_bytes=(packed >> N_BYTES_SHIFT) & ((1 << N_BYTES_BITS) - 1),
    )


def ignore_rest() -> int:
    """The "drive nothing, consume clocks until CS rises" directive.

    Used for every unsupported opcode and every command the current state
    refuses (no WEL, busy, deep power-down) -- a real device does not
    error, it simply does nothing, and so must the model.
    """
    return pack(Action.IGNORE_REST, lanes=1)
