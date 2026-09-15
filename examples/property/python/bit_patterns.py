# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Reusable hardware-aware bit-pattern strategies, generic in bit width."""

from hypothesis import strategies as st


# docs-start: constants
def zero(width: int) -> int:
    return 0


def one(width: int) -> int:
    return 1


def all_ones(width: int) -> int:
    return (1 << width) - 1


def sign_bit(width: int) -> int:
    # Only the MSB set, the smallest negative value in two's complement
    return 1 << (width - 1)


def max_signed_positive(width: int) -> int:
    # MSB clear, every other bit set: the largest positive two's-complement value
    return (1 << (width - 1)) - 1


# docs-end: constants


# docs-start: powers
def powers_of_two(width: int) -> st.SearchStrategy[int]:
    return st.sampled_from([1 << bit for bit in range(width)])


def powers_of_two_minus_one(width: int) -> st.SearchStrategy[int]:
    return st.sampled_from([(1 << bit) - 1 for bit in range(1, width + 1)])


def powers_of_two_plus_one(width: int) -> st.SearchStrategy[int]:
    limit = 1 << width
    values = [(1 << bit) + 1 for bit in range(1, width) if (1 << bit) + 1 < limit]
    return st.sampled_from(values)


# docs-end: powers


# docs-start: walking
def one_hot(width: int) -> st.SearchStrategy[int]:
    # A single set bit at any position: the walking-one pattern
    return st.integers(0, width - 1).map(lambda bit: 1 << bit)


def one_cold(width: int) -> st.SearchStrategy[int]:
    # A single cleared bit at any position: the walking-zero pattern
    full = all_ones(width)
    return st.integers(0, width - 1).map(lambda bit: full ^ (1 << bit))


# docs-end: walking


# docs-start: alternating
def alternating_bits(width: int) -> st.SearchStrategy[int]:
    # 0101... and 1010..., both truncated to width bits
    even_bits = sum(1 << bit for bit in range(0, width, 2))
    return st.sampled_from([even_bits, all_ones(width) ^ even_bits])


# docs-end: alternating


# docs-start: masks
def contiguous_mask(width: int) -> st.SearchStrategy[int]:
    # A run of ones of any length, at any position
    def mask(length: int) -> st.SearchStrategy[int]:
        return st.integers(0, width - length).map(lambda start: ((1 << length) - 1) << start)

    return st.integers(1, width).flatmap(mask)


def sparse_mask(width: int) -> st.SearchStrategy[int]:
    # A handful of set bits, scattered at random positions
    positions = st.integers(0, width - 1)
    return st.sets(positions, min_size=1, max_size=3).map(lambda bits: sum(1 << bit for bit in bits))


# docs-end: masks


# docs-start: interesting_unsigned
def interesting_unsigned(width: int) -> st.SearchStrategy[int]:
    # Structured, hardware-relevant corner cases mixed with ordinary arbitrary values.
    # Hypothesis shrinks sampled_from towards earlier elements and one_of towards
    # earlier branches, so the simplest patterns (few or one bit set) come first.
    structured = st.one_of(
        st.sampled_from([zero(width), one(width), sign_bit(width), max_signed_positive(width), all_ones(width)]),
        powers_of_two(width),
        one_hot(width),
        powers_of_two_minus_one(width),
        powers_of_two_plus_one(width),
        one_cold(width),
        contiguous_mask(width),
        sparse_mask(width),
        alternating_bits(width),
    )
    arbitrary = st.integers(0, (1 << width) - 1)
    return st.one_of(structured, arbitrary)


# docs-end: interesting_unsigned
