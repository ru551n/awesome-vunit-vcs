# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Directive pack/unpack: the one piece of this model whose bit layout is
duplicated by hand in VHDL, so it gets hardcoded golden values rather than
only round-trips. A round-trip test passes just as happily against a layout
that disagrees with the contract."""

from __future__ import annotations

import itertools

import pytest

from awesome_vunit_vcs.flash import directive as d


def test_field_table_matches_the_contract() -> None:
    assert (d.ACTION_SHIFT, d.ACTION_BITS) == (0, 2)
    assert (d.LANES_SHIFT, d.LANES_BITS) == (2, 3)
    assert (d.PRE_DUMMY_SHIFT, d.PRE_DUMMY_BITS) == (5, 6)
    assert (d.BYTE_OUT_SHIFT, d.BYTE_OUT_BITS) == (11, 8)
    assert (d.FLAGS_SHIFT, d.FLAGS_BITS) == (19, 2)
    assert (d.N_BYTES_SHIFT, d.N_BYTES_BITS) == (21, 9)


def test_fields_are_contiguous_and_fit_in_thirty_bits() -> None:
    fields = [
        (d.ACTION_SHIFT, d.ACTION_BITS),
        (d.LANES_SHIFT, d.LANES_BITS),
        (d.PRE_DUMMY_SHIFT, d.PRE_DUMMY_BITS),
        (d.BYTE_OUT_SHIFT, d.BYTE_OUT_BITS),
        (d.FLAGS_SHIFT, d.FLAGS_BITS),
        (d.N_BYTES_SHIFT, d.N_BYTES_BITS),
    ]
    expected_shift = 0
    for shift, width in fields:
        assert shift == expected_shift, "fields must be packed without gaps"
        expected_shift += width
    # 30 bits, not 32: VHDL's integer is signed, so 2**31 cannot cross.
    assert expected_shift == 30
    assert d.PACKED_MAX == 2**30 - 1


def test_golden_encodings() -> None:
    assert d.pack(d.Action.RECEIVE, lanes=1) == 0b1_00 | (1 << d.N_BYTES_SHIFT)
    # 0x6B's data phase: transmit, 4 lanes, 8 dummy cycles first, byte 0xA5.
    packed = d.pack(d.Action.TRANSMIT, lanes=4, pre_dummy_cycles=8, byte_out=0xA5)
    assert packed == (1 | (4 << 2) | (8 << 5) | (0xA5 << 11) | (1 << 21))
    assert d.ignore_rest() == (2 | (1 << 2) | (1 << 21))


@pytest.mark.parametrize(
    ("action", "lanes", "dummy", "byte_out", "flags", "n_bytes"),
    list(itertools.product(list(d.Action), (1, 2, 4), (0, 1, 63), (0, 0x5A, 255), (0, 1, 3), (1, 2, 511)))[::7],
)
def test_round_trip(action, lanes, dummy, byte_out, flags, n_bytes) -> None:
    packed = d.pack(
        action,
        lanes=lanes,
        pre_dummy_cycles=dummy,
        byte_out=byte_out,
        flags=flags,
        n_bytes=n_bytes,
    )
    assert 0 <= packed <= d.PACKED_MAX
    back = d.unpack(packed)
    assert (back.action, back.lanes, back.pre_dummy_cycles) == (action, lanes, dummy)
    assert (back.byte_out, back.flags, back.n_bytes) == (byte_out, flags, n_bytes)
    assert back.volatile == bool(flags & d.FLAG_VOLATILE)


def test_every_representable_directive_stays_inside_the_budget() -> None:
    widest = d.pack(
        d.Action.IGNORE_REST,
        lanes=4,
        pre_dummy_cycles=(1 << d.PRE_DUMMY_BITS) - 1,
        byte_out=0xFF,
        flags=(1 << d.FLAGS_BITS) - 1,
        n_bytes=(1 << d.N_BYTES_BITS) - 1,
    )
    assert widest <= d.PACKED_MAX


@pytest.mark.parametrize(
    ("kwargs", "match"),
    [
        ({"lanes": 3}, "lanes"),
        ({"lanes": 0}, "lanes"),
        ({"lanes": 8}, "lanes"),
        ({"pre_dummy_cycles": 64}, "pre_dummy_cycles"),
        ({"pre_dummy_cycles": -1}, "pre_dummy_cycles"),
        ({"byte_out": 256}, "byte_out"),
        ({"byte_out": -1}, "byte_out"),
        ({"flags": 4}, "flags"),
        ({"n_bytes": 512}, "n_bytes"),
        ({"n_bytes": -1}, "n_bytes"),
    ],
)
def test_out_of_range_fields_raise(kwargs, match) -> None:
    with pytest.raises(ValueError, match=match):
        d.pack(d.Action.RECEIVE, **kwargs)


@pytest.mark.parametrize("packed", [-1, 2**30, 2**31, 2**31 - 1])
def test_unpack_rejects_values_outside_the_budget(packed: int) -> None:
    with pytest.raises(ValueError):
        d.unpack(packed)


def test_action_encoding_is_the_contract_order() -> None:
    assert (d.Action.RECEIVE, d.Action.TRANSMIT, d.Action.IGNORE_REST) == (0, 1, 2)
