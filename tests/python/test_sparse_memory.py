# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The shared sparse store against a dict-per-byte reference, including random operation sequences."""

from __future__ import annotations

import random

import pytest

from awesome_vunit_vcs.common.sparse_memory import SparseMemory, SparseMemoryError


class Reference:
    """One dict entry per byte ever set: obviously correct, and slow."""

    def __init__(self, default: int) -> None:
        self.default = default
        self.bytes: dict[int, int] = {}

    def read(self, addr: int, length: int) -> bytes:
        return bytes(self.bytes.get(a, self.default) for a in range(addr, addr + length))

    def write(self, addr: int, data: bytes) -> None:
        for offset, value in enumerate(data):
            self.bytes[addr + offset] = value

    def fill(self, addr: int, length: int, value: int) -> None:
        for a in range(addr, addr + length):
            self.bytes[a] = value


def test_untouched_reads_default_and_costs_nothing() -> None:
    memory = SparseMemory(default=0xA5)
    assert memory.read(2**63, 4) == b"\xa5" * 4
    assert memory.read_byte(12345) == 0xA5
    assert memory.materialized_pages == 0
    assert memory.run_count == 0


def test_huge_fill_is_one_run() -> None:
    memory = SparseMemory(page_bytes=256)
    memory.fill(0, 2**32, 0x11)
    memory.fill(2**40, 2**40, 0x22)
    assert memory.materialized_pages == 0
    assert memory.run_count == 2
    assert memory.read(2**32 - 2, 4) == b"\x11\x11\x00\x00"
    assert memory.touched(0, 2**48) == [(0, 2**32), (2**40, 2**41)]


def test_write_overwrites() -> None:
    memory = SparseMemory(page_bytes=16)
    memory.write(10, b"\xff" * 10)
    memory.write(12, b"\x00\x01")
    assert memory.read(10, 5) == b"\xff\xff\x00\x01\xff"
    assert memory.materialized_pages == 2


def test_fill_with_default_clears() -> None:
    memory = SparseMemory(page_bytes=16)
    memory.write(0, b"\x01" * 64)
    memory.fill(0, 64, 0)
    assert memory.materialized_pages == 0
    assert memory.touched(0, 64) == []


def test_size_bound() -> None:
    memory = SparseMemory(size_bytes=100)
    memory.write(96, b"1234")
    with pytest.raises(SparseMemoryError):
        memory.write(97, b"1234")
    with pytest.raises(SparseMemoryError):
        memory.read(-1, 1)
    with pytest.raises(SparseMemoryError):
        SparseMemory(size_bytes=0)


def test_clear() -> None:
    memory = SparseMemory(page_bytes=16)
    memory.write(3, b"abc")
    memory.fill(100, 1000, 7)
    memory.clear()
    assert memory.read(0, 2000) == bytes(2000)
    assert memory.run_count == memory.materialized_pages == 0


@pytest.mark.parametrize("seed", range(20))
def test_random_operations_match_reference(seed: int) -> None:
    rnd = random.Random(seed)
    default = rnd.choice((0x00, 0xFF, 0x5A))
    page_bytes = rnd.choice((4, 16, 64))
    span = 1024
    memory = SparseMemory(page_bytes=page_bytes, default=default)
    reference = Reference(default)
    for _ in range(300):
        addr = rnd.randrange(span)
        length = rnd.randrange(min(200, span - addr) + 1)
        operation = rnd.random()
        if operation < 0.4:
            data = bytes(rnd.randrange(256) for _ in range(length))
            memory.write(addr, data)
            reference.write(addr, data)
        elif operation < 0.8:
            value = rnd.choice((default, rnd.randrange(256)))
            memory.fill(addr, length, value)
            reference.fill(addr, length, value)
        else:
            assert memory.read(addr, length) == reference.read(addr, length)
            assert memory.read_byte(addr) == reference.read(addr, 1)[0]
    assert memory.read(0, span) == reference.read(0, span)
    # Everything outside the touched spans reads as the default
    covered = bytearray(span)
    for start, end in memory.touched(0, span):
        covered[start:end] = b"\x01" * (end - start)
    for addr in range(span):
        if not covered[addr]:
            assert reference.read(addr, 1)[0] == default
    # The two representations never overlap
    runs = [(s, e) for s, e, _ in memory._runs]
    for page_idx in memory._pages:
        ps, pe = page_idx * page_bytes, (page_idx + 1) * page_bytes
        assert all(e <= ps or s >= pe for s, e in runs)
