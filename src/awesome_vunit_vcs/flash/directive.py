# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The packed directive: the single integer every ``cs_assert`` / ``xfer`` call hands back to the VHDL VC.

Authoritative layout: the directive table of the flash user guide. The VC
has the same field table hand-written in ``vhdl/flash/flash_pkg.vhd``, so
the two sides can only agree by both matching that document --
:data:`LAYOUT_VERSION` is the run-time guard that they still do.

Why one packed integer rather than several calls: VUnit's Python bridge
returns exactly one value per call, and a directive is needed on the
critical path of every single byte. Packing six fields into one integer
turns "what do I do with the next byte" into one FFI round trip instead
of six.

Every field describes the SAME, next action -- one tense throughout.
``pre_dummy_cycles`` is a prefix on that action, never a phase of its own,
which is what lets 0x6B (address x1 -> 8 dummy -> data x4) be a single
directive and also covers the commands where dummy cycles precede a
*receive*.

========================  ======  ===================================================
Field                     Bits    Values
========================  ======  ===================================================
``action``                1..0    :class:`Action`
``lanes``                 4..2    1, 2 or 4
``pre_dummy_cycles``      10..5   SCK cycles with the I/Os released before the action
``byte_out``              18..11  The byte to transmit
``flags``                 20..19  :data:`FLAG_VOLATILE`
``n_bytes``               29..21  Always 1 in this model
========================  ======  ===================================================

The whole layout is capped at 30 bits because VHDL's ``integer`` is signed
32-bit: a packed value at or above ``2**31`` is simply not representable on
the other side of the bridge.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

from .errors import FlashValueError

#: Version of the packed layout. Bumped whenever any field width, shift or
#: order below changes. The VC asserts this against its own constant at
#: instance-creation time, so a drift fails at time 0 rather than as an
#: inexplicable wrong byte later.
LAYOUT_VERSION = 1


class Action(IntEnum):
    """What the VC should do with the next byte on the wire."""

    #: Sample a byte from the host
    RECEIVE = 0
    #: Drive ``byte_out`` to the host
    TRANSMIT = 1
    #: Drive nothing and consume clocks until CS rises
    IGNORE_REST = 2


# field -> (shift, width), exactly as tabulated in the FFI contract.
#: Shift and width in bits of the ``action`` field
ACTION_SHIFT, ACTION_BITS = 0, 2
#: Shift and width in bits of the ``lanes`` field
LANES_SHIFT, LANES_BITS = 2, 3
#: Shift and width in bits of the ``pre_dummy_cycles`` field
PRE_DUMMY_SHIFT, PRE_DUMMY_BITS = 5, 6
#: Shift and width in bits of the ``byte_out`` field
BYTE_OUT_SHIFT, BYTE_OUT_BITS = 11, 8
#: Shift and width in bits of the ``flags`` field
FLAGS_SHIFT, FLAGS_BITS = 19, 2
#: Shift and width in bits of the ``n_bytes`` field
N_BYTES_SHIFT, N_BYTES_BITS = 21, 9

#: Bit 0 of ``flags``, set when the value about to be produced depends on
#: simulation time, so the VC passes the time on the next ``xfer``. Set for the opcode
#: byte and for status-register reads, whose WIP bit is derived from a
#: deadline rather than stored.
FLAG_VOLATILE = 1 << 0

#: The lane widths a directive may give
VALID_LANES = (1, 2, 4)

#: The largest packed directive. The layout occupies bits 0..29, so a packed
#: directive never exceeds ``2**30 - 1``. This is not cosmetic: VHDL's
#: ``integer`` is *signed* 32-bit, so any value at or above ``2**31`` cannot
#: cross the bridge at all. The VC asserts the same bound in its own decode,
#: so a violation fails on both sides rather than arriving as a negative
#: integer.
PACKED_MAX = 2**30 - 1


def _field(value: int, name: str, width: int) -> int:
    value = int(value)
    if value < 0 or value >= (1 << width):
        raise FlashValueError(f"directive field {name}={value} does not fit in {width} bits")
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
    """
    Pack one directive into the non-negative integer the VC receives.

    Every field is range-checked: a silently truncated field would show up
    in simulation as a plausible-but-wrong byte, which is the single most
    expensive kind of bug this interface can have.

    Args:
        action: What to do with the next byte.
        lanes: Lane width of the action, 1, 2 or 4.
        pre_dummy_cycles: SCK cycles with the I/Os released before the
            action, 0 to 63.
        byte_out: The byte to transmit, 0 to 255.
        flags: Flag bits, see :data:`FLAG_VOLATILE`, 0 to 3.
        n_bytes: Number of bytes the directive covers, 0 to 511.

    Returns:
        The packed directive, at most :data:`PACKED_MAX`.

    Raises:
        FlashValueError: ``lanes`` is not 1, 2 or 4, or a field does not fit its width.
    """
    if lanes not in VALID_LANES:
        raise FlashValueError(f"lanes={lanes} must be one of {VALID_LANES}")
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
        raise FlashValueError(
            f"packed directive 0x{packed:x} exceeds the contract's 30-bit budget "
            f"(max 0x{PACKED_MAX:x}); VHDL's signed 32-bit integer cannot carry it"
        )
    return packed


@dataclass(frozen=True)
class Directive:
    """
    Unpacked form of a directive, as :func:`unpack` returns it.

    Only Python tests need this; the VC unpacks with its own VHDL constants.

    Attributes:
        action: What to do with the next byte.
        lanes: Lane width of the action, 1, 2 or 4 for a valid directive.
        pre_dummy_cycles: SCK cycles with the I/Os released before the action.
        byte_out: The byte to transmit.
        flags: Flag bits, see :data:`FLAG_VOLATILE`.
        n_bytes: Number of bytes the directive covers.
    """

    action: Action
    lanes: int
    pre_dummy_cycles: int
    byte_out: int
    flags: int
    n_bytes: int

    @property
    def volatile(self) -> bool:
        """Whether :data:`FLAG_VOLATILE` is set, so the next ``xfer`` passes the time."""
        return bool(self.flags & FLAG_VOLATILE)


def unpack(packed: int) -> Directive:
    """
    Inverse of :func:`pack`.

    Args:
        packed: A packed directive.

    Returns:
        The fields of the directive.

    Raises:
        FlashValueError: ``packed`` is negative or above :data:`PACKED_MAX`, or
            holds an action value that is not an :class:`Action`. It is
            never masked away.
    """
    if packed < 0 or packed > PACKED_MAX:
        raise FlashValueError(f"packed directive {packed} is outside the contract's [0, 0x{PACKED_MAX:x}] range")
    return Directive(
        action=Action((packed >> ACTION_SHIFT) & ((1 << ACTION_BITS) - 1)),
        lanes=(packed >> LANES_SHIFT) & ((1 << LANES_BITS) - 1),
        pre_dummy_cycles=(packed >> PRE_DUMMY_SHIFT) & ((1 << PRE_DUMMY_BITS) - 1),
        byte_out=(packed >> BYTE_OUT_SHIFT) & ((1 << BYTE_OUT_BITS) - 1),
        flags=(packed >> FLAGS_SHIFT) & ((1 << FLAGS_BITS) - 1),
        n_bytes=(packed >> N_BYTES_SHIFT) & ((1 << N_BYTES_BITS) - 1),
    )


def ignore_rest() -> int:
    """
    The "drive nothing, consume clocks until CS rises" directive.

    Used for every unsupported opcode and every command the current state
    refuses (no WEL, busy, deep power-down) -- a real device does not
    error, it simply does nothing, and so must the model.

    Returns:
        The packed :attr:`Action.IGNORE_REST` directive on one lane.
    """
    return pack(Action.IGNORE_REST, lanes=1)
