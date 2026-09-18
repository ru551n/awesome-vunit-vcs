# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The simulator independent AXI4 core: bursts, sample decoding, transactions, statistics, shadow memory."""

from __future__ import annotations

import pytest
from axi4_helpers import PERIOD_FS, Recorder, header, pack

from awesome_vunit_vcs.axi4 import (
    Axi4Config,
    Axi4Monitor,
    Axi4Transaction,
    Axi4ValueError,
    BurstType,
    Channel,
    Direction,
    Response,
    SampleDecoder,
    beat_addresses,
    beat_lanes,
    crosses_4k,
)
from awesome_vunit_vcs.axi4.bus import Axi4Control, Axi4Sample, ControlKind, WriteDataPayload

INCR, FIXED, WRAP = 1, 0, 2

# -- Bursts: hand-computed from the address formulas of the AXI specification


@pytest.mark.parametrize(
    ("address", "length", "size", "burst", "expected"),
    [
        # Aligned INCR, 4 x 4 bytes
        (0x100, 3, 2, INCR, [0x100, 0x104, 0x108, 0x10C]),
        # Unaligned INCR: the first beat keeps its address, the others are aligned
        (0x1003, 2, 2, INCR, [0x1003, 0x1004, 0x1008]),
        # Narrow INCR, 2-byte beats
        (0x6, 3, 1, INCR, [0x6, 0x8, 0xA, 0xC]),
        # WRAP of 4 x 4 bytes wraps at 0x30 + 16
        (0x38, 3, 2, WRAP, [0x38, 0x3C, 0x30, 0x34]),
        # WRAP of 8 x 8 bytes from the middle of its 64-byte region
        (0x1018, 7, 3, WRAP, [0x1018, 0x1020, 0x1028, 0x1030, 0x1038, 0x1000, 0x1008, 0x1010]),
        # Narrow WRAP of 4 x 1 byte
        (0x5, 3, 0, WRAP, [0x5, 0x6, 0x7, 0x4]),
        # FIXED repeats the address
        (0x7, 2, 1, FIXED, [0x7, 0x7, 0x7]),
    ],
)
def test_beat_addresses(address: int, length: int, size: int, burst: int, expected: list[int]) -> None:
    assert beat_addresses(address, length, size, burst) == expected


@pytest.mark.parametrize(
    ("address", "length", "size", "burst", "data_bytes", "expected"),
    [
        # Aligned full width on a 32-bit bus
        (0x100, 1, 2, INCR, 4, [(0, 3), (0, 3)]),
        # Unaligned first beat: lane 3 only, then full beats
        (0x1003, 2, 2, INCR, 4, [(3, 3), (0, 3), (0, 3)]),
        # 2-byte beats on a 64-bit bus move across the lanes
        (0x6, 3, 1, INCR, 8, [(6, 7), (0, 1), (2, 3), (4, 5)]),
        # Narrow and unaligned: the first beat ends at the end of its aligned 2 bytes
        (0x3, 2, 1, INCR, 4, [(3, 3), (0, 1), (2, 3)]),
        # Narrow WRAP
        (0x5, 3, 0, WRAP, 4, [(1, 1), (2, 2), (3, 3), (0, 0)]),
        # Unaligned FIXED: every beat as the first
        (0x7, 2, 1, FIXED, 4, [(3, 3), (3, 3), (3, 3)]),
        # 4-byte beats on a 128-bit bus
        (0x18, 2, 2, INCR, 16, [(8, 11), (12, 15), (0, 3)]),
    ],
)
def test_beat_lanes(
    address: int, length: int, size: int, burst: int, data_bytes: int, expected: list[tuple[int, int]]
) -> None:
    assert beat_lanes(address, length, size, burst, data_bytes) == expected


@pytest.mark.parametrize(
    ("address", "length", "size", "burst", "crosses"),
    [
        (0xFF0, 3, 2, INCR, False),  # 0xFF0 to 0xFFF
        (0xFF0, 4, 2, INCR, True),  # to 0x1003
        (0xFFC, 0, 3, INCR, False),  # one 8-byte beat from the aligned 0xFF8
        (0xFFD, 1, 2, INCR, True),  # aligned 0xFFC + 8 bytes
        (0x1FFF, 255, 0, FIXED, False),
        (0xFF0, 3, 3, WRAP, False),
    ],
)
def test_crosses_4k(address: int, length: int, size: int, burst: int, crosses: bool) -> None:
    assert crosses_4k(address, length, size, burst) is crosses


# -- Configuration and decoding


@pytest.mark.parametrize(
    "kwargs",
    [
        {"data_width": 24},
        {"data_width": 2048},
        {"data_width": 128, "lite": True},
        {"address_width": 0},
        {"address_width": 65},
        {"id_width": 33},
        {"wuser_width": -1},
    ],
)
def test_invalid_configurations_are_rejected(kwargs: dict[str, int]) -> None:
    with pytest.raises(Axi4ValueError):
        Axi4Config(**kwargs)  # type: ignore[arg-type]


def test_payload_words_follow_the_widths() -> None:
    config = Axi4Config(data_width=1024, address_width=64, id_width=8, wuser_width=5)
    # AW: 8 + 64 + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4 = 101 bits; W: 1024 + 128 + 1 + 5 + 128 = 1286 bits
    assert config.payload_words(Channel.AW) == 4
    assert config.payload_words(Channel.W) == 41


def test_decoder_reads_hand_built_records() -> None:
    config = Axi4Config(data_width=32, address_width=32, id_width=4)
    words = [
        header(5, valid=False, ready=False, control=1),
        10_000,
        header(0, ready=False),
        *pack([(3, 4), (0x8000_1234, 32), (7, 8), (2, 3), (2, 2), (1, 1), (0b0011, 4), (5, 3), (9, 4), (6, 4)]),
        header(1, payload_x=True),
        *pack([(0xDEADBEEF, 32), (0b0101, 4), (1, 1), (0b1000, 4)]),
    ]
    times = [0, 0, 10, 10, 10, 10, 20, 20, 20]
    records = list(SampleDecoder(config).decode(words, times))
    assert records[0] == Axi4Control(ControlKind.PERIOD, 0, False, False, 10_000_000)
    aw = records[1]
    assert isinstance(aw, Axi4Sample)
    assert (aw.valid, aw.ready, aw.stall, aw.handshake, aw.time_fs) == (True, False, True, False, 10)
    assert (aw.payload.id, aw.payload.address, aw.payload.len, aw.payload.size) == (3, 0x8000_1234, 7, 2)  # type: ignore[union-attr]
    assert (aw.payload.burst, aw.payload.lock, aw.payload.cache, aw.payload.prot) == (2, 1, 3, 5)  # type: ignore[union-attr]
    assert (aw.payload.qos, aw.payload.region) == (9, 6)  # type: ignore[union-attr]
    w = records[2]
    assert isinstance(w, Axi4Sample)
    assert w.payload == WriteDataPayload(0xDEADBEEF, 0b0101, True, 0, 0b1000)
    assert w.payload_metavalue and w.handshake


def test_decoder_keeps_a_record_split_between_batches() -> None:
    recorder = Recorder(data_width=128)
    recorder.w(0x0102030405060708090A0B0C0D0E0F10)
    words, times = recorder.take()
    decoder = SampleDecoder(Axi4Config(data_width=128, id_width=4))
    assert list(decoder.decode(words[:3], times[:3])) == []
    (sample,) = decoder.decode(words[3:], times[3:])
    assert sample.payload.data == 0x0102030405060708090A0B0C0D0E0F10  # type: ignore[union-attr]


def test_decoder_rejects_an_unknown_kind() -> None:
    with pytest.raises(Axi4ValueError, match="kind 7"):
        list(SampleDecoder(Axi4Config()).decode([7], [0]))


def test_lite_forces_the_signals_axi4_lite_does_not_have() -> None:
    recorder = Recorder(data_width=64, id_width=0)
    recorder.aw(addr=0x10, len=5, size=0, burst=2, lock=1, cache=0xF, prot=3).w(1, last=False)
    words, times = recorder.take()
    aw, w = SampleDecoder(Axi4Config(data_width=64, lite=True)).decode(words, times)
    assert (aw.payload.len, aw.payload.size, aw.payload.burst, aw.payload.lock, aw.payload.cache) == (0, 3, 1, 0, 0)  # type: ignore[union-attr]
    assert aw.payload.prot == 3  # type: ignore[union-attr]
    assert w.payload.last  # type: ignore[union-attr]


# -- Transactions


def _monitor(recorder: Recorder, **kwargs: bool) -> tuple[Axi4Monitor, list[Axi4Transaction]]:
    monitor = Axi4Monitor(
        Axi4Config(data_width=recorder.data_width, address_width=recorder.address_width, id_width=recorder.id_width),
        **kwargs,
    )
    received: list[Axi4Transaction] = []
    monitor.transactions.subscribe(received.append)
    return monitor, received


def test_a_write_burst_with_backpressure() -> None:
    bus = Recorder()
    bus.period().aw(id=2, addr=0x100, len=1, ready=False).step()
    bus.aw(id=2, addr=0x100, len=1).step()
    bus.w(0x11223344, last=False).step()
    bus.w(0xAABBCCDD, strb=0b0110, ready=False).step()
    bus.w(0xAABBCCDD, strb=0b0110).step(3)
    bus.b(id=2).step()
    monitor, received = _monitor(bus)
    monitor.feed(*bus.take())
    (write,) = received
    assert write.direction == Direction.WRITE and write.id == 2 and write.address == 0x100
    assert [beat.address for beat in write.beats] == [0x100, 0x104]
    assert write.data() == bytes([0x44, 0x33, 0x22, 0x11, 0xDD, 0xCC, 0xBB, 0xAA])
    assert write.strobes() == (True, True, True, True, False, True, True, False)
    assert write.transferred_bytes() == [
        (0x100, 0x44),
        (0x101, 0x33),
        (0x102, 0x22),
        (0x103, 0x11),
        (0x105, 0xCC),
        (0x106, 0xBB),
    ]
    assert (write.address_fs, write.first_data_fs, write.last_data_fs, write.response_fs) == (
        1 * PERIOD_FS,
        2 * PERIOD_FS,
        4 * PERIOD_FS,
        7 * PERIOD_FS,
    )
    stats = monitor.statistics()
    assert stats.channels["AW"].stall_cycles == 1 and stats.channels["W"].stall_cycles == 1
    assert stats.channels["W"].handshakes == 2
    assert stats.write.bytes == 6 and stats.write.beats == 2
    assert stats.write.address_to_first_data.minimum == 1
    assert stats.write.address_to_last_data.minimum == 3
    assert stats.write.address_to_response.minimum == 6
    assert stats.write.data_to_response.minimum == 3


def test_write_data_before_its_address() -> None:
    bus = Recorder()
    bus.period().w(0x01, last=False).step().w(0x02).step().aw(id=1, addr=0x40, len=1).step().b(id=1)
    monitor, received = _monitor(bus)
    monitor.feed(*bus.take())
    (write,) = received
    assert [beat.data for beat in write.beats] == [1, 2]
    assert write.first_data_fs < write.address_fs
    assert monitor.statistics().write.address_to_first_data.minimum == -2


def test_out_of_order_responses_between_ids_and_interleaved_read_data() -> None:
    bus = Recorder()
    bus.period()
    bus.ar(id=1, addr=0x000, len=1).step()
    bus.ar(id=2, addr=0x100, len=1).step()
    bus.ar(id=1, addr=0x200, len=0).step()
    # ID 2 first, interleaved with ID 1, and the second ID 1 read after the first
    bus.r(id=2, data=0x20, last=False).step()
    bus.r(id=1, data=0x10, last=False).step()
    bus.r(id=2, data=0x21).step()
    bus.r(id=1, data=0x11).step()
    bus.r(id=1, data=0x12).step()
    monitor, received = _monitor(bus, per_id_statistics=True)
    monitor.feed(*bus.take())
    assert [(t.id, t.address) for t in received] == [(2, 0x100), (1, 0x000), (1, 0x200)]
    assert [beat.data for beat in received[0].beats] == [0x20, 0x21]
    assert [beat.data for beat in received[1].beats] == [0x10, 0x11]
    stats = monitor.statistics()
    assert stats.read.outstanding_max == 3
    assert stats.read.address_to_first_data.maximum == 5  # the third read, cycle 2 to 7
    assert stats.read_by_id[1].transactions == 2 and stats.read_by_id[2].transactions == 1
    assert stats.read_by_id[1].outstanding_max == 2


def test_narrow_wrap_read_bytes() -> None:
    bus = Recorder()
    bus.period().ar(addr=0x5, len=3, size=0, burst=WRAP).step()
    for data in (0x0000AA00, 0x00BB0000, 0xCC000000, 0x000000DD):
        bus.r(data=data, last=data == 0xDD).step()
    monitor, received = _monitor(bus)
    monitor.feed(*bus.take())
    (read,) = received
    assert read.burst == BurstType.WRAP
    assert read.transferred_bytes() == [(0x5, 0xAA), (0x6, 0xBB), (0x7, 0xCC), (0x4, 0xDD)]


def test_a_reset_drops_outstanding_transactions() -> None:
    bus = Recorder()
    bus.period().ar(id=1, addr=0).step().reset(True).step().reset(False).step().r(id=1, data=5)
    monitor, received = _monitor(bus)
    monitor.feed(*bus.take())
    assert received == []
    assert monitor.outstanding(Direction.READ) == 0


def test_statistics_of_known_traffic() -> None:
    bus = Recorder()
    bus.period()
    # Two single-beat writes, one outstanding at a time, 10 cycles apart
    for index in range(2):
        bus.aw(addr=4 * index).w(index).step(2).b(resp=2 * index).step(8)
    monitor, _ = _monitor(bus)
    monitor.feed(*bus.take())
    monitor.advance(20 * PERIOD_FS)
    stats = monitor.statistics()
    assert stats.clock_period_fs == PERIOD_FS
    assert stats.window_fs == 20 * PERIOD_FS and stats.cycles == 21
    assert stats.write.transactions == 2 and stats.write.bytes == 8
    assert stats.write.bandwidth_bps == pytest.approx(8 * 8 / 200e-9)
    assert dict(stats.write.responses) == {"OKAY": 1, "EXOKAY": 0, "SLVERR": 1, "DECERR": 0}
    assert stats.write.address_to_response.minimum == 2 and stats.write.address_to_response.maximum == 2
    assert stats.write.address_to_response.histogram == (("2-3", 2),)
    # Outstanding 1 for 2 of every 10 cycles
    assert stats.write.outstanding_max == 1
    assert stats.write.outstanding_mean == pytest.approx(4 / 20)
    assert stats.channels["AW"].utilization == pytest.approx(2 / 21)
    assert stats.write.burst_lengths == ((1, 2),) and stats.write.burst_sizes == ((4, 2),)
    summary = stats.summary("tb")
    assert "write: 2 transactions" in summary and "SLVERR=1" in summary and "p99=2" in summary


def test_percentiles_are_nearest_rank() -> None:
    bus = Recorder()
    bus.period()
    # Read latencies 1, 2, ..., 10 cycles, each read alone
    for latency in range(1, 11):
        bus.ar().step(latency).r().step()
    monitor, _ = _monitor(bus)
    monitor.feed(*bus.take())
    latency = monitor.statistics().read.address_to_last_data
    assert (latency.p50, latency.p90, latency.p99, latency.mean) == (5, 9, 10, 5.5)
    assert latency.histogram == (("1", 1), ("2-3", 2), ("4-7", 4), ("8-15", 3))


# -- Shadow memory


def _write(bus: Recorder, addr: int, data: int, strb: int = 0xF, resp: int = 0, lock: int = 0) -> None:
    bus.aw(addr=addr, lock=lock).w(data, strb=strb).step().b(resp=resp).step()


def _read(bus: Recorder, addr: int, data: int, lock: int = 0, resp: int = 0) -> None:
    bus.ar(addr=addr, lock=lock).step().r(data=data, resp=resp).step()


def test_shadow_memory_accepts_the_latest_strobed_data() -> None:
    bus = Recorder()
    bus.period()
    _write(bus, 0x10, 0x11223344)
    _write(bus, 0x10, 0xAABBCCDD, strb=0b0010)
    _read(bus, 0x10, 0x1122CC44)
    monitor, received = _monitor(bus, shadow_memory=True)
    errors: list[str] = []
    monitor.scoreboard.subscribe(lambda violation: errors.append(violation.message))
    monitor.feed(*bus.take())
    assert len(received) == 3 and errors == []


def test_shadow_memory_reports_a_mismatch() -> None:
    bus = Recorder()
    bus.period()
    _write(bus, 0x10, 0x11223344)
    _read(bus, 0x10, 0x11223355)
    monitor, _ = _monitor(bus, shadow_memory=True)
    errors: list[str] = []
    monitor.scoreboard.subscribe(lambda violation: errors.append(violation.message))
    monitor.feed(*bus.take())
    (error,) = errors
    assert error.startswith("AXI4_SCOREBOARD:") and "0x10: read 0x55, expected 0x44" in error


def test_shadow_memory_ignores_failed_writes_and_unknown_bytes() -> None:
    bus = Recorder()
    bus.period()
    _write(bus, 0x10, 0x11111111, resp=2)  # SLVERR: no effect
    _write(bus, 0x20, 0x22222222, lock=1, resp=0)  # a failed exclusive write
    _read(bus, 0x10, 0x99999999)
    _read(bus, 0x20, 0x99999999)
    monitor, _ = _monitor(bus, shadow_memory=True)
    errors: list[str] = []
    monitor.scoreboard.subscribe(lambda violation: errors.append(violation.message))
    monitor.feed(*bus.take())
    assert errors == []


def test_shadow_memory_allows_a_write_that_overlaps_a_read() -> None:
    bus = Recorder()
    bus.period()
    _write(bus, 0x10, 0x00000001)
    # The read starts, a write completes before the read data: old or new data are both right
    bus.ar(addr=0x10).step()
    bus.aw(addr=0x10).w(0x00000002).step().b().step()
    bus.r(data=0x00000002).step()
    _read(bus, 0x10, 0x00000001)  # after the write completed only the new data is right
    monitor, _ = _monitor(bus, shadow_memory=True)
    errors: list[str] = []
    monitor.scoreboard.subscribe(lambda violation: errors.append(violation.message))
    monitor.feed(*bus.take())
    assert len(errors) == 1 and "read 0x01, expected 0x02" in errors[0]


def test_transaction_describe_and_response_of_a_read() -> None:
    bus = Recorder()
    bus.period().ar(id=3, addr=0x80, len=1).step().r(id=3, resp=0, last=False).step().r(id=3, resp=3)
    monitor, received = _monitor(bus)
    monitor.feed(*bus.take())
    assert received[0].resp == Response.DECERR
    assert received[0].describe() == "read ID 3 at 0x80 (2 x 4 bytes, INCR)"
