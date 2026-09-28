"""The simulator independent I2C core: timing tables, PEC, bus decoding and transfers."""

from __future__ import annotations

import random

import pytest
from i2c_helpers import NS, US, Bus, reference_pec

from awesome_vunit_vcs.errors import AwesomeVunitVcsError
from awesome_vunit_vcs.i2c import (
    AddressKind,
    I2cMonitor,
    I2cTransfer,
    I2cValueError,
    SpeedMode,
    bus_limits,
    master_timing,
    smbus_pec,
)
from awesome_vunit_vcs.i2c.bus import BusDecoder, EventKind


def _transfers(bus: Bus) -> list[I2cTransfer]:
    monitor = I2cMonitor()
    transfers: list[I2cTransfer] = []
    monitor.transfers.subscribe(transfers.append)
    monitor.feed(bus.words, bus.times)
    return transfers


# Timing tables
@pytest.mark.parametrize(
    ("mode", "expected"),
    [
        # UM10204, characteristics of the SDA and SCL bus lines: fSCL, tHD;STA, tLOW, tHIGH, tSU;STA,
        # tHD;DAT, tSU;DAT, tSU;STO, tBUF
        ("standard", (100_000, 4000, 4700, 4000, 4700, 0, 250, 4000, 4700)),
        ("fast", (400_000, 600, 1300, 600, 600, 0, 100, 600, 1300)),
        ("fast_plus", (1_000_000, 260, 500, 260, 260, 0, 50, 260, 500)),
    ],
)
def test_bus_limits_are_the_specification_minimums(mode: str, expected: tuple[int, ...]) -> None:
    limits = bus_limits(mode)
    times_ns = (
        limits.t_hd_sta_fs,
        limits.t_low_fs,
        limits.t_high_fs,
        limits.t_su_sta_fs,
        limits.t_hd_dat_fs,
        limits.t_su_dat_fs,
        limits.t_su_sto_fs,
        limits.t_buf_fs,
    )
    assert (limits.f_scl_max_hz, *(time // NS for time in times_ns)) == expected


@pytest.mark.parametrize("mode", list(SpeedMode))
def test_master_timing_meets_the_limits_of_its_mode(mode: SpeedMode) -> None:
    timing = master_timing(mode)
    limits = bus_limits(mode)
    assert timing.t_low_fs + timing.t_high_fs >= 10**15 // limits.f_scl_max_hz
    assert timing.t_low_fs >= limits.t_low_fs and timing.t_high_fs >= limits.t_high_fs
    assert timing.t_low_fs - timing.t_hd_dat_fs >= limits.t_su_dat_fs
    assert timing.t_su_sta_fs >= limits.t_su_sta_fs and timing.t_hd_sta_fs >= limits.t_hd_sta_fs
    assert timing.t_su_sto_fs >= limits.t_su_sto_fs and timing.t_buf_fs >= limits.t_buf_fs


def test_timing_overrides_and_errors() -> None:
    assert bus_limits(SpeedMode.FAST, t_low_fs=2 * US, t_high_fs=0).t_low_fs == 2 * US
    assert bus_limits(SpeedMode.FAST, t_high_fs=0).t_high_fs == 600 * NS
    assert master_timing(2, t_hd_dat_fs=None).t_hd_dat_fs == 100 * NS
    assert bus_limits(SpeedMode.FAST).t_period_min_fs == 2500 * NS
    with pytest.raises(I2cValueError):
        bus_limits("warp")
    with pytest.raises(I2cValueError):
        bus_limits(t_lol_fs=1)
    with pytest.raises(I2cValueError):
        master_timing(t_hd_dat_fs=10 * US)
    with pytest.raises(AwesomeVunitVcsError):
        master_timing(t_low_fs=-1)


# PEC
def test_pec_matches_the_bitwise_reference() -> None:
    generator = random.Random(1)
    for _ in range(200):
        data = bytes(generator.randrange(256) for _ in range(generator.randrange(20)))
        assert smbus_pec(data) == reference_pec(data)
    # The CRC-8/SMBUS check value
    assert smbus_pec(b"123456789") == 0xF4
    data = bytes([0xA0, 0x10, 0x55])
    assert smbus_pec(data + bytes([reference_pec(data)])) == 0


# Bus events
def test_decoder_finds_start_stop_and_bits() -> None:
    decoder = BusDecoder()
    kinds = [
        event.kind
        for word, time in [(1, 10), (0, 20), (2, 30), (3, 40), (1, 50), (3, 60)]
        for event in decoder.decode(word, time)
    ]
    assert kinds == [EventKind.START, EventKind.FALL, EventKind.DATA, EventKind.RISE, EventKind.START, EventKind.STOP]


def test_simultaneous_changes_belong_to_the_low_phase() -> None:
    decoder = BusDecoder()
    # SCL falls and SDA falls in one sample: no START
    assert [event.kind for event in decoder.decode(0, 10)] == [EventKind.FALL, EventKind.DATA]
    # SCL rises and SDA rises in one sample: the bit is 1, no STOP
    events = decoder.decode(3, 20)
    assert [event.kind for event in events] == [EventKind.DATA, EventKind.RISE]
    assert events[1].sda == 1


def test_a_metavalue_keeps_the_last_level() -> None:
    decoder = BusDecoder()
    events = decoder.decode(1 | 8, 10)
    assert [(event.kind, event.sda) for event in events] == [(EventKind.METAVALUE, 1)]
    assert decoder.sda == 1


# Transfers
def test_a_write_with_every_byte_acknowledged() -> None:
    [transfer] = _transfers(Bus().write(0x50, b"\x12\x34"))
    assert (transfer.address, transfer.read, transfer.data, transfer.acks) == (0x50, False, b"\x12\x34", (True, True))
    assert transfer.address_ack and transfer.stopped and not transfer.repeated_start
    assert transfer.kind is AddressKind.SEVEN_BIT and transfer.nack_index is None


def test_a_write_then_read_with_a_repeated_start() -> None:
    bus = Bus().start().byte(0xA0).byte(0x07).start().byte(0xA1).byte(0x5A).byte(0xC3, ack=False).stop()
    first, second = _transfers(bus)
    assert (first.address, first.read, first.data, first.stopped) == (0x50, False, b"\x07", False)
    assert (second.address, second.read, second.data, second.acks) == (0x50, True, b"\x5a\xc3", (True, False))
    assert second.repeated_start and second.stopped and second.nack_index == 1


def test_an_address_not_acknowledged() -> None:
    [transfer] = _transfers(Bus().start().byte(0x90, ack=False).stop())
    assert transfer.address == 0x48 and not transfer.address_ack and transfer.data == b""


def test_ten_bit_addresses_also_after_a_repeated_start() -> None:
    # Write to 0x2A5: 11110 10 0, 0xA5; then Sr and 11110 10 1 reads from the same target
    bus = Bus().start().byte(0xF4).byte(0xA5).byte(0x11).start().byte(0xF5).byte(0x22, ack=False).stop()
    write, read = _transfers(bus)
    assert (write.address, write.ten_bit, write.data) == (0x2A5, True, b"\x11")
    assert (read.address, read.ten_bit, read.read, read.data) == (0x2A5, True, True, b"\x22")


@pytest.mark.parametrize(
    ("first_byte", "kind"),
    [
        (0x00, AddressKind.GENERAL_CALL),
        (0x01, AddressKind.START_BYTE),
        (0x02, AddressKind.CBUS),
        (0x05, AddressKind.RESERVED),
        (0x06, AddressKind.RESERVED),
        (0x0A, AddressKind.HS_MODE),
        (0xF9, AddressKind.DEVICE_ID),
        (0x10, AddressKind.SEVEN_BIT),
    ],
)
def test_reserved_addresses(first_byte: int, kind: AddressKind) -> None:
    [transfer] = _transfers(Bus().start().byte(first_byte).byte(0x06).stop())
    assert transfer.kind is kind and transfer.address == first_byte >> 1


def test_a_stop_inside_a_byte_leaves_partial_bits() -> None:
    bus = Bus().start().byte(0xA0)
    for bit in (1, 0, 1):
        bus.bit(bit)
    [transfer] = _transfers(bus.stop())
    assert transfer.partial_bits == 3 and transfer.data == b""


def test_statistics() -> None:
    bus = Bus().write(0x50, b"\x01\x02").write(0x51, b"", acks=[False])
    # A target stretches the clock by 10 us before the acknowledge bit of the address
    bus.start()
    for bit in (1, 0, 1, 0, 0, 0, 0, 0):
        bus.bit(bit)
    bus.wait(10 * US).bit(0).stop()
    monitor = I2cMonitor()
    monitor.feed(bus.words, bus.times)
    stats = monitor.statistics()
    assert (stats.transactions, stats.transfers, stats.writes, stats.reads) == (3, 3, 3, 0)
    assert (stats.data_bytes, stats.nacks, stats.address_nacks) == (2, 1, 1)
    assert stats.scl_frequency_hz == 400_000
    assert stats.stretch_fs == 10 * US
    assert 0 < stats.utilization < 1 and stats.observed_fs == bus.times[-1]
