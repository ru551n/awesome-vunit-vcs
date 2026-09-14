# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Storage tests: NOR semantics, the sparse run overlay, and written-region
coalescing.

The adversarial cases here are all about the two representations
(materialized pages and constant-value runs) disagreeing. Every test that
fills across a page boundary, or programs into the middle of a fill, is
probing exactly that seam."""

from __future__ import annotations

import time

import pytest

from awesome_vunit_vcs.flash.array import FlashArray

MIB = 1024 * 1024


@pytest.fixture
def arr() -> FlashArray:
    return FlashArray(16 * MIB, 256)


# -- NOR semantics -----------------------------------------------------------


def test_untouched_array_reads_erased(arr: FlashArray) -> None:
    assert arr.read(0, 8) == b"\xff" * 8
    assert arr.read(16 * MIB - 4, 4) == b"\xff" * 4
    assert arr.materialized_pages == 0


def test_program_can_only_clear_bits(arr: FlashArray) -> None:
    arr.program(0x100, bytes([0b1010_1010]))
    assert arr.read_byte(0x100) == 0b1010_1010
    # Programming 0xFF over it must NOT restore the bits.
    arr.program(0x100, bytes([0xFF]))
    assert arr.read_byte(0x100) == 0b1010_1010
    # A second program ANDs again.
    arr.program(0x100, bytes([0b1100_1100]))
    assert arr.read_byte(0x100) == 0b1000_1000


def test_program_of_zero_is_absorbing(arr: FlashArray) -> None:
    arr.program(0, b"\x00")
    for value in (0xFF, 0x5A, 0x01):
        arr.program(0, bytes([value]))
        assert arr.read_byte(0) == 0x00


def test_only_erase_restores_bits(arr: FlashArray) -> None:
    arr.program(0x2000, b"\x00" * 4)
    arr.erase(0x2000, 4096)
    assert arr.read(0x2000, 4) == b"\xff" * 4


def test_program_spanning_pages_is_not_wrapped_here(arr: FlashArray) -> None:
    # The array is address-flat; page-wrap is a device-level rule.
    arr.program(0xFE, bytes(range(4)))
    assert arr.read(0xFE, 4) == bytes(range(4))
    assert arr.materialized_pages == 2


# -- sparse fill --------------------------------------------------------------


def test_preload_fill_over_1mib_is_fast_and_materializes_nothing(
    arr: FlashArray,
) -> None:
    start = time.perf_counter()
    arr.fill(0, MIB, 0x5A)
    elapsed = time.perf_counter() - start
    assert arr.materialized_pages == 0
    assert arr.materialized_bytes == 0
    assert arr.run_count == 1
    # Generous by three orders of magnitude: the point is that it is O(1),
    # not that this machine is fast.
    assert elapsed < 0.05
    assert arr.read(0, 4) == b"\x5a" * 4
    assert arr.read(MIB - 4, 8) == b"\x5a" * 4 + b"\xff" * 4


def test_whole_device_fill_is_still_o1(arr: FlashArray) -> None:
    arr.fill(0, 16 * MIB, 0x00)
    assert arr.materialized_pages == 0
    assert arr.run_count == 1
    assert arr.read_byte(16 * MIB - 1) == 0x00


def test_erase_needs_no_run_at_all(arr: FlashArray) -> None:
    arr.fill(0, MIB, 0x5A)
    arr.erase(0, MIB)
    assert arr.run_count == 0
    assert arr.materialized_pages == 0
    assert arr.read(0, 4) == b"\xff" * 4


def test_sparse_preload_leaves_neighbours_erased(arr: FlashArray) -> None:
    arr.write_raw(0x1000, b"\xaa" * 4)
    arr.write_raw(0x8_0000, b"\xbb" * 4)
    assert arr.read(0x0FFC, 12) == b"\xff" * 4 + b"\xaa" * 4 + b"\xff" * 4
    assert arr.read(0x7_FFFC, 12) == b"\xff" * 4 + b"\xbb" * 4 + b"\xff" * 4
    assert arr.materialized_pages == 2


def test_program_into_a_fill_materializes_only_its_own_page(arr: FlashArray) -> None:
    arr.fill(0, MIB, 0x0F)
    arr.program(0x400, b"\xf0")
    assert arr.materialized_pages == 1
    assert arr.read_byte(0x400) == 0x00  # 0x0F & 0xF0
    assert arr.read_byte(0x401) == 0x0F  # the rest of the page kept the fill
    assert arr.read_byte(0x3FF) == 0x0F  # and so did the neighbouring run


def test_fill_across_a_materialized_page_keeps_both_views_consistent(
    arr: FlashArray,
) -> None:
    arr.write_raw(0x1000, bytes(range(256)))  # exactly one page
    arr.write_raw(0x1100, b"\x11" * 8)  # start of the next page
    arr.fill(0x1080, 0x100, 0x77)  # straddles both pages
    assert arr.read(0x1078, 0x10) == bytes(range(0x78, 0x80)) + b"\x77" * 8
    assert arr.read(0x1178, 0x10) == b"\x77" * 8 + b"\xff" * 8
    assert arr.read_byte(0x1100) == 0x77  # fill won over the earlier bytes


def test_fill_fully_covering_a_page_drops_it(arr: FlashArray) -> None:
    arr.write_raw(0x1000, b"\x01" * 256)
    assert arr.materialized_pages == 1
    arr.fill(0x0F00, 0x400, 0x22)
    assert arr.materialized_pages == 0
    assert arr.read(0x1000, 4) == b"\x22" * 4


def test_overlapping_fills_of_the_same_value_coalesce(arr: FlashArray) -> None:
    arr.fill(0x0000, 0x1000, 0x33)
    arr.fill(0x1000, 0x1000, 0x33)
    arr.fill(0x0800, 0x1000, 0x33)
    assert arr.run_count == 1
    assert arr.read(0x1FFC, 8) == b"\x33" * 4 + b"\xff" * 4


def test_a_fill_punched_out_of_a_fill(arr: FlashArray) -> None:
    arr.fill(0, MIB, 0xAA)
    arr.fill(0x1000, 0x1000, 0xBB)
    assert arr.read(0x0FFF, 2) == b"\xaa\xbb"
    assert arr.read(0x1FFF, 2) == b"\xbb\xaa"
    assert arr.run_count == 3


def test_read_spanning_runs_pages_and_gaps(arr: FlashArray) -> None:
    arr.fill(0x000, 0x100, 0x11)
    arr.write_raw(0x100, b"\x22" * 0x100)
    # 0x200..0x2FF left untouched
    arr.fill(0x300, 0x100, 0x33)
    assert arr.read(0x0FE, 4) == b"\x11\x11\x22\x22"
    assert arr.read(0x1FE, 4) == b"\x22\x22\xff\xff"
    assert arr.read(0x2FE, 4) == b"\xff\xff\x33\x33"


def test_bounds_are_enforced(arr: FlashArray) -> None:
    with pytest.raises(ValueError):
        arr.read(16 * MIB - 2, 4)
    with pytest.raises(ValueError):
        arr.program(16 * MIB, b"\x00")
    with pytest.raises(ValueError):
        arr.fill(-1, 4, 0)


def test_geometry_is_validated() -> None:
    with pytest.raises(ValueError):
        FlashArray(1000, 256)
    with pytest.raises(ValueError):
        FlashArray(0, 256)


# -- written regions ----------------------------------------------------------


def test_written_regions_coalesce_adjacent_writes(arr: FlashArray) -> None:
    arr.program(0x100, b"\x00" * 0x40)
    arr.program(0x140, b"\x00" * 0x40)
    assert arr.written_regions() == [(0x100, 0x80)]


def test_written_regions_keep_disjoint_writes_apart(arr: FlashArray) -> None:
    arr.program(0x100, b"\x00")
    arr.program(0x200, b"\x00")
    arr.program(0x101, b"\x00")
    assert arr.written_regions() == [(0x100, 2), (0x200, 1)]


def test_written_regions_merge_when_a_gap_is_filled(arr: FlashArray) -> None:
    arr.program(0x000, b"\x00")
    arr.program(0x010, b"\x00")
    arr.program(0x001, b"\x00" * 0x0F)
    assert arr.written_regions() == [(0x000, 0x11)]


def test_out_of_order_writes_still_coalesce(arr: FlashArray) -> None:
    for addr in (0x300, 0x100, 0x200):
        arr.program(addr, b"\x00" * 0x100)
    assert arr.written_regions() == [(0x100, 0x300)]


def test_erase_is_recorded_but_preload_is_not(arr: FlashArray) -> None:
    arr.write_raw(0x1000, b"\x00" * 16)
    arr.fill(0x2000, 16, 0x00)
    assert arr.written_regions() == []
    arr.erase(0x3000, 4096)
    assert arr.written_regions() == [(0x3000, 4096)]
    arr.clear_written_regions()
    assert arr.written_regions() == []


def test_preload_can_opt_into_marking(arr: FlashArray) -> None:
    arr.write_raw(0x40, b"\x01", mark=True)
    assert arr.written_regions() == [(0x40, 1)]
