# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Protocol-level tests: the state machine as the VC sees it.

Everything here goes through `Host`, which follows the directives the model
returns rather than assuming the shape of the command -- so these tests
cover the directive stream (lane widths, dummy-cycle prefixes, when the
device stops talking) as much as they cover the resulting bytes."""

from __future__ import annotations

import pytest
from flash_harness import Host, frame

from awesome_vunit_vcs.flash.config import FlashConfig
from awesome_vunit_vcs.flash.device import ContentMismatch, FlashDevice
from awesome_vunit_vcs.flash.directive import Action

KIB = 1024
MIB = 1024 * 1024

# Simulation time in femtoseconds
NS = 10**6
US = 10**9
MS = 10**12
SEC = 10**15

# 0xA0 has M5:M4 == 0b10: stay in continuous read. 0x00 leaves it.
XIP_ON = 0xA0
XIP_OFF = 0x00


def make(**config) -> Host:
    return Host(FlashDevice(FlashConfig(**config)))


@pytest.fixture
def host() -> Host:
    return make()


@pytest.fixture
def fast() -> Host:
    """A device with busy times collapsed, for the majority of tests that
    care about protocol rather than milliseconds."""
    host = make()
    host.dev.set_timing_enable(False)
    return host


# -- identification --------------------------------------------------------------


def test_rdid_returns_the_three_jedec_bytes_and_then_repeats(host: Host) -> None:
    assert host.command(0x9F, read=7).out == [0xEF, 0x40, 0x18] * 2 + [0xEF]


def test_rdid_honours_a_jedec_id_override() -> None:
    host = make(jedec_id=0x20BA19)
    assert host.command(0x9F, read=3).out == [0x20, 0xBA, 0x19]


def test_rdsfdp_signature_over_the_wire(host: Host) -> None:
    result = host.command(0x5A, addr=0x000000, addr_bytes=3, read=4)
    assert bytes(result.out) == b"SFDP"
    assert host.first_transmit(result).pre_dummy_cycles == 8


def test_rdsfdp_keeps_three_address_bytes_in_four_byte_mode(host: Host) -> None:
    host.command(0xB7)  # EN4B
    assert host.dev.mode.addr_bytes == 4
    assert bytes(host.command(0x5A, addr=0, addr_bytes=3, read=4).out) == b"SFDP"


def test_unknown_opcode_is_silently_ignored(host: Host) -> None:
    result = host.command(0x77, read=4)
    assert result.directives[1].action is Action.IGNORE_REST
    assert result.out == []
    assert host.dev.get_stat("unknown_opcode_count") == 1
    assert host.dev.get_stat("ignored_command_count") == 1


# -- reads ------------------------------------------------------------------------


def test_erased_device_reads_all_ones(host: Host) -> None:
    assert host.read_array(0x1234, 4) == [0xFF] * 4


def test_read_increments_and_wraps_at_the_end_of_the_array(host: Host) -> None:
    host.dev.preload(0, b"\x01\x02")
    host.dev.preload(host.dev.size_bytes - 2, b"\x03\x04")
    assert host.read_array(host.dev.size_bytes - 2, 4) == [0x03, 0x04, 0x01, 0x02]


@pytest.mark.parametrize(
    ("opcode", "lanes", "dummy"),
    [
        (0x03, 1, 0),
        (0x0B, 1, 8),
        (0x3B, 2, 8),
        (0x6B, 4, 8),
        (0xBB, 2, 0),
        (0xEB, 4, 4),
    ],
)
def test_read_family_lane_widths_and_dummy_prefix(host: Host, opcode: int, lanes: int, dummy: int) -> None:
    host.dev.preload(0x40, b"\xa5\x5a")
    kwargs = {"mode_byte": XIP_OFF} if opcode in (0xBB, 0xEB) else {}
    result = host.command(opcode, addr=0x40, read=2, **kwargs)
    assert result.out == [0xA5, 0x5A]
    first = host.first_transmit(result)
    assert (first.lanes, first.pre_dummy_cycles) == (lanes, dummy)
    # The dummy cycles are a prefix on the first data byte only.
    later = [d for d in result.directives if d.action is Action.TRANSMIT][1:]
    assert all(d.pre_dummy_cycles == 0 for d in later)


def test_io_reads_take_their_address_on_the_wide_lanes(host: Host) -> None:
    result = host.command(0xEB, addr=0x40, mode_byte=XIP_OFF, read=1)
    address_directives = result.directives[1:4]
    assert all(d.action is Action.RECEIVE and d.lanes == 4 for d in address_directives)


# -- programming ------------------------------------------------------------------


def program(host: Host, addr: int, data: bytes, opcode: int = 0x02, **kwargs):
    host.wren()
    return host.command(opcode, addr=addr, data=list(data), **kwargs)


def test_program_needs_write_enable(host: Host) -> None:
    result = host.command(0x02, addr=0x100, data=[0x00])
    assert result.directives[1].action is Action.IGNORE_REST
    assert host.dev.read_back(0x100, 1) == b"\xff"
    assert host.dev.get_stat("wel_reject_count") == 1
    assert result.busy == 0


def test_program_is_and_only(fast: Host) -> None:
    program(fast, 0x100, b"\xa5")
    assert fast.dev.read_back(0x100, 1) == b"\xa5"
    program(fast, 0x100, b"\x0f")
    assert fast.dev.read_back(0x100, 1) == b"\x05"  # 0xA5 & 0x0F
    program(fast, 0x100, b"\xff")
    assert fast.dev.read_back(0x100, 1) == b"\x05"  # cannot set bits back


def test_wel_is_cleared_by_a_completed_program(fast: Host) -> None:
    fast.wren()
    assert fast.dev.get_stat("wel") == 1
    fast.command(0x02, addr=0, data=[0x00])
    assert fast.dev.get_stat("wel") == 0


def test_wrdi_clears_write_enable(host: Host) -> None:
    host.wren()
    host.command(0x04)
    assert host.dev.get_stat("wel") == 0


def test_page_program_wraps_to_the_start_of_the_same_page(fast: Host) -> None:
    data = bytes(range(0x20))
    program(fast, 0x00F0, data)
    # The first 16 bytes land at the end of page 0...
    assert fast.dev.read_back(0x00F0, 0x10) == data[:0x10]
    # ... and the rest wraps to the START of page 0, not into page 1.
    assert fast.dev.read_back(0x0000, 0x10) == data[0x10:]
    assert fast.dev.read_back(0x0100, 0x10) == b"\xff" * 0x10


def test_more_than_a_page_overwrites_the_latch_not_the_next_page(fast: Host) -> None:
    data = bytes((i * 7) & 0xFF for i in range(300))
    program(fast, 0x0000, data)
    # The last 44 bytes rewrote latch offsets 0..43 before anything was
    # programmed, so those offsets hold the LATER value, not the earlier.
    assert fast.dev.read_back(0x0000, 44) == data[256:]
    assert fast.dev.read_back(44, 256 - 44) == data[44:256]
    assert fast.dev.read_back(0x0100, 4) == b"\xff" * 4


def test_program_across_the_page_boundary_wraps(fast: Host) -> None:
    program(fast, 0x01FE, b"\x01\x02\x03\x04")
    assert fast.dev.read_back(0x01FE, 2) == b"\x01\x02"
    assert fast.dev.read_back(0x0100, 2) == b"\x03\x04"
    assert fast.dev.read_back(0x0200, 2) == b"\xff\xff"


def test_quad_page_program_uses_four_data_lanes(fast: Host) -> None:
    fast.wren()
    result = fast.command(0x32, addr=0x200, data=[0xAA, 0xBB])
    data_directives = [d for d in result.directives if d.action is Action.RECEIVE]
    assert data_directives[-1].lanes == 4
    assert fast.dev.read_back(0x200, 2) == b"\xaa\xbb"


def test_program_with_no_data_does_nothing_but_still_consumes_wel(fast: Host) -> None:
    fast.wren()
    result = fast.command(0x02, addr=0x300)
    assert result.busy == 0
    assert fast.dev.get_stat("wel") == 0
    assert fast.dev.read_back(0x300, 1) == b"\xff"


# -- erase -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("opcode", "size", "busy_key"),
    [(0x20, 4 * KIB, "tSE"), (0x52, 32 * KIB, "tBE32"), (0xD8, 64 * KIB, "tBE64")],
)
def test_erase_granularity(opcode: int, size: int, busy_key: str) -> None:
    host = make()
    host.dev.preload_fill(0, 1 * MIB, 0x00)
    addr = 3 * size + 0x123  # deliberately not aligned
    base = addr & ~(size - 1)
    host.wren()
    result = host.command(opcode, addr=addr)
    assert result.busy == host.dev.timing.busy_fs(busy_key)
    host.dev.check_content_fill(base, size, 0xFF)
    assert host.dev.read_back(base - 1, 1) == b"\x00"
    assert host.dev.read_back(base + size, 1) == b"\x00"
    assert host.dev.written_regions() == [(base, size)]


@pytest.mark.parametrize(
    ("opcode", "size", "addr_bytes"),
    [(0x20, 8 * KIB, 3), (0x52, 16 * KIB, 3), (0xD8, 128 * KIB, 3), (0xDC, 128 * KIB, 4)],
)
def test_erase_sizes_follow_the_configuration(opcode: int, size: int, addr_bytes: int) -> None:
    host = make(sector_bytes=8 * KIB, block32_bytes=16 * KIB, block_bytes=128 * KIB)
    host.dev.set_timing_enable(False)
    host.dev.preload_fill(0, 1 * MIB, 0x00)
    addr = 3 * size + 0x123
    base = addr & ~(size - 1)
    host.wren()
    host.command(opcode, addr=addr, addr_bytes=addr_bytes)
    host.dev.check_content_fill(base, size, 0xFF)
    assert host.dev.read_back(base - 1, 1) == b"\x00"
    assert host.dev.read_back(base + size, 1) == b"\x00"
    assert host.dev.written_regions() == [(base, size)]
    assert host.dev.get_stat("bytes_erased") == size


def test_block32_erase_is_an_unknown_opcode_without_32kib_blocks() -> None:
    host = make(block32_bytes=0)
    host.dev.set_timing_enable(False)
    host.dev.preload_fill(0, 32 * KIB, 0x00)
    host.wren()
    result = host.command(0x52, addr=0)
    assert result.directives[1].action is Action.IGNORE_REST
    host.dev.check_content_fill(0, 32 * KIB, 0x00)
    assert host.dev.get_stat("unknown_opcode_count") == 1
    assert host.dev.get_stat("wel") == 1, "an unknown opcode does not consume WEL"


@pytest.mark.parametrize("opcode", [0xC7, 0x60])
def test_chip_erase(opcode: int) -> None:
    host = make()
    host.dev.preload_fill(0, host.dev.size_bytes, 0x00)
    host.wren()
    result = host.command(opcode)
    assert result.busy == host.dev.timing.busy_fs("tCE")
    host.dev.check_content_fill(0, 4, 0xFF)
    host.dev.check_content_fill(host.dev.size_bytes - 4, 4, 0xFF)
    assert host.dev.written_regions() == [(0, host.dev.size_bytes)]
    # A whole-device erase must not have materialized the whole device.
    assert host.dev.get_stat("materialized_pages") == 0


def test_erase_needs_write_enable(fast: Host) -> None:
    fast.dev.preload_fill(0, 4 * KIB, 0x00)
    fast.command(0x20, addr=0)
    assert fast.dev.read_back(0, 1) == b"\x00"
    assert fast.dev.get_stat("wel_reject_count") == 1


def test_erase_with_a_truncated_address_does_nothing(fast: Host) -> None:
    fast.dev.preload_fill(0, 4 * KIB, 0x00)
    fast.wren()
    # Only two of the three address bytes are clocked before CS rises.
    fast.xact(frame(0x20, addr=0x1234, addr_bytes=2))
    assert fast.dev.read_back(0, 1) == b"\x00"
    assert fast.dev.get_stat("abort_count") == 1


def test_erase_at_the_top_of_the_device_is_clamped(fast: Host) -> None:
    top = fast.dev.size_bytes - 4 * KIB
    fast.dev.preload_fill(top, 4 * KIB, 0x00)
    fast.wren()
    fast.command(0x20, addr=fast.dev.size_bytes - 1)
    fast.dev.check_content_fill(top, 4 * KIB, 0xFF)


# -- protection ---------------------------------------------------------------------


def test_explicit_lock_silently_rejects_a_program(fast: Host) -> None:
    fast.dev.set_protection(0x1000, 0x1000, True)
    fast.wren()
    result = fast.command(0x02, addr=0x1000, data=[0x00])
    # No exception, no error on the wire, no busy time: just nothing.
    assert result.busy == 0
    assert not result.ignored, "the command is accepted, then does nothing"
    assert fast.dev.read_back(0x1000, 1) == b"\xff"
    assert fast.dev.get_stat("protect_reject_count") == 1
    assert fast.dev.written_regions() == []


def test_explicit_lock_silently_rejects_an_erase(fast: Host) -> None:
    fast.dev.preload_fill(0x1000, 0x1000, 0x00)
    fast.dev.set_protection(0x1800, 16, True)  # only part of the sector
    fast.wren()
    fast.command(0x20, addr=0x1000)
    fast.dev.check_content_fill(0x1000, 0x1000, 0x00)
    assert fast.dev.get_stat("protect_reject_count") == 1


def test_a_program_straddling_the_lock_boundary_is_rejected_entirely(fast: Host) -> None:
    """Any overlap kills the whole instruction: the unprotected half of a
    straddling write is not programmed either."""
    fast.dev.set_protection(0x1FF8, 8, True)
    fast.wren()
    fast.command(0x02, addr=0x1FF0, data=[0x00] * 0x10)
    assert fast.dev.read_back(0x1FF0, 0x10) == b"\xff" * 0x10
    assert fast.dev.get_stat("protect_reject_count") == 1
    # Keeping entirely clear of the lock programs normally.
    fast.wren()
    fast.command(0x02, addr=0x1FF0, data=[0x00] * 8)
    assert fast.dev.read_back(0x1FF0, 8) == b"\x00" * 8


def test_unlocking_restores_programmability(fast: Host) -> None:
    fast.dev.set_protection(0x1000, 0x1000, True)
    fast.wren()
    fast.command(0x02, addr=0x1000, data=[0x00])
    fast.dev.set_protection(0x1000, 0x1000, False)
    fast.wren()
    fast.command(0x02, addr=0x1000, data=[0x00])
    assert fast.dev.read_back(0x1000, 1) == b"\x00"


def test_status_register_block_protect_takes_effect(fast: Host) -> None:
    fast.wren()
    # BP0 = 1, TB = 1: the bottom 64 KiB.
    fast.command(0x01, data=[0b0010_0100])
    assert fast.status(0)[0] & 0xFC == 0b0010_0100
    fast.wren()
    fast.command(0x02, addr=0x0000, data=[0x00])
    assert fast.dev.read_back(0x0000, 1) == b"\xff"
    fast.wren()
    fast.command(0x02, addr=0x1_0000, data=[0x00])
    assert fast.dev.read_back(0x1_0000, 1) == b"\x00"


# -- status registers ----------------------------------------------------------------


def test_status_registers_read_back(fast: Host) -> None:
    assert fast.status(0) == [0x00]
    assert fast.status(1) == [0x02]  # QE set by the default configuration
    assert fast.status(2) == [0x00]


def test_status_read_repeats_the_same_byte(fast: Host) -> None:
    fast.wren()
    assert fast.status(0, count=3) == [0x02, 0x02, 0x02]


def test_wrsr_cannot_write_wip_or_wel(fast: Host) -> None:
    fast.wren()
    fast.command(0x01, data=[0xFF])
    assert fast.status(0)[0] & 0x03 == 0x00


def test_wrsr_writes_all_three_registers(fast: Host) -> None:
    fast.wren()
    fast.command(0x01, data=[0x00, 0x00, 0x04])
    assert fast.status(1) == [0x00]  # QE cleared
    assert fast.status(2)[0] & 0x04 == 0x04  # WPS set


def test_wrsr_with_two_bytes_writes_sr1_and_sr2(fast: Host) -> None:
    fast.wren()
    fast.command(0x01, data=[0b0000_0100, 0x40])
    assert fast.status(0) == [0b0000_0100]
    assert fast.status(1) == [0x40]  # CMP set, QE cleared
    assert fast.status(2) == [0x00]


def test_wrsr2_writes_the_qe_bit(host: Host) -> None:
    host.at(SEC).wren()
    result = host.at(SEC).command(0x31, data=[0x00])
    assert result.busy == host.dev.timing.busy_fs("tW")
    assert host.at(SEC).status(0) == [0x01], "busy for tW, and WEL is cleared"
    host.at(2 * SEC)
    assert host.status(1) == [0x00]
    assert host.dev.get_stat("qe") == 0
    assert host.command(0x6B, addr=0, read=1).out == []
    assert host.dev.get_stat("qe_reject_count") == 1
    host.wren()
    host.command(0x31, data=[0xFF, 0x00])  # a second byte is ignored
    assert host.at(3 * SEC).status(1) == [0x43]  # only CMP, QE and SRL are writable
    assert host.status(0) == [0x00]
    assert host.command(0x6B, addr=0, read=1).out == [0xFF]
    assert host.dev.get_stat("wrsr_count") == 2


def test_wrsr3_writes_only_sr3(fast: Host) -> None:
    fast.wren()
    fast.command(0x11, data=[0xFF])
    assert fast.status(2) == [0xE4]  # ADS follows the addressing mode, not the write
    assert fast.status(1) == [0x02]
    assert fast.status(0) == [0x00]
    assert fast.dev.get_stat("wel") == 0


@pytest.mark.parametrize("opcode", [0x31, 0x11])
def test_wrsr2_and_wrsr3_need_write_enable(fast: Host, opcode: int) -> None:
    fast.command(opcode, data=[0x00])
    assert fast.status(1) == [0x02]
    assert fast.dev.get_stat("wel_reject_count") == 1


def test_wrsr_needs_write_enable(fast: Host) -> None:
    fast.command(0x01, data=[0xFC])
    assert fast.status(0) == [0x00]
    assert fast.dev.get_stat("wel_reject_count") == 1


# -- trailing partial byte -------------------------------------------------------------


def test_trailing_bits_abort_a_page_program(fast: Host) -> None:
    fast.wren()
    result = fast.command(0x02, addr=0x400, data=[0xAA, 0xBB], trailing_bits=3)
    assert result.busy == 0
    assert fast.dev.read_back(0x400, 2) == b"\xff\xff"
    assert fast.dev.get_stat("abort_count") == 1
    # The instruction was never executed, so it never consumed WEL either.
    assert fast.dev.get_stat("wel") == 1


def test_trailing_bits_abort_a_write_status(fast: Host) -> None:
    fast.wren()
    fast.command(0x01, data=[0xFC], trailing_bits=1)
    assert fast.status(0) == [0x02]  # WEL still set, BP bits untouched
    assert fast.dev.get_stat("abort_count") == 1


def test_trailing_bits_do_not_abort_an_erase(fast: Host) -> None:
    """The rule is about the *data* phase. An erase has none, so a partial
    trailing byte after a complete address still erases."""
    fast.dev.preload_fill(0, 4 * KIB, 0x00)
    fast.wren()
    fast.command(0x20, addr=0, trailing_bits=4)
    fast.dev.check_content_fill(0, 4 * KIB, 0xFF)


# -- addressing ------------------------------------------------------------------------


def test_three_byte_addressing_by_default(host: Host) -> None:
    assert host.dev.get_stat("addr_bytes") == 3
    host.dev.preload(0x123456, b"\x5a")
    assert host.read_array(0x123456, 1) == [0x5A]


def test_en4b_switches_every_current_mode_command(fast: Host) -> None:
    fast.dev.preload(0x00234567, b"\x5a")
    fast.command(0xB7)
    assert fast.dev.get_stat("addr_bytes") == 4
    assert fast.status(2)[0] & 0x01 == 0x01, "SR3 ADS must report 4-byte mode"
    assert fast.read_array(0x00234567, 1) == [0x5A]
    fast.command(0xE9)
    assert fast.dev.get_stat("addr_bytes") == 3
    assert fast.status(2)[0] & 0x01 == 0x00


def test_four_byte_opcodes_ignore_the_mode(fast: Host) -> None:
    fast.dev.preload(0x00FEDCBA, b"\x77")
    assert fast.dev.get_stat("addr_bytes") == 3
    assert fast.command(0x13, addr=0x00FEDCBA, addr_bytes=4, read=1).out == [0x77]
    assert fast.command(0x0C, addr=0x00FEDCBA, addr_bytes=4, read=1).out == [0x77]


def test_a_four_byte_opcode_given_three_address_bytes_stalls(fast: Host) -> None:
    result = fast.command(0x13, addr=0x123456, addr_bytes=3, read=2)
    # The device is still waiting for the fourth address byte, so it never
    # reaches its data phase and drives nothing.
    assert result.out == []
    assert result.directives[-1].action is Action.RECEIVE


def test_four_byte_page_program_and_erase() -> None:
    """A 32 MiB part, at an address no 3-byte command can reach."""
    host = make(size_bytes=32 * MIB, jedec_id=0x20BA19)
    host.dev.set_timing_enable(False)
    assert host.dev.get_stat("addr_bytes") == 3, "and still in 3-byte mode"
    host.wren()
    host.command(0x12, addr=0x0100_0000, addr_bytes=4, data=[0x00])
    assert host.dev.read_back(0x0100_0000, 1) == b"\x00"
    assert host.command(0x13, addr=0x0100_0000, addr_bytes=4, read=1).out == [0x00]
    host.wren()
    host.command(0xDC, addr=0x0100_0000, addr_bytes=4)
    assert host.dev.read_back(0x0100_0000, 1) == b"\xff"
    assert host.dev.written_regions()[-1] == (0x0100_0000, 64 * KIB)


@pytest.mark.parametrize(
    ("opcode", "kwargs"),
    [
        (0xB7, {}),
        (0xE9, {}),
        (0x13, {"addr": 0, "addr_bytes": 4, "read": 1}),
        (0x0C, {"addr": 0, "addr_bytes": 4, "read": 1}),
        (0x12, {"addr": 0, "addr_bytes": 4, "data": [0x00]}),
        (0xDC, {"addr": 0, "addr_bytes": 4}),
    ],
)
def test_a_three_byte_only_device_ignores_four_byte_commands(opcode: int, kwargs: dict[str, object]) -> None:
    host = make(addr_modes=3)
    host.dev.set_timing_enable(False)
    host.dev.preload_fill(0, 64 * KIB, 0x00)
    host.wren()
    result = host.command(opcode, **kwargs)
    assert result.directives[1].action is Action.IGNORE_REST
    assert result.out == []
    assert host.dev.get_stat("unknown_opcode_count") == 1
    assert host.dev.get_stat("addr_bytes") == 3
    host.dev.check_content_fill(0, 64 * KIB, 0x00)


def test_a_four_byte_only_device_stays_in_four_byte_mode() -> None:
    host = make(size_bytes=32 * MIB, addr_bytes=4, addr_modes=4)
    host.dev.set_timing_enable(False)
    assert host.command(0xE9).directives[1].action is Action.IGNORE_REST
    assert host.dev.get_stat("unknown_opcode_count") == 1
    assert host.dev.get_stat("addr_bytes") == 4
    host.command(0xB7)
    assert host.dev.get_stat("unknown_opcode_count") == 1, "EN4B is accepted"
    host.command(0x66)
    host.command(0x99)
    assert host.dev.get_stat("addr_bytes") == 4


def test_a_config_can_power_up_in_four_byte_mode() -> None:
    host = make(size_bytes=32 * MIB, jedec_id=0xEF4019, addr_bytes=4)
    host.dev.set_timing_enable(False)
    assert host.dev.get_stat("addr_bytes") == 4
    host.dev.preload(0x0123_4567, b"\x5a")
    assert host.read_array(0x0123_4567, 1) == [0x5A]
    # ... and a reset returns to the configured power-up mode, not to 3.
    host.command(0xE9)
    host.command(0x66)
    host.command(0x99)
    assert host.dev.get_stat("addr_bytes") == 4


# -- QPI ---------------------------------------------------------------------------------


def test_enter_and_leave_qpi(fast: Host) -> None:
    fast.command(0x38)
    assert fast.dev.get_stat("qpi") == 1
    # In QPI even the opcode is four lanes wide.
    result = fast.command(0x03, addr=0x10, read=1)
    assert result.directives[0].lanes == 4
    assert all(d.lanes == 4 for d in result.directives if d.action is not Action.IGNORE_REST)
    fast.command(0xFF)
    assert fast.dev.get_stat("qpi") == 0
    assert fast.command(0x03, addr=0x10, read=1).directives[0].lanes == 1


def test_qpi_reads_and_programs_real_data(fast: Host) -> None:
    fast.dev.preload(0x800, b"\xde\xad")
    fast.command(0x38)
    assert fast.command(0x0B, addr=0x800, read=2).out == [0xDE, 0xAD]
    fast.wren()
    fast.command(0x02, addr=0x900, data=[0x0F])
    assert fast.dev.read_back(0x900, 1) == b"\x0f"


def test_quad_commands_need_the_qe_bit(fast: Host) -> None:
    fast.wren()
    fast.command(0x01, data=[0x00, 0x00])  # clear QE
    assert fast.dev.get_stat("qe") == 0
    for opcode, kwargs in ((0x6B, {"addr": 0}), (0xEB, {"addr": 0, "mode_byte": XIP_OFF})):
        assert fast.command(opcode, read=1, **kwargs).out == []
    assert fast.command(0x38).directives[1].action is Action.IGNORE_REST
    assert fast.dev.get_stat("qpi") == 0
    assert fast.dev.get_stat("qe_reject_count") == 3
    # Single-lane reads still work.
    assert fast.read_array(0, 1) == [0xFF]


# -- continuous read / XIP -------------------------------------------------------------------


def test_mode_byte_arms_continuous_read(fast: Host) -> None:
    fast.dev.preload(0x1000, b"\x11\x22\x33\x44")
    assert fast.command(0xEB, addr=0x1000, mode_byte=XIP_ON, read=2).out == [0x11, 0x22]
    assert fast.dev.get_stat("continuous_read") == 1
    # The next transaction has NO opcode: CS falls straight into the address.
    result = fast.xact(frame(addr=0x1002, mode_byte=XIP_ON), read=2)
    assert result.out == [0x33, 0x44]
    assert result.directives[0].action is Action.RECEIVE
    assert result.directives[0].lanes == 4, "XIP starts on the wide address lanes"


def test_a_non_continuous_mode_byte_leaves_xip(fast: Host) -> None:
    fast.dev.preload(0x1000, b"\x11\x22")
    fast.command(0xEB, addr=0x1000, mode_byte=XIP_ON, read=1)
    assert fast.dev.get_stat("continuous_read") == 1
    fast.xact(frame(addr=0x1000, mode_byte=XIP_OFF), read=1)
    assert fast.dev.get_stat("continuous_read") == 0
    # And the device is decoding opcodes again.
    assert fast.command(0x9F, read=1).out == [0xEF]


@pytest.mark.parametrize(
    ("mode_byte", "continuous"),
    [(0x00, False), (0x10, False), (0x20, True), (0xA0, True), (0x30, False), (0xFF, False)],
)
def test_only_m5_m4_eq_10_arms_continuous_read(fast: Host, mode_byte: int, continuous: bool) -> None:
    fast.command(0xEB, addr=0, mode_byte=mode_byte, read=1)
    assert fast.dev.get_stat("continuous_read") == int(continuous)


def test_dual_io_has_its_own_continuous_read(fast: Host) -> None:
    fast.dev.preload(0x20, b"\xab\xcd")
    fast.command(0xBB, addr=0x20, mode_byte=XIP_ON, read=1)
    assert fast.dev.get_stat("continuous_read") == 1
    result = fast.xact(frame(addr=0x20, mode_byte=XIP_ON), read=2)
    assert result.out == [0xAB, 0xCD]
    assert result.directives[0].lanes == 2, "dual I/O resumes on two lanes"


def test_a_reset_leaves_continuous_read(fast: Host) -> None:
    fast.command(0xEB, addr=0, mode_byte=XIP_ON, read=1)
    fast.command(0x66)
    # 0x66 is decoded normally only because XIP is a *next-transaction*
    # state; drive the reset through the XIP address phase instead.
    fast.dev.mode.exit_continuous()
    assert fast.dev.get_stat("continuous_read") == 0


def test_xip_survives_across_several_transactions(fast: Host) -> None:
    fast.dev.preload_fill(0, 0x100, 0x5A)
    fast.command(0xEB, addr=0, mode_byte=XIP_ON, read=1)
    for _ in range(3):
        result = fast.xact(frame(addr=0x10, mode_byte=XIP_ON), read=1)
        assert result.out == [0x5A]
    assert fast.dev.get_stat("continuous_read_entries") == 1


# -- busy / WIP ------------------------------------------------------------------------------


def test_program_goes_busy_for_tpp_and_wip_clears_on_its_own(host: Host) -> None:
    host.at(SEC).wren()
    result = host.at(SEC).command(0x02, addr=0, data=[0x00])
    assert result.busy == 700 * US
    assert host.at(SEC).status(0) == [0x01]
    assert host.at(SEC + 699 * US).status(0) == [0x01]
    assert host.at(SEC + 700 * US).status(0) == [0x00]
    assert host.at(2 * SEC).status(0) == [0x00]


def test_reads_are_refused_while_busy_but_status_is_not(host: Host) -> None:
    host.at(0).wren()
    host.at(0).command(0x02, addr=0, data=[0x00])
    assert host.at(US).read_array(0, 1) == []
    assert host.dev.get_stat("wip_reject_count") == 1
    assert host.at(US).status(0) == [0x01]
    assert host.at(SEC).read_array(0, 1) == [0x00]


def test_polling_status_does_not_cancel_the_busy_deadline(host: Host) -> None:
    host.at(0).wren()
    host.at(0).command(0x20, addr=0)
    for t in (MS, 10 * MS, 40 * MS):
        assert host.at(t).status(0) == [0x01]
    assert host.at(45 * MS).status(0) == [0x00]


def test_set_timing_overrides_one_operation(host: Host) -> None:
    host.dev.set_timing("tPP", NS)
    host.at(0).wren()
    assert host.at(0).command(0x02, addr=0, data=[0x00]).busy == NS
    host.at(SEC).wren()
    assert host.at(SEC).command(0x20, addr=0).busy == 45 * MS


def test_set_timing_enable_false_collapses_everything(host: Host) -> None:
    host.dev.set_timing_enable(False)
    host.wren()
    assert host.command(0x02, addr=0, data=[0x00]).busy == 0
    assert host.status(0) == [0x00], "never busy, so WIP is never seen"
    host.wren()
    assert host.command(0xC7).busy == 0
    host.wren()
    assert host.command(0x20, addr=0).busy == 0
    # Re-enabling restores the table.
    host.dev.set_timing_enable(True)
    host.wren()
    assert host.command(0x02, addr=0, data=[0x00]).busy == 700 * US


def test_an_ignored_command_never_arms_the_deadline(host: Host) -> None:
    host.at(0).wren()
    host.at(0).command(0x20, addr=0)  # 45 ms sector erase
    host.at(MS).command(0x77)  # unknown opcode mid-erase
    assert host.at(44 * MS).status(0) == [0x01], "the erase is still running"


# -- deep power-down ----------------------------------------------------------------------------


def test_deep_power_down_refuses_everything_but_release(fast: Host) -> None:
    fast.dev.preload(0, b"\x5a")
    fast.command(0xB9)
    assert fast.dev.get_stat("dpd") == 1
    assert fast.read_array(0, 1) == []
    assert fast.status(0) == []
    assert fast.dev.get_stat("dpd_reject_count") == 2
    assert fast.command(0xAB, addr=0, addr_bytes=3, read=1).out == [0x17]
    assert fast.dev.get_stat("dpd") == 0
    assert fast.read_array(0, 1) == [0x5A]


def test_release_without_an_address_still_releases(host: Host) -> None:
    host.command(0xB9)
    result = host.command(0xAB)
    assert host.dev.get_stat("dpd") == 0
    assert result.busy == 3 * US  # tRES1: no ID was read


def test_release_with_an_id_read_uses_tres2(host: Host) -> None:
    host.command(0xB9)
    result = host.command(0xAB, addr=0, addr_bytes=3, read=1)
    assert result.busy == 1800 * NS


# -- reset -----------------------------------------------------------------------------------------


def test_reset_requires_the_enable_first(fast: Host) -> None:
    fast.command(0xB7)  # EN4B
    fast.command(0x99)  # 0x99 alone does nothing
    assert fast.dev.get_stat("addr_bytes") == 4
    fast.command(0x66)
    fast.command(0x99)
    assert fast.dev.get_stat("addr_bytes") == 3
    assert fast.dev.get_stat("reset_count") == 1


def test_a_command_between_enable_and_reset_disarms_it(fast: Host) -> None:
    fast.command(0xB7)
    fast.command(0x66)
    fast.command(0x9F, read=1)  # anything at all
    fast.command(0x99)
    assert fast.dev.get_stat("addr_bytes") == 4
    assert fast.dev.get_stat("reset_count") == 0


def test_reset_clears_volatile_state_but_not_the_array(fast: Host) -> None:
    fast.dev.preload(0x10, b"\x5a")
    fast.command(0x38)  # QPI
    fast.command(0x06)  # WREN (in QPI: four lanes)
    fast.command(0x66)
    fast.command(0x99)
    assert fast.dev.get_stat("qpi") == 0
    assert fast.dev.get_stat("wel") == 0
    assert fast.dev.read_back(0x10, 1) == b"\x5a"


# -- written regions ---------------------------------------------------------------------------------


def test_written_regions_report_only_what_the_device_wrote(fast: Host) -> None:
    fast.dev.preload(0x5000, b"\x00" * 16)  # test setup, not a device write
    assert fast.dev.written_regions() == []
    program(fast, 0x1000, b"\x00" * 4)
    program(fast, 0x1004, b"\x00" * 4)
    program(fast, 0x2000, b"\x00")
    assert fast.dev.written_regions() == [(0x1000, 8), (0x2000, 1)]


def test_stats_count_what_happened(fast: Host) -> None:
    program(fast, 0, b"\x00")
    fast.wren()
    fast.command(0x20, addr=0)
    assert fast.dev.get_stat("program_count") == 1
    assert fast.dev.get_stat("erase_count") == 1
    assert fast.dev.get_stat("bytes_programmed") == 1
    assert fast.dev.get_stat("bytes_erased") == 4 * KIB
    assert fast.dev.get_stat("ignored_command_count") == 0


def test_unknown_stat_name_raises_with_the_known_names(fast: Host) -> None:
    with pytest.raises(KeyError, match="program_count"):
        fast.dev.get_stat("programs")


# -- VC misuse ------------------------------------------------------------------------------------------


def test_driving_the_bus_when_the_device_expected_a_byte_raises(host: Host) -> None:
    host.dev.cs_assert(0)
    with pytest.raises(ValueError, match="byte_in=-1"):
        host.dev.xfer(-1)


def test_a_transaction_with_no_bytes_at_all_is_harmless(host: Host) -> None:
    assert host.xact([]).busy == 0
    assert host.dev.get_stat("cmd_count") == 0


# -- content checks ------------------------------------------------------------------------------------


def test_check_content_raises_content_mismatch_at_the_first_bad_byte(fast: Host) -> None:
    fast.dev.preload(0x10, b"\xde\xad")
    fast.dev.check_content(0x10, b"\xde\xad")
    with pytest.raises(ContentMismatch, match="0x00000011"):
        fast.dev.check_content(0x10, b"\xde\xbe")


def test_check_content_fill_raises_content_mismatch(fast: Host) -> None:
    fast.dev.check_content_fill(0, 1 << 20, 0xFF)
    fast.dev.preload(0x8_0000, b"\x00")
    with pytest.raises(ContentMismatch, match="0x00080000"):
        fast.dev.check_content_fill(0, 1 << 20, 0xFF)


TOP = 16 * MIB


@pytest.mark.parametrize(
    ("call", "addr", "num_bytes"),
    [
        (lambda d, a, n: d.preload(a, b"\x00" * n), TOP - 1, 2),
        (lambda d, a, n: d.preload(a, b"\x00" * n), TOP, 1),
        (lambda d, a, n: d.preload(a, b"\x00" * n), -1, 1),
        (lambda d, a, n: d.preload(a, b"\x00" * n), TOP, 0),
        (lambda d, a, n: d.preload_fill(a, n, 0x00), TOP - 1, 2),
        (lambda d, a, n: d.preload_fill(a, n, 0x00), -1, 1),
        (lambda d, a, n: d.read_back(a, n), TOP - 1, 2),
        (lambda d, a, n: d.read_back(a, n), 0, -1),
        (lambda d, a, n: d.check_content(a, b"\xff" * n), TOP - 1, 2),
        (lambda d, a, n: d.check_content_fill(a, n, 0xFF), TOP - 1, 2),
        (lambda d, a, n: d.set_protection(a, n, True), TOP - 1, 2),
        (lambda d, a, n: d.set_protection(a, n, True), 0, -1),
        (lambda d, a, n: d.set_protection(a, n, True), -1, 1),
    ],
)
def test_ranges_outside_the_device_raise(host: Host, call, addr: int, num_bytes: int) -> None:
    with pytest.raises(ValueError, match=r"not inside the device|num_bytes"):
        call(host.dev, addr, num_bytes)
    assert host.dev.read_back(0, 2) == b"\xff\xff", "nothing wrapped to the start"
    assert host.dev.protection.locked_regions() == []


def test_ranges_ending_at_the_top_of_the_device_are_fine(host: Host) -> None:
    host.dev.preload(TOP - 2, b"\x01\x02")
    host.dev.preload_fill(TOP - 4, 2, 0x00)
    assert host.dev.read_back(TOP - 4, 4) == b"\x00\x00\x01\x02"
    host.dev.check_content(TOP - 2, b"\x01\x02")
    host.dev.check_content_fill(TOP - 4, 2, 0x00)
    host.dev.set_protection(TOP - 4, 4, True)
    host.dev.preload(0, b"")


@pytest.mark.parametrize("value", [-1, 0x100, 0x1A5])
def test_fill_values_outside_a_byte_raise(host: Host, value: int) -> None:
    with pytest.raises(ValueError, match="value"):
        host.dev.preload_fill(0, 4, value)
    assert host.dev.read_back(0, 4) == b"\xff" * 4
    with pytest.raises(ValueError, match="value"):
        host.dev.check_content_fill(0, 4, value)


@pytest.mark.parametrize("num_bytes", [0, -4])
def test_fills_need_at_least_one_byte(host: Host, num_bytes: int) -> None:
    with pytest.raises(ValueError, match="num_bytes"):
        host.dev.preload_fill(0, num_bytes, 0x00)
    with pytest.raises(ValueError, match="num_bytes"):
        host.dev.check_content_fill(0, num_bytes, 0xFF)


def test_busy_deadline_is_reported_in_femtoseconds(host: Host) -> None:
    host.at(SEC).wren()
    host.at(SEC).command(0x02, addr=0, data=[0x00])
    assert host.dev.get_stat("busy_deadline_fs") == SEC + 700 * US
    with pytest.raises(KeyError):
        host.dev.get_stat("busy_deadline_ps")


def test_xfer_without_cs_assert_raises(host: Host) -> None:
    with pytest.raises(RuntimeError, match="without cs_assert"):
        host.dev.xfer(0x03)
    host.xact([0x9F], read=1)
    with pytest.raises(RuntimeError, match="without cs_assert"):
        host.dev.xfer(0x03)
