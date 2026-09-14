# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Sparse flash array with NOR program/erase semantics.

Two representations coexist, and the whole point of the module is keeping
them consistent:

* materialized pages: ``{page index -> bytearray}``, the bytes that have
  actually been touched at byte granularity.
* runs: a sorted list of disjoint ``[start, end, value]`` constant-value
  runs. A fill of 1 MiB of 0x00 is one run: O(1) work, zero bytes
  materialized. A 16 MiB model filled with a pattern must not cost 16 MiB
  of Python heap, because a testbench doing that per test would dominate
  the simulation's run time.

Invariant: runs and materialized pages never overlap. Materializing a page
subtracts its span from the runs (splitting at most one run in two);
filling a range drops the pages it fully covers and patches the at most two
pages it partly covers. Anything absent from both reads as the erased value
(0xFF), so an untouched device costs nothing at all.

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

#: The value of an erased byte
ERASED_BYTE = 0xFF

_start_of = itemgetter(0)


def _subtract(pieces: list[tuple[int, int]], lo: int, hi: int) -> list[tuple[int, int]]:
    """Remove ``[lo, hi)`` from a list of disjoint ascending ranges."""
    out: list[tuple[int, int]] = []
    for s, e in pieces:
        if e <= lo or s >= hi:
            out.append((s, e))
            continue
        if s < lo:
            out.append((s, lo))
        if e > hi:
            out.append((hi, e))
    return out


class FlashArray:
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
        ValueError: ``size_bytes`` is not a positive multiple of a positive ``page_bytes``.
    """

    def __init__(self, size_bytes: int, page_bytes: int, erased_value: int = ERASED_BYTE) -> None:
        if size_bytes <= 0 or page_bytes <= 0 or size_bytes % page_bytes:
            raise ValueError(f"size_bytes={size_bytes} must be a positive multiple of page_bytes={page_bytes}")
        self.size_bytes = size_bytes
        self.page_bytes = page_bytes
        self.erased_value = erased_value & 0xFF
        self._pages: dict[int, bytearray] = {}
        # Sorted list of materialized page indices, so a fill over a huge
        # range can find the (usually zero) pages it intersects in O(log n)
        # rather than scanning every key.
        self._page_index: list[int] = []
        self._runs: list[list[int]] = []
        self._written: list[list[int]] = []

    # -- introspection (tests and diagnostics) ---------------------------

    @property
    def materialized_pages(self) -> int:
        """Number of pages held as real bytes. A fill must leave this alone -- the sparse-fill test asserts it."""
        return len(self._pages)

    @property
    def materialized_bytes(self) -> int:
        """Bytes held as real bytes, :attr:`materialized_pages` times :attr:`page_bytes`."""
        return len(self._pages) * self.page_bytes

    @property
    def run_count(self) -> int:
        """Number of constant-value runs describing filled regions."""
        return len(self._runs)

    # -- bounds ----------------------------------------------------------

    def _check(self, addr: int, length: int) -> None:
        if addr < 0 or length < 0 or addr + length > self.size_bytes:
            raise ValueError(f"[0x{addr:x}, +{length}) outside device size 0x{self.size_bytes:x}")

    # -- run bookkeeping -------------------------------------------------

    def _runs_remove(self, start: int, end: int) -> None:
        runs = self._runs
        i = bisect.bisect_left(runs, start, key=_start_of)
        if i > 0 and runs[i - 1][1] > start:
            i -= 1
        replacement: list[list[int]] = []
        j = i
        while j < len(runs) and runs[j][0] < end:
            s, e, v = runs[j]
            if s < start:
                replacement.append([s, start, v])
            if e > end:
                replacement.append([end, e, v])
            j += 1
        if j > i or replacement:
            runs[i:j] = replacement

    def _runs_insert(self, start: int, end: int, value: int) -> None:
        """Insert a run over a span already cleared by ``_runs_remove``,
        coalescing with equal-valued neighbours so a repeated fill of the
        same value cannot grow the run list without bound."""
        if end <= start:
            return
        runs = self._runs
        i = bisect.bisect_left(runs, start, key=_start_of)
        if i < len(runs) and runs[i][0] == end and runs[i][2] == value:
            end = runs[i][1]
            del runs[i]
        if i > 0 and runs[i - 1][1] == start and runs[i - 1][2] == value:
            runs[i - 1][1] = end
            return
        runs.insert(i, [start, end, value])

    def _run_value_at(self, addr: int) -> int | None:
        runs = self._runs
        i = bisect.bisect_right(runs, addr, key=_start_of) - 1
        if i >= 0 and runs[i][0] <= addr < runs[i][1]:
            return runs[i][2]
        return None

    # -- page materialization --------------------------------------------

    def _page(self, page_idx: int) -> bytearray:
        """The real bytes of one page, created from the run overlay on
        first touch. This is the only place a page comes into existence."""
        buf = self._pages.get(page_idx)
        if buf is not None:
            return buf
        ps = page_idx * self.page_bytes
        pe = ps + self.page_bytes
        buf = bytearray([self.erased_value]) * self.page_bytes
        runs = self._runs
        i = bisect.bisect_left(runs, ps, key=_start_of)
        if i > 0 and runs[i - 1][1] > ps:
            i -= 1
        while i < len(runs) and runs[i][0] < pe:
            s, e, v = runs[i]
            a = max(s, ps) - ps
            b = min(e, pe) - ps
            buf[a:b] = bytes([v]) * (b - a)
            i += 1
        self._runs_remove(ps, pe)
        self._pages[page_idx] = buf
        bisect.insort(self._page_index, page_idx)
        return buf

    # -- reads -----------------------------------------------------------

    def read(self, addr: int, length: int) -> bytes:
        """
        Read a range.

        Args:
            addr: The first byte.
            length: The number of bytes.

        Returns:
            The bytes at ``[addr, addr + length)``. Untouched bytes read as erased.

        Raises:
            ValueError: The range is not inside the array.
        """
        self._check(addr, length)
        if length == 0:
            return b""
        end = addr + length
        out = bytearray([self.erased_value]) * length
        runs = self._runs
        i = bisect.bisect_left(runs, addr, key=_start_of)
        if i > 0 and runs[i - 1][1] > addr:
            i -= 1
        while i < len(runs) and runs[i][0] < end:
            s, e, v = runs[i]
            a = max(s, addr) - addr
            b = min(e, end) - addr
            out[a:b] = bytes([v]) * (b - a)
            i += 1
        for page_idx in self._pages_in(addr, end):
            ps = page_idx * self.page_bytes
            pe = ps + self.page_bytes
            a = max(ps, addr)
            b = min(pe, end)
            out[a - addr : b - addr] = self._pages[page_idx][a - ps : b - ps]
        return bytes(out)

    def read_byte(self, addr: int) -> int:
        """
        Read one byte, on the hot path of every ``xfer``.

        It is kept free of the slicing and the bounds check :meth:`read` does,
        so an address outside the array reads as erased instead of raising.

        Args:
            addr: The address of the byte.

        Returns:
            The byte value.
        """
        page_idx, offset = divmod(addr, self.page_bytes)
        buf = self._pages.get(page_idx)
        if buf is not None:
            return buf[offset]
        value = self._run_value_at(addr)
        return self.erased_value if value is None else value

    def _pages_in(self, start: int, end: int) -> list[int]:
        if end <= start:
            return []
        lo = start // self.page_bytes
        hi = (end - 1) // self.page_bytes
        i = bisect.bisect_left(self._page_index, lo)
        j = bisect.bisect_right(self._page_index, hi)
        return self._page_index[i:j]

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
            ValueError: The range is not inside the array.
        """
        self._check(addr, length)
        if length == 0:
            return
        value &= 0xFF
        end = addr + length
        lo = addr // self.page_bytes
        hi = (end - 1) // self.page_bytes
        i = bisect.bisect_left(self._page_index, lo)
        j = bisect.bisect_right(self._page_index, hi)
        kept: list[int] = []
        partial: list[tuple[int, int]] = []
        for page_idx in self._page_index[i:j]:
            ps = page_idx * self.page_bytes
            pe = ps + self.page_bytes
            if ps >= addr and pe <= end:
                # Fully covered: the run below describes it, so the bytes
                # are pure overhead.
                del self._pages[page_idx]
                continue
            buf = self._pages[page_idx]
            a = max(ps, addr) - ps
            b = min(pe, end) - ps
            buf[a:b] = bytes([value]) * (b - a)
            kept.append(page_idx)
            partial.append((ps, pe))
        self._page_index[i:j] = kept
        self._runs_remove(addr, end)
        if value != self.erased_value:
            # The erased value is the implicit default, so an erase needs no
            # run at all -- that keeps chip erase O(1) and the run list short.
            pieces: list[tuple[int, int]] = [(addr, end)]
            for ps, pe in partial:
                pieces = _subtract(pieces, ps, pe)
            for s, e in pieces:
                self._runs_insert(s, e, value)
        if mark:
            self._mark_written(addr, end)

    def write_raw(self, addr: int, data: bytes, *, mark: bool = False) -> None:
        """
        Overwrite bytes, ignoring NOR rules.

        For preload and image loading only -- the device itself can never do this.

        Args:
            addr: The address of the first byte.
            data: The bytes to write.
            mark: Record the range as a written region, see :meth:`written_regions`.

        Raises:
            ValueError: The range is not inside the array.
        """
        self._check(addr, len(data))
        if not data:
            return
        offset = 0
        while offset < len(data):
            page_idx, page_off = divmod(addr + offset, self.page_bytes)
            n = min(self.page_bytes - page_off, len(data) - offset)
            self._page(page_idx)[page_off : page_off + n] = data[offset : offset + n]
            offset += n
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
            ValueError: The range is not inside the array.
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
            ValueError: The range is not inside the array.
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
