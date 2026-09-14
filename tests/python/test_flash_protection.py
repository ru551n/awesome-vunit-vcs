# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Block-protection decode and the explicit lock map."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash.protection import Protection

MIB = 1024 * 1024
SIZE = 16 * MIB


@pytest.fixture
def prot() -> Protection:
    return Protection(SIZE)


def test_nothing_is_protected_by_default(prot: Protection) -> None:
    assert prot.status_region() is None
    assert not prot.is_protected(0, SIZE)


@pytest.mark.parametrize(
    ("bp", "tb", "sec", "expected"),
    [
        (1, 0, 0, (SIZE - 64 * 1024, 64 * 1024)),  # top 64 KiB
        (2, 0, 0, (SIZE - 128 * 1024, 128 * 1024)),
        (3, 0, 0, (SIZE - 256 * 1024, 256 * 1024)),
        (1, 1, 0, (0, 64 * 1024)),  # bottom 64 KiB
        (1, 0, 1, (SIZE - 4096, 4096)),  # top 4 KiB sector
        (2, 1, 1, (0, 8192)),  # bottom two sectors
        (6, 0, 0, (SIZE - 2 * MIB, 2 * MIB)),
        (7, 0, 0, (0, SIZE)),  # the all-protected row
        (7, 1, 1, (0, SIZE)),  # ... regardless of TB/SEC
    ],
)
def test_bp_tb_sec_decode(prot: Protection, bp, tb, sec, expected) -> None:
    prot.set_status_bits(bp=bp, tb=tb, sec=sec)
    assert prot.status_region() == expected


def test_cmp_inverts_the_decoded_region(prot: Protection) -> None:
    prot.set_status_bits(bp=1, tb=1, sec=0, cmp_=1)
    assert prot.status_region() == (64 * 1024, SIZE - 64 * 1024)
    prot.set_status_bits(bp=0, tb=0, sec=0, cmp_=1)
    assert prot.status_region() == (0, SIZE)


def test_protection_is_any_overlap_not_containment(prot: Protection) -> None:
    prot.set_status_bits(bp=1, tb=1, sec=0)  # bottom 64 KiB
    assert prot.is_protected(0x0000, 1)
    assert prot.is_protected(0xFFFF, 1)
    assert not prot.is_protected(0x10000, 1)
    # A page straddling the boundary is protected as a whole.
    assert prot.is_protected(0xFFF0, 0x20)


def test_zero_length_is_never_protected(prot: Protection) -> None:
    prot.set_status_bits(bp=7, tb=0, sec=0)
    assert not prot.is_protected(0, 0)


# -- explicit lock map ---------------------------------------------------------


def test_explicit_lock_map_merges_and_splits(prot: Protection) -> None:
    prot.set_region(0x1000, 0x1000, True)
    prot.set_region(0x2000, 0x1000, True)
    assert prot.locked_regions() == [(0x1000, 0x2000)]
    prot.set_region(0x1800, 0x800, False)
    assert prot.locked_regions() == [(0x1000, 0x800), (0x2000, 0x1000)]
    assert prot.is_protected(0x1800, 1) is False
    assert prot.is_protected(0x17FF, 1) is True


def test_unlocking_a_region_never_locked_is_harmless(prot: Protection) -> None:
    prot.set_region(0x5000, 0x1000, False)
    assert prot.locked_regions() == []


def test_explicit_lock_and_bp_are_unioned(prot: Protection) -> None:
    prot.set_status_bits(bp=1, tb=1, sec=0)  # bottom 64 KiB
    prot.set_region(0x20_0000, 0x1000, True)
    assert prot.is_protected(0x0000, 1)
    assert prot.is_protected(0x20_0000, 1)
    assert not prot.is_protected(0x10_0000, 1)


def test_lock_boundaries_are_half_open(prot: Protection) -> None:
    prot.set_region(0x1000, 0x100, True)
    assert prot.is_protected(0x0FFF, 1) is False
    assert prot.is_protected(0x1000, 1) is True
    assert prot.is_protected(0x10FF, 1) is True
    assert prot.is_protected(0x1100, 1) is False
    # A range that merely touches the end does not overlap it.
    assert prot.is_protected(0x1100, 0x10) is False
    assert prot.is_protected(0x0F00, 0x100) is False


def test_region_outside_the_device_raises(prot: Protection) -> None:
    with pytest.raises(ValueError):
        prot.set_region(SIZE - 16, 32, True)
    with pytest.raises(ValueError):
        prot.set_region(-1, 16, True)


def test_reset_clears_status_bits_but_keeps_the_lock_map(prot: Protection) -> None:
    prot.set_status_bits(bp=3, tb=1, sec=0)
    prot.set_region(0x8000, 0x1000, True)
    prot.reset()
    assert prot.status_region() is None
    assert prot.locked_regions() == [(0x8000, 0x1000)]
