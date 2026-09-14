# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Block protection: the status-register BP/TB/SEC decode plus an explicit
per-region lock map.

Two independent sources, unioned:

* the device's own `BP[2:0]` / `TB` / `SEC` bits, written through WRSR.
  This is what a driver under test actually manipulates, so the model has
  to decode it the way silicon does.
* `set_protection(addr, num_bytes, locked)` from the testbench, which
  models board-level write protect, a one-time-programmable lock, or
  simply "this region is precious, tell me if the DUT touches it".

The critical behaviour, and the reason this is its own module: a program
or erase that touches a protected region is **silently ignored**. No
exception, no error bit, nothing on the wire -- the device accepts the
command, does nothing, and clears WEL. That is what real parts do, and a
model that raises instead would turn a firmware bug into a simulator crash
at the wrong place, hiding the fact that the firmware never noticed either.

The BP decode is the generic JEDEC/W25Q-style one:

    BP == 0b000             -> nothing protected
    BP == 0b111             -> the whole device, whatever its size
    SEC == 0, unit = 64 KiB -> 2**(BP-1) blocks
    SEC == 1, unit =  4 KiB -> 2**(BP-1) sectors
    TB  == 0                -> protected region at the top of the array
    TB  == 1                -> protected region at the bottom

clamped to the device size, so a BP value larger than the part protects
everything rather than running off the end.
"""

from __future__ import annotations

import bisect
from operator import itemgetter

_start_of = itemgetter(0)

SEC_UNIT_BYTES = 4096
BLOCK_UNIT_BYTES = 65536


class Protection:
    """Protection state for one device instance."""

    def __init__(self, size_bytes: int) -> None:
        self.size_bytes = size_bytes
        self.bp = 0  # BP2:BP0
        self.tb = 0  # 0 = top, 1 = bottom
        self.sec = 0  # 0 = 64 KiB blocks, 1 = 4 KiB sectors
        self.cmp = 0  # complement: invert the decoded region
        self._locks: list[list[int]] = []  # sorted, disjoint [start, end)

    # -- status-register driven -------------------------------------------

    def set_status_bits(self, *, bp: int, tb: int, sec: int, cmp_: int = 0) -> None:
        self.bp = bp & 0b111
        self.tb = tb & 1
        self.sec = sec & 1
        self.cmp = cmp_ & 1

    def status_region(self) -> tuple[int, int] | None:
        """`(start, length)` protected by BP/TB/SEC/CMP, or None."""
        region = self._bp_region()
        if not self.cmp:
            return region
        # CMP inverts the selection: everything except the decoded region.
        if region is None:
            return (0, self.size_bytes)
        start, length = region
        if start == 0:
            rest = self.size_bytes - length
            return (length, rest) if rest else None
        return (0, start) if start else None

    def _bp_region(self) -> tuple[int, int] | None:
        if self.bp == 0:
            return None
        if self.bp == 0b111:
            # All-protected, independent of SEC and of the device size --
            # every part's table ends with an "entire array" row.
            return (0, self.size_bytes)
        unit = SEC_UNIT_BYTES if self.sec else BLOCK_UNIT_BYTES
        length = min(unit << (self.bp - 1), self.size_bytes)
        if self.tb:
            return (0, length)
        return (self.size_bytes - length, length)

    # -- explicit lock map -------------------------------------------------

    def set_region(self, addr: int, num_bytes: int, locked: bool) -> None:
        """Lock or unlock `[addr, addr+num_bytes)` explicitly. Overlapping
        calls are merged/split, so lock-then-unlock-a-hole works."""
        if num_bytes <= 0:
            return
        if addr < 0 or addr + num_bytes > self.size_bytes:
            raise ValueError(f"protection region [0x{addr:x}, +{num_bytes}) outside device")
        end = addr + num_bytes
        locks = self._locks
        i = bisect.bisect_left(locks, addr, key=_start_of)
        if i > 0 and locks[i - 1][1] >= addr:
            i -= 1
        j = i
        lo, hi = addr, end
        replacement: list[list[int]] = []
        while j < len(locks) and locks[j][0] <= end:
            s, e = locks[j]
            if locked:
                lo = min(lo, s)
                hi = max(hi, e)
            else:
                if s < addr:
                    replacement.append([s, addr])
                if e > end:
                    replacement.append([end, e])
            j += 1
        if locked:
            replacement = [[lo, hi]]
        locks[i:j] = replacement

    def locked_regions(self) -> list[tuple[int, int]]:
        return [(s, e - s) for s, e in self._locks]

    def clear_regions(self) -> None:
        self._locks.clear()

    # -- the question the device actually asks ------------------------------

    def is_protected(self, addr: int, num_bytes: int) -> bool:
        """True if ANY byte of `[addr, addr+num_bytes)` is protected.

        Any overlap protects the whole operation: silicon refuses the
        instruction outright rather than programming the unprotected part
        of a straddling page.
        """
        if num_bytes <= 0:
            return False
        end = addr + num_bytes
        region = self.status_region()
        if region is not None:
            rs, rl = region
            if addr < rs + rl and rs < end:
                return True
        locks = self._locks
        i = bisect.bisect_left(locks, addr, key=_start_of)
        if i > 0 and locks[i - 1][1] > addr:
            return True
        return i < len(locks) and locks[i][0] < end

    def reset(self) -> None:
        """A device reset restores the volatile protection bits but leaves
        the testbench's explicit lock map alone -- that map models
        something outside the chip."""
        self.bp = 0
        self.tb = 0
        self.sec = 0
        self.cmp = 0
