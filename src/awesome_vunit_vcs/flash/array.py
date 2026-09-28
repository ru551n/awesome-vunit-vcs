# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Sparse flash array with NOR program/erase semantics.

The storage is the shared sparse store,
:class:`~awesome_vunit_vcs.common.sparse_memory.SparseMemory`: materialized
pages plus constant-value runs, so a fill of 1 MiB is O(1) and an untouched
device costs nothing. Untouched bytes read as the erased value (0xFF).

NOR semantics live here and nowhere else:

* program can only clear bits -- ``old & new``. Programming 0xFF over 0x00
  leaves 0x00. This is the single most common thing a naive flash model
  gets wrong, and it is exactly the thing a driver under test gets wrong
  too, so the model must not paper over it.
* erase sets a region back to 0xFF.

Addresses and lengths are in bytes.
"""

from __future__ import annotations

import bisect
from operator import itemgetter

from ..common.sparse_memory import SparseMemory
from .errors import FlashValueError

#: The value of an erased byte
ERASED_BYTE = 0xFF

_start_of = itemgetter(0)


class FlashArray(SparseMemory):
    """
    The storage of one device.

    Addresses are absolute byte addresses in ``[0, size_bytes)``. Callers
    (the device) are responsible for wrapping the device's own address
    counter before calling in.

    Args:
        size_bytes: The array size in bytes, a positive multiple of ``page_bytes``.
        page_bytes: The page size in bytes, the unit bytes are materialized in.
        erased_value: The value of an erased or untouched byte, masked to 8 bits.

    Attributes:
        size_bytes: The array size in bytes.
        page_bytes: The page size in bytes.
        erased_value: The value of an erased or untouched byte.

    Raises:
        FlashValueError: ``size_bytes`` is not a positive multiple of a positive ``page_bytes``.
    """

    size_bytes: int

    def __init__(self, size_bytes: int, page_bytes: int, erased_value: int = ERASED_BYTE) -> None:
        if size_bytes <= 0 or page_bytes <= 0 or size_bytes % page_bytes:
            raise FlashValueError(f"size_bytes={size_bytes} must be a positive multiple of page_bytes={page_bytes}")
        super().__init__(size_bytes, page_bytes, erased_value)
        self.erased_value = self.default
        self._written: list[list[int]] = []

    def _check(self, addr: int, length: int) -> None:
        if addr < 0 or length < 0 or addr + length > self.size_bytes:
            raise FlashValueError(f"[0x{addr:x}, +{length}) outside device size 0x{self.size_bytes:x}")

    # -- writes ----------------------------------------------------------

    def fill(self, addr: int, length: int, value: int, *, mark: bool = False) -> None:
        """
        Set a range to a constant, ignoring NOR rules.

        The work is O(1) amortized regardless of length: whole pages are
        described by a run, never materialized.

        Args:
            addr: The first byte.
            length: The number of bytes.
            value: The byte value, masked to 8 bits.
            mark: Record the range as a written region, see :meth:`written_regions`.

        Raises:
            FlashValueError: The range is not inside the array.
        """
        super().fill(addr, length, value)
        if mark:
            self._mark_written(addr, addr + length)

    def write_raw(self, addr: int, data: bytes, *, mark: bool = False) -> None:
        """
        Overwrite bytes, ignoring NOR rules.

        For preload and image loading only -- the device itself can never do this.

        Args:
            addr: The address of the first byte.
            data: The bytes to write.
            mark: Record the range as a written region, see :meth:`written_regions`.

        Raises:
            FlashValueError: The range is not inside the array.
        """
        self.write(addr, data)
        if mark:
            self._mark_written(addr, addr + len(data))

    def program(self, addr: int, data: bytes) -> None:
        """
        NOR program: bits may only go from 1 to 0, so the stored byte becomes ``old & new``.

        The range is recorded as a written region.

        Args:
            addr: The address of the first byte.
            data: The bytes to program.

        Raises:
            FlashValueError: The range is not inside the array.
        """
        self._check(addr, len(data))
        if not data:
            return
        offset = 0
        while offset < len(data):
            page_idx, page_off = divmod(addr + offset, self.page_bytes)
            n = min(self.page_bytes - page_off, len(data) - offset)
            buf = self._page(page_idx)
            for k in range(n):
                buf[page_off + k] &= data[offset + k]
            offset += n
        self._mark_written(addr, addr + len(data))

    def erase(self, addr: int, length: int) -> None:
        """
        Erase a range back to the erased value.

        Recorded as a written region: from the testbench's point of view the
        device modified those bytes.

        Args:
            addr: The first byte.
            length: The number of bytes.

        Raises:
            FlashValueError: The range is not inside the array.
        """
        self.fill(addr, length, self.erased_value, mark=True)

    # -- written-region tracking ------------------------------------------

    def _mark_written(self, start: int, end: int) -> None:
        if end <= start:
            return
        w = self._written
        i = bisect.bisect_left(w, start, key=_start_of)
        if i > 0 and w[i - 1][1] >= start:
            i -= 1
        lo, hi = start, end
        j = i
        while j < len(w) and w[j][0] <= end:
            lo = min(lo, w[j][0])
            hi = max(hi, w[j][1])
            j += 1
        w[i:j] = [[lo, hi]]

    def written_regions(self) -> list[tuple[int, int]]:
        """
        The regions programmed, erased or written with ``mark=True``.

        Touching regions merge, so a 256-byte program of two adjacent pages
        is one region, not two.

        Returns:
            Sorted, coalesced ``(addr, length)`` pairs in bytes.
        """
        return [(s, e - s) for s, e in self._written]

    def clear_written_regions(self) -> None:
        """Forget every written region. The content is unchanged."""
        self._written.clear()
