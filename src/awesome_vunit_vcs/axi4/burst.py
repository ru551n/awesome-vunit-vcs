# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Burst arithmetic of AXI4: the address and the byte lanes of every beat.

The formulas are those of the AXI specification (ARM IHI 0022, "Transfer address"): ``size`` is the
AxSIZE code (``2**size`` bytes per beat), ``length`` the AxLEN code (``length + 1`` beats), and byte
lanes are numbered from 0, the lane of WDATA[7:0] and RDATA[7:0].
"""

from __future__ import annotations

import enum

__all__ = ["BurstType", "beat_addresses", "beat_lanes", "crosses_4k", "lane_mask"]

#: The size of the address region a burst must not cross, in bytes
BOUNDARY_4K = 4096


class BurstType(enum.IntEnum):
    """The AxBURST encodings."""

    FIXED = 0
    INCR = 1
    WRAP = 2
    #: Reserved; a burst of this type is a protocol violation
    RESERVED = 3


def beat_addresses(address: int, length: int, size: int, burst: int) -> list[int]:
    """
    The address of every beat of a burst.

    A FIXED burst repeats its start address. An INCR burst continues from the start address aligned to
    the size. A WRAP burst wraps at the boundary aligned to its total size in bytes. A RESERVED burst is
    taken as INCR.

    Args:
        address: AxADDR, the start address.
        length: AxLEN; the burst has ``length + 1`` beats.
        size: AxSIZE; each beat is ``2**size`` bytes.
        burst: AxBURST, a :class:`BurstType` or its value.
    """
    number_bytes = 1 << size
    beats = length + 1
    if burst == BurstType.FIXED:
        return [address] * beats
    aligned = address // number_bytes * number_bytes
    if burst == BurstType.WRAP:
        total = number_bytes * beats
        boundary = address // total * total
        return [address] + [boundary + (aligned - boundary + index * number_bytes) % total for index in range(1, beats)]
    return [address] + [aligned + index * number_bytes for index in range(1, beats)]


def beat_lanes(address: int, length: int, size: int, burst: int, data_bytes: int) -> list[tuple[int, int]]:
    """
    The lowest and highest byte lane of every beat of a burst, both included.

    The first beat of an unaligned burst, and every beat of an unaligned FIXED burst, starts at the lane
    of its address and ends at the end of the aligned beat. A beat narrower than the bus moves across
    the lanes with its address.

    Args:
        address: AxADDR.
        length: AxLEN.
        size: AxSIZE.
        burst: AxBURST.
        data_bytes: The width of the data bus in bytes.
    """
    number_bytes = 1 << size
    aligned = address // number_bytes * number_bytes
    first_lower = address - address // data_bytes * data_bytes
    first_upper = min(aligned + number_bytes - 1 - address // data_bytes * data_bytes, data_bytes - 1)
    lanes = []
    for index, beat_address in enumerate(beat_addresses(address, length, size, burst)):
        if index == 0 or burst == BurstType.FIXED:
            lanes.append((first_lower, first_upper))
        else:
            lower = beat_address - beat_address // data_bytes * data_bytes
            lanes.append((lower, min(lower + number_bytes - 1, data_bytes - 1)))
    return lanes


def lane_mask(lanes: tuple[int, int]) -> int:
    """A mask with bit ``n`` set for every lane ``n`` from ``lanes[0]`` to ``lanes[1]``."""
    lower, upper = lanes
    return ((1 << (upper - lower + 1)) - 1) << lower if upper >= lower else 0


def crosses_4k(address: int, length: int, size: int, burst: int) -> bool:
    """
    Whether an INCR burst crosses a 4 KB address boundary. FIXED and WRAP bursts never cross one on
    their own; a WRAP burst of legal length and alignment stays inside its wrap boundary.
    """
    if burst != BurstType.INCR:
        return False
    number_bytes = 1 << size
    last = address // number_bytes * number_bytes + (length + 1) * number_bytes - 1
    return address // BOUNDARY_4K != last // BOUNDARY_4K
