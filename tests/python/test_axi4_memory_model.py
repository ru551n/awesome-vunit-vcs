# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The memory of the AXI4 slaves and the slave decisions, against byte-per-address references."""

from __future__ import annotations

import json
import random
from pathlib import Path

import numpy as np
import pytest

from awesome_vunit_vcs.axi4 import Axi4Slave, Endianness, MemoryModel, Permission, Response
from awesome_vunit_vcs.axi4.errors import Axi4ValueError

# -- the memory --------------------------------------------------------------


def test_vunit_messages() -> None:
    memory = MemoryModel(default_permission=Permission.NO_ACCESS)
    memory.allocate(2)
    buffer = memory.allocate(10, name="buffer_name")
    assert buffer.address == 2 and buffer.last_address == 11
    assert memory.describe_address(12) == "address 12 at unallocated location"
    assert memory.describe_address(1) == "address 1 at offset 1 within anonymous buffer at range (0 to 1)"
    assert memory.describe_address(5) == "address 5 at offset 3 within buffer 'buffer_name' at range (2 to 11)"
    memory.set_permission(5, 1, Permission.NO_ACCESS)
    _, failures = memory.read(5, 1, check_permissions=True)
    assert failures == [f"Reading from {memory.describe_address(5)} without permission (no_access)"]
    assert memory.write(5, b"\xff", check_permissions=True) == [
        f"Writing to {memory.describe_address(5)} without permission (no_access)"
    ]
    assert memory.write(5, b"\xff") == []  # the testbench ignores permissions
    assert memory.read(12, 3, check_permissions=True)[1] == [
        "Reading from address 12 at unallocated location without permission (no_access) (and 2 more bytes)"
    ]


def test_allocation_like_vunit() -> None:
    memory = MemoryModel()
    assert memory.allocate(1).address == 0
    assert memory.allocate(1, alignment=8).address == 8
    assert memory.allocate(1, alignment=16).address == 16
    assert memory.num_bytes == 17
    memory.clear()
    assert memory.allocate(1024).address == 0
    far = memory.allocate(16, address=2**40, permission=Permission.READ_ONLY)
    assert far.address == 2**40 and memory.num_bytes == 1024
    assert memory.permission(2**40 + 15) == Permission.READ_ONLY


def test_size_bound() -> None:
    memory = MemoryModel(size_bytes=1)
    assert memory.write(1, b"\xff") == ["Writing to address 1 out of range 0 to 0"]
    assert memory.read(1, 1) == (b"\x00", ["Reading from address 1 out of range 0 to 0"])
    with pytest.raises(Axi4ValueError):
        memory.allocate(2)


def test_expected_data() -> None:
    memory = MemoryModel()
    memory.allocate(3)
    memory.set_expected(0, b"\x4d")
    memory.set_expected(2, b"\x42")
    assert memory.has_expected(0) and not memory.has_expected(1) and memory.expected(2) == 66
    assert memory.check_expected_was_written(0, 3) == [
        f"The {memory.describe_address(0)} was never written with expected byte 77",
        f"The {memory.describe_address(2)} was never written with expected byte 66",
    ]
    assert memory.write(0, b"\xff") == [f"Writing to {memory.describe_address(0)}. Got 255 expected 77"]
    assert memory.read(0, 1)[0] == b"\x00"  # the testbench's mismatching write is not done
    memory.write(0, b"\x4d")
    memory.write(2, b"\x42")
    assert memory.check_expected_was_written() == []
    memory.clear_expected(0)
    assert not memory.has_expected(0)


def test_expected_check_is_sparse() -> None:
    memory = MemoryModel(page_bytes=256)
    memory.set_expected(2**60, b"\x01\x02")
    assert memory.unwritten_expected() == [(2**60, 1), (2**60 + 1, 2)]


def test_words() -> None:
    memory = MemoryModel()
    assert memory.serialize(0x11223344556677, 7) == bytes([0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
    assert memory.serialize(-256, 4) == bytes([0, 255, 255, 255])
    assert memory.serialize(-(2**31), 4) == bytes([0, 0, 0, 128])
    assert memory.serialize(0x3322, 2, Endianness.BIG) == b"\x33\x22"
    assert memory.deserialize(b"\xaa\xff", Endianness.BIG) == 0xAAFF
    assert MemoryModel(endian=Endianness.BIG).deserialize(b"\xaa\xff") == 0xAAFF


def test_huge_space_costs_nothing() -> None:
    memory = MemoryModel(default_permission=Permission.NO_ACCESS)
    memory.allocate(2**32, permission=Permission.READ_AND_WRITE)
    memory.set_permission(2**63, 2**62, Permission.READ_ONLY)
    memory.write(2**64 - 4, b"abcd")
    assert memory.read(2**64 - 4, 4) == (b"abcd", [])
    assert memory.data.materialized_pages == 1
    assert memory.data.run_count == 0


def test_load_image(tmp_path: Path) -> None:
    image = tmp_path / "image.json"
    image.write_text(
        json.dumps({"regions": [{"addr": 16, "hex": "deadbeef"}, {"addr": 2**33, "fill": 7, "length": 2**20}]})
    )
    memory = MemoryModel()
    assert memory.load_image(image, base=2**32) == 4 + 2**20
    assert memory.read(2**32 + 16, 4)[0] == bytes.fromhex("deadbeef")
    assert memory.read(2**33 + 2**32 + 2**20 - 1, 2)[0] == b"\x07\x00"
    with pytest.raises(Axi4ValueError):
        MemoryModel(size_bytes=16).load_image(image)


@pytest.mark.parametrize("seed", range(10))
def test_random_accesses_match_reference(seed: int) -> None:
    rnd = random.Random(seed)
    memory = MemoryModel(page_bytes=16, default_value=0xEE, default_permission=Permission(rnd.randrange(4)))
    data: dict[int, int] = {}
    permissions: dict[int, Permission] = {}
    expected: dict[int, int] = {}
    span = 512
    for _ in range(300):
        address = rnd.randrange(span)
        length = rnd.randrange(1, 40)
        operation = rnd.randrange(5)
        values = bytes(rnd.randrange(256) for _ in range(length))
        if operation == 0:
            permission = Permission(rnd.randrange(4))
            memory.set_permission(address, length, permission)
            permissions.update(dict.fromkeys(range(address, address + length), permission))
        elif operation == 1:
            memory.set_expected(address, values)
            expected.update(zip(range(address, address + length), values, strict=True))
        elif operation == 2:
            strobes = [rnd.random() < 0.7 for _ in range(length)]
            failures = memory.write(address, values, strobes, check_permissions=True, skip_mismatches=False)
            denied = mismatched = 0
            for offset, (value, strobe) in enumerate(zip(values, strobes, strict=True)):
                a = address + offset
                if not strobe:
                    continue
                if permissions.get(a, memory._permissions.default) in (Permission.NO_ACCESS, Permission.READ_ONLY):
                    denied += 1
                    continue
                mismatched += a in expected and expected[a] != value
                data[a] = value
            assert len(failures) == (denied > 0) + (mismatched > 0)
        else:
            read, failures = memory.read(address, length, check_permissions=True)
            denied = 0
            for offset in range(length):
                a = address + offset
                if permissions.get(a, memory._permissions.default) in (Permission.NO_ACCESS, Permission.WRITE_ONLY):
                    denied += 1
                    assert read[offset] == 0
                else:
                    assert read[offset] == data.get(a, 0xEE)
            assert len(failures) == (denied > 0)
    missing = [(a, v) for a, v in sorted(expected.items()) if data.get(a, 0xEE) != v]
    assert memory.unwritten_expected() == missing


# -- the slave decisions -----------------------------------------------------


def spec_beats(address: int, len_: int, size: int, burst: int, data_bytes: int) -> list[tuple[int, int, int]]:
    """``(address, lower lane, upper lane)`` of every beat, following the pseudocode of the AXI specification."""
    number_bytes = 1 << size
    burst_length = len_ + 1
    aligned = address // number_bytes * number_bytes
    wrap_boundary = address // (number_bytes * burst_length) * (number_bytes * burst_length)
    beats = []
    current = address
    for n in range(1, burst_length + 1):
        lower = current - current // data_bytes * data_bytes
        if n == 1 or burst == 0:
            upper = aligned + (number_bytes - 1) - current // data_bytes * data_bytes
        else:
            upper = lower + number_bytes - 1
        beats.append((current, lower, upper))
        if burst != 0:
            current = aligned + number_bytes
            if burst == 2 and current >= wrap_boundary + number_bytes * burst_length:
                current = wrap_boundary
            aligned = current // number_bytes * number_bytes
    return beats


def random_burst(rnd: random.Random, data_bytes: int) -> tuple[int, int, int, int]:
    burst = rnd.randrange(3)
    size = rnd.randrange(data_bytes.bit_length())
    if burst == 2:
        len_ = rnd.choice((1, 3, 7, 15))
        address = rnd.randrange(2**40) >> size << size
    else:
        len_ = rnd.randrange(16 if burst == 0 else 256)
        address = rnd.randrange(2**40)
    return address, len_, size, burst


@pytest.mark.parametrize("seed", range(10))
def test_read_bursts_match_the_specification(seed: int) -> None:
    rnd = random.Random(seed)
    data_bytes = rnd.choice((1, 4, 16, 128))
    memory = MemoryModel(page_bytes=64)
    slave = Axi4Slave(memory, 8 * data_bytes, is_write=False, check_4kbyte_boundary=False)
    for _ in range(20):
        address, len_, size, burst_type = random_burst(rnd, data_bytes)
        content = bytes(rnd.randrange(256) for _ in range(2 * 4096 + (len_ + 1) * data_bytes))
        memory.write(address - 4096, content)
        burst, failures = slave.accept(3, address, len_, size, burst_type)
        assert failures == []
        result = slave.read(burst)
        assert list(result.resps) == [Response.OKAY] * (len_ + 1)
        for beat, (beat_address, lower, upper) in enumerate(spec_beats(address, len_, size, burst_type, data_bytes)):
            base = beat_address // data_bytes * data_bytes
            for lane in range(data_bytes):
                expected = content[base + lane - (address - 4096)] if lower <= lane <= upper else -1
                assert result.data[beat][lane] == expected


@pytest.mark.parametrize("seed", range(10))
def test_write_bursts_match_the_specification(seed: int) -> None:
    rnd = random.Random(seed)
    data_bytes = rnd.choice((1, 4, 16, 128))
    memory = MemoryModel(page_bytes=64)
    reference: dict[int, int] = {}
    slave = Axi4Slave(memory, 8 * data_bytes, is_write=True, check_4kbyte_boundary=False)
    for _ in range(20):
        address, len_, size, burst_type = random_burst(rnd, data_bytes)
        burst, _ = slave.accept(0, address, len_, size, burst_type)
        data = np.array([[rnd.randrange(256) for _ in range(data_bytes)] for _ in range(len_ + 1)])
        strobes = np.zeros(data.shape, dtype=np.bool_)
        for beat, (beat_address, lower, upper) in enumerate(spec_beats(address, len_, size, burst_type, data_bytes)):
            base = beat_address // data_bytes * data_bytes
            for lane in range(lower, upper + 1):
                strobes[beat][lane] = rnd.random() < 0.8
                if strobes[beat][lane]:
                    reference[base + lane] = int(data[beat][lane])
        assert slave.write(burst, data, strobes) == (Response.OKAY, [])
    for address, value in reference.items():
        assert memory.read(address, 1)[0][0] == value


def test_slave_failures_and_responses() -> None:
    memory = MemoryModel(default_permission=Permission.NO_ACCESS)
    memory.allocate(4096 + 32, alignment=4096)
    slave = Axi4Slave(memory, 128, is_write=False)
    burst, failures = slave.accept(2, 4000, 255, 0, 1)
    assert failures == ["Crossing 4KByte boundary. First page = 0 (4000/4096), last page = 1 (4255/4096)"]
    assert burst.supported
    slave.check_4kbyte_boundary = False
    assert slave.accept(2, 4000, 255, 0, 1)[1] == []
    burst, failures = slave.accept(2, 0, 0, 0, 3)
    assert failures == ["Unsupported burst type 0b11 (reserved) of read burst #2 for id 2"]
    assert list(slave.read(burst).resps) == [Response.SLVERR]
    assert slave.accept(0, 2, 1, 2, 2)[1] == ["Unsupported wrapping read burst #0 for id 0: 2 beats of 4 bytes from 2"]
    assert slave.accept(0, 0, 0, 5, 1)[1] == [
        "The 32 byte beats of read burst #1 for id 0 are wider than the 16 byte bus"
    ]
    assert slave.burst_lengths == {256: 2, 1: 2, 2: 1}
    # A beat reading a byte without permission reads 0 there and responds SLVERR
    memory.write(4096 + 32, b"\x55" * 16)
    burst, _ = slave.accept(0, 4096 + 16, 1, 4, 1)
    result = slave.read(burst)
    assert list(result.resps) == [Response.OKAY, Response.SLVERR]
    assert list(result.data[1]) == [0] * 16
    assert result.failures == [
        "Reading from address 4128 at unallocated location without permission (no_access) (and 15 more bytes)"
    ]
    # A write of a strobed byte without permission responds SLVERR; the others are written
    writer = Axi4Slave(memory, 128, is_write=True)
    burst, _ = writer.accept(0, 4096 + 16, 1, 4, 1)
    resp, failures = writer.write(burst, np.full((2, 16), 9), np.ones((2, 16), dtype=np.bool_))
    assert resp == Response.SLVERR and len(failures) == 1
    assert memory.read(4096 + 16, 16)[0] == b"\x09" * 16
