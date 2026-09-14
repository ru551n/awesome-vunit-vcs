# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
FlashBackend, driven the way the VHDL flash component drives it.

VHDL cannot say "that was a list, I wanted an int32 array" -- it just
misbehaves -- so return types are asserted here, and every error must come
back as a report rather than an exception escaping into the bridge.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pytest

from awesome_vunit_vcs.common.reports import Report, Severity, decode_reports
from awesome_vunit_vcs.common.vunit_bridge import join_time, split_time
from awesome_vunit_vcs.flash.config import BUSY_KEYS, DEFAULT_BUSY_FS, MIB
from awesome_vunit_vcs.flash.directive import LAYOUT_VERSION, Action, ignore_rest, unpack
from awesome_vunit_vcs.flash.vunit_backend import FlashBackend

US = 10**9
MS = 10**12
SEC = 10**15

NAME = "tb_flash:flash_a"


def backend_options(**overrides: Any) -> dict[str, Any]:
    """The keyword arguments the VHDL component passes, with the new_flash defaults."""
    options: dict[str, Any] = {
        "size_bytes": 16 * MIB,
        "page_bytes": 256,
        "sector_bytes": 4096,
        "block32_bytes": 32768,
        "block_bytes": 65536,
        "addr_bytes": 3,
        "addr_modes": 0,
        "jedec_id": 0xEF4018,
        "electronic_id": -1,
        "sr1_default": 0x00,
        "sr2_default": 0x02,
        "sr3_default": 0x00,
        "busy": {key: split_time(DEFAULT_BUSY_FS[key]) for key in BUSY_KEYS},
        "timing_enabled": True,
    }
    options.update(overrides)
    return options


def make(name: str = NAME, **overrides: Any) -> FlashBackend:
    return FlashBackend(name, **backend_options(**overrides))


@pytest.fixture
def fast() -> FlashBackend:
    """A backend with busy times off, the common testbench setup."""
    return make(timing_enabled=False)


def reports(backend: FlashBackend) -> list[Report]:
    return decode_reports(backend.take_reports())


def only_report(backend: FlashBackend, severity: Severity) -> str:
    assert backend.num_reports() == 1
    taken = reports(backend)
    assert [report.severity for report in taken] == [severity]
    assert backend.num_reports() == 0
    return taken[0].message


def transaction(
    backend: FlashBackend, send: list[int], read: int = 0, now_fs: int = 0, trailing_bits: int = 0
) -> tuple[list[int], Any]:
    """cs_assert -> one xfer per byte -> cs_deassert, following the
    directives, which is all the VC ever does."""
    hi, lo = split_time(now_fs)
    out: list[int] = []
    directive = unpack(backend.cs_assert(hi, lo))
    index = 0
    while directive.action is not Action.IGNORE_REST:
        if directive.action is Action.RECEIVE:
            if index >= len(send):
                break
            byte = send[index]
            index += 1
        else:
            if len(out) >= read:
                break
            out.append(directive.byte_out)
            byte = -1
        packed = backend.xfer(byte, hi, lo) if directive.volatile else backend.xfer(byte)
        directive = unpack(packed)
    return out, backend.cs_deassert(trailing_bits, hi, lo)


# -- creation --------------------------------------------------------------


def test_layout_version_matches_the_directive_module() -> None:
    assert make().layout_version() == LAYOUT_VERSION == 1


def test_a_valid_configuration_queues_no_reports() -> None:
    backend = make()
    assert backend.num_reports() == 0
    assert backend.take_reports() == ""


def test_configuration_reaches_the_device() -> None:
    backend = make(
        size_bytes=32 * MIB,
        addr_bytes=4,
        addr_modes=4,
        jedec_id=0x20BA19,
        electronic_id=0x42,
        sr2_default=0x00,
        block32_bytes=0,
    )
    assert backend.num_reports() == 0
    assert backend.get_stat("addr_bytes") == 4
    assert backend.get_stat("sr2") == 0x00
    assert backend.get_stat("timing_enabled") == 1
    out, _ = transaction(backend, [0x9F], read=3)
    assert out == [0x20, 0xBA, 0x19]
    config = backend.device.config
    assert config.electronic_id == 0x42
    assert config.block32_bytes == 0
    assert int(config.addr_modes) == 4


def test_a_negative_electronic_id_is_derived_from_the_jedec_id() -> None:
    assert make(electronic_id=-1).device.config.device_id() == 0x17


def test_an_invalid_configuration_is_a_failure_report_not_an_exception() -> None:
    backend = make(size_bytes=3)
    message = only_report(backend, Severity.FAILURE)
    assert message.startswith(f"{NAME}: __init__ raised ValueError: ")
    assert "size_bytes=3" in message
    # The fallback device keeps later calls harmless
    assert backend.get_stat("addr_bytes") == 3
    assert backend.num_reports() == 0


def test_invalid_busy_times_are_a_failure_report() -> None:
    busy = {key: split_time(DEFAULT_BUSY_FS[key]) for key in BUSY_KEYS if key != "tRES2"}
    assert "tRES2" in only_report(make(busy=busy), Severity.FAILURE)
    busy = {key: split_time(DEFAULT_BUSY_FS[key]) for key in BUSY_KEYS}
    busy["tSE"] = (0, -1)
    message = only_report(make(busy=busy), Severity.FAILURE)
    assert message.startswith(f"{NAME}: __init__ raised ValueError: ")
    assert "lo=-1" in message


def test_timing_enabled_false_starts_with_timing_off(fast: FlashBackend) -> None:
    assert fast.get_stat("timing_enabled") == 0
    transaction(fast, [0x06])
    _, busy = transaction(fast, [0x20, 0, 0, 0])
    assert list(busy) == [0, 0, 0]


def test_instances_are_independent() -> None:
    first = make("tb:flash_a")
    second = make("tb:flash_b", size_bytes=4 * MIB, jedec_id=0xEF4016)
    assert first.preload(np.array([0xAA], dtype=np.int32), 0) == 0
    assert list(second.read_back(0, 1)) == [0xFF]
    assert list(first.read_back(0, 1)) == [0xAA]
    assert second.get_stat("sr1") == 0


# -- the wire --------------------------------------------------------------


def test_jedec_id_over_the_bus_with_split_times() -> None:
    backend = make()
    out, busy = transaction(backend, [0x9F], read=3, now_fs=5 * SEC + 123)
    assert out == [0xEF, 0x40, 0x18]
    assert isinstance(busy, np.ndarray)
    assert busy.dtype == np.int32
    assert list(busy) == [0, 0, 0]
    assert backend.num_reports() == 0


def test_a_full_read_transaction(fast: FlashBackend) -> None:
    fast.preload([0x11, 0x22], 0x1234)
    out, busy = transaction(fast, [0x03, 0x00, 0x12, 0x34], read=2)
    assert out == [0x11, 0x22]
    assert list(busy) == [0, 0, 0]


def test_a_sector_erase_returns_its_busy_time_as_halves() -> None:
    backend = make()
    transaction(backend, [0x06])
    _, busy = transaction(backend, [0x20, 0x00, 0x10, 0x00])
    assert list(busy) == [*split_time(45 * MS), 0]
    assert join_time(int(busy[0]), int(busy[1])) == 45_000_000_000_000


def test_configured_busy_times_are_used() -> None:
    busy = {key: split_time(DEFAULT_BUSY_FS[key]) for key in BUSY_KEYS}
    busy["tSE"] = split_time(1_000)
    backend = make(busy=busy)
    transaction(backend, [0x06])
    _, erase_busy = transaction(backend, [0x20, 0, 0, 0])
    assert list(erase_busy) == [0, 1_000, 0]
    transaction(backend, [0x06], now_fs=SEC)
    _, program_busy = transaction(backend, [0x02, 0, 0, 0, 0x00], now_fs=SEC)
    assert join_time(int(program_busy[0]), int(program_busy[1])) == 700 * US


def test_large_busy_times_split_into_32_bit_halves() -> None:
    backend = make()
    transaction(backend, [0x06])
    _, busy = transaction(backend, [0xC7])
    assert join_time(int(busy[0]), int(busy[1])) == 20 * SEC
    assert all(0 <= int(value) < 2**31 for value in busy)


def test_wip_follows_the_time_vhdl_sends() -> None:
    backend = make()
    transaction(backend, [0x06])
    transaction(backend, [0x02, 0, 0, 0, 0x00], now_fs=SEC)
    assert backend.get_stat("wip") == 1
    assert backend.get_stat("busy_remaining_us") == 700
    # A status read at a later time, passed on the volatile xfer, sees WIP clear
    out, _ = transaction(backend, [0x05], read=1, now_fs=SEC + 699 * US)
    assert out == [0x01]
    out, _ = transaction(backend, [0x05], read=1, now_fs=SEC + 700 * US)
    assert out == [0x00]
    assert backend.get_stat("wip") == 0


def test_xfer_accepts_an_omitted_time(fast: FlashBackend) -> None:
    fast.cs_assert(*split_time(SEC))
    assert unpack(fast.xfer(0x9F)).action is Action.TRANSMIT
    assert list(fast.cs_deassert(0, *split_time(SEC))) == [0, 0, 0]
    assert fast.num_reports() == 0


def test_trailing_bits_abort_a_program(fast: FlashBackend) -> None:
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0, 0x04, 0, 0xAA], trailing_bits=3)
    assert list(fast.read_back(0x400, 1)) == [0xFF]
    assert fast.get_stat("abort_count") == 1


def test_xfer_without_cs_assert_is_a_failure_report(fast: FlashBackend) -> None:
    assert fast.xfer(0x03) == ignore_rest()
    message = only_report(fast, Severity.FAILURE)
    assert message.startswith(f"{NAME}: xfer raised ")


def test_driving_the_bus_when_a_byte_was_expected_is_a_failure_report(fast: FlashBackend) -> None:
    fast.cs_assert(0, 0)
    assert fast.xfer(-1) == ignore_rest()
    assert "byte_in=-1" in only_report(fast, Severity.FAILURE)


def test_invalid_time_halves_are_failure_reports(fast: FlashBackend) -> None:
    assert fast.cs_assert(-1, 0) == ignore_rest()
    assert only_report(fast, Severity.FAILURE).startswith(f"{NAME}: cs_assert raised ValueError: ")
    fast.cs_assert(0, 0)
    assert fast.xfer(0x9F, 0, 1 << 30) == ignore_rest()
    only_report(fast, Severity.FAILURE)
    busy = fast.cs_deassert(0, 0, -1)
    assert busy.dtype == np.int32
    assert list(busy) == [0, 0, 1]
    assert only_report(fast, Severity.FAILURE).startswith(f"{NAME}: cs_deassert raised ValueError: ")


# -- control plane ---------------------------------------------------------


@pytest.mark.parametrize(
    "call",
    [
        lambda b: b.reset(),
        lambda b: b.preload([1], 0),
        lambda b: b.preload_fill(0, 16, 0),
        lambda b: b.check_content([0xFF] * 16, 0x100),
        lambda b: b.check_content_fill(0x100, 16, 0xFF),
        lambda b: b.set_timing_enable(True),
        lambda b: b.set_timing("tPP", *split_time(US)),
        lambda b: b.set_protection(0, 16, True),
        lambda b: b.clear_statistics(),
    ],
)
def test_control_calls_return_the_number_of_waiting_reports(fast: FlashBackend, call: Any) -> None:
    assert call(fast) == 0


def test_control_calls_count_reports_already_waiting(fast: FlashBackend) -> None:
    fast.get_stat("nope")
    assert fast.reset() == 1
    assert fast.preload_fill(0, 1, 0) == 1


@pytest.mark.parametrize(
    "call",
    [
        lambda b: b.read_back(0, 4),
        lambda b: b.written_regions(),
    ],
)
def test_array_returns_are_int32_numpy(fast: FlashBackend, call: Any) -> None:
    value = call(fast)
    assert isinstance(value, np.ndarray)
    assert value.dtype == np.int32


def test_preload_and_read_back_round_trip(fast: FlashBackend) -> None:
    assert fast.preload(np.array([1, 2, 3], dtype=np.int32), 0x100) == 0
    assert list(fast.read_back(0xFF, 5)) == [0xFF, 1, 2, 3, 0xFF]


def test_preload_accepts_a_plain_sequence_and_an_empty_array(fast: FlashBackend) -> None:
    assert fast.preload([0x00, 0xFF, 0x80], 0) == 0
    assert list(fast.read_back(0, 3)) == [0x00, 0xFF, 0x80]
    assert fast.preload(np.array([], dtype=np.int32), 0) == 0


def test_preload_rejects_non_byte_values(fast: FlashBackend) -> None:
    assert fast.preload([300], 0) == 1
    message = only_report(fast, Severity.FAILURE)
    assert message.startswith(f"{NAME}: preload raised ValueError: ")
    assert "300" in message
    assert fast.preload([0x00, 0x100], 0) == 1
    assert "element 1" in only_report(fast, Severity.FAILURE)
    assert fast.preload([-1], 0) == 1
    only_report(fast, Severity.FAILURE)
    assert list(fast.read_back(0, 2)) == [0xFF, 0xFF], "nothing was written"


def test_preload_past_the_end_is_a_failure_report(fast: FlashBackend) -> None:
    assert fast.preload_fill(0, 16 * MIB + 1, 0) == 1
    only_report(fast, Severity.FAILURE)


def test_preload_at_the_end_of_the_device_does_not_wrap(fast: FlashBackend) -> None:
    assert fast.preload([0x00, 0x00], 16 * MIB - 1) == 1
    assert "not inside the device" in only_report(fast, Severity.FAILURE)
    assert list(fast.read_back(0, 1)) == [0xFF]


def test_fill_values_outside_a_byte_are_failure_reports(fast: FlashBackend) -> None:
    assert fast.preload_fill(0, 4, 0x100) == 1
    assert only_report(fast, Severity.FAILURE).startswith(f"{NAME}: preload_fill raised ValueError: ")
    assert list(fast.read_back(0, 1)) == [0xFF]
    assert fast.check_content_fill(0, 4, 0x1FF) == 1
    assert only_report(fast, Severity.FAILURE).startswith(f"{NAME}: check_content_fill raised ValueError: ")


def test_read_back_failure_returns_an_empty_array(fast: FlashBackend) -> None:
    value = fast.read_back(16 * MIB, 4)
    assert value.dtype == np.int32
    assert value.size == 0
    only_report(fast, Severity.FAILURE)


def test_check_content_on_erased_flash_is_an_error_report(fast: FlashBackend) -> None:
    assert fast.check_content([0x00], 0) == 1
    message = only_report(fast, Severity.ERROR)
    assert message.startswith(f"{NAME}: ")
    assert "0x00000000" in message


def test_check_content_reports_the_first_bad_byte(fast: FlashBackend) -> None:
    fast.preload([0xDE, 0xAD], 0x10)
    assert fast.check_content(np.array([0xDE, 0xAD], dtype=np.int32), 0x10) == 0
    assert fast.check_content([0xDE, 0xBE], 0x10) == 1
    assert "0x00000011" in only_report(fast, Severity.ERROR)


def test_check_content_with_non_byte_values_is_a_failure(fast: FlashBackend) -> None:
    assert fast.check_content([0x1FF], 0) == 1
    only_report(fast, Severity.FAILURE)


def test_check_content_fill_does_not_build_the_expectation(fast: FlashBackend) -> None:
    assert fast.check_content_fill(0, 1 << 20, 0xFF) == 0
    fast.preload([0x00], 0x8_0000)
    assert fast.check_content_fill(0, 1 << 20, 0xFF) == 1
    message = only_report(fast, Severity.ERROR)
    assert message.startswith(f"{NAME}: ")
    assert "0x00080000" in message


def test_written_regions_is_a_flat_addr_len_array(fast: FlashBackend) -> None:
    assert list(fast.written_regions()) == []
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0x00, 0x10, 0x00, 0x00, 0x00])
    assert list(fast.written_regions()) == [0x1000, 2]


def test_written_regions_after_a_page_program(fast: FlashBackend) -> None:
    page_addr = 0x0003_0000
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0x03, 0x00, 0x00, *range(256)])
    regions = fast.written_regions()
    assert regions.dtype == np.int32
    assert list(regions) == [page_addr, 256]
    assert list(fast.read_back(page_addr, 4)) == [0, 1, 2, 3]


def test_load_image(fast: FlashBackend, tmp_path: Path) -> None:
    path = tmp_path / "image.bin"
    path.write_bytes(bytes(range(4)))
    assert fast.load_image(str(path), "bin", 0x200) == 0
    assert list(fast.read_back(0x200, 4)) == [0, 1, 2, 3]
    assert fast.load_image(str(path), "auto", 0x300) == 0
    assert list(fast.read_back(0x300, 4)) == [0, 1, 2, 3]


def test_load_image_failure_is_a_report(fast: FlashBackend, tmp_path: Path) -> None:
    assert fast.load_image(str(tmp_path / "missing.bin"), "bin", 0) == 1
    only_report(fast, Severity.FAILURE)
    assert fast.load_image(str(tmp_path / "image.xyz"), "auto", 0) == 1
    assert "cannot infer image format" in only_report(fast, Severity.FAILURE)
    assert fast.load_image(str(tmp_path / "image.bin"), "xyz", 0) == 1
    assert "unknown image format" in only_report(fast, Severity.FAILURE)


def test_set_protection(fast: FlashBackend) -> None:
    assert fast.set_protection(0x1000, 0x1000, True) == 0
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0x00, 0x10, 0x00, 0x00])
    assert list(fast.read_back(0x1000, 1)) == [0xFF]
    assert fast.get_stat("protect_reject_count") == 1
    assert fast.set_protection(0x1000, 0x1000, False) == 0
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0x00, 0x10, 0x00, 0x00])
    assert list(fast.read_back(0x1000, 1)) == [0x00]


def test_a_reset_while_cs_is_low_is_not_a_failure(fast: FlashBackend) -> None:
    fast.cs_assert(0, 0)
    assert unpack(fast.xfer(0x9F)).action is Action.TRANSMIT
    assert fast.reset() == 0
    assert fast.xfer(-1) == ignore_rest()
    assert list(fast.cs_deassert(0, 0, 0)) == [0, 0, 0]
    out, _ = transaction(fast, [0x9F], read=1)
    assert out == [0xEF]
    assert fast.num_reports() == 0


def test_timing_off_ends_a_running_busy_period() -> None:
    backend = make()
    transaction(backend, [0x06], now_fs=SEC)
    transaction(backend, [0x20, 0, 0, 0], now_fs=SEC)
    assert backend.get_stat("wip") == 1
    assert backend.set_timing_enable(False) == 0
    assert backend.get_stat("wip") == 0
    assert backend.get_stat("busy_remaining_us") == 0


def test_reset_keeps_the_array_but_drops_the_mode(fast: FlashBackend) -> None:
    fast.preload([0x5A], 0)
    transaction(fast, [0xB7])  # EN4B
    assert fast.get_stat("addr_bytes") == 4
    assert fast.reset() == 0
    assert fast.get_stat("addr_bytes") == 3
    assert list(fast.read_back(0, 1)) == [0x5A]


def test_set_timing_and_enable() -> None:
    backend = make()
    assert backend.set_timing("tPP", *split_time(2 * MS)) == 0
    transaction(backend, [0x06])
    _, busy = transaction(backend, [0x02, 0, 0, 0, 0x00])
    assert join_time(int(busy[0]), int(busy[1])) == 2 * MS
    assert backend.set_timing_enable(False) == 0
    assert backend.get_stat("timing_enabled") == 0
    transaction(backend, [0x06], now_fs=SEC)
    _, busy = transaction(backend, [0x02, 0, 0, 1, 0x00], now_fs=SEC)
    assert list(busy) == [0, 0, 0]


def test_set_timing_with_an_unknown_name_is_a_failure_report(fast: FlashBackend) -> None:
    assert fast.set_timing("tXX", 0, 1) == 1
    message = only_report(fast, Severity.FAILURE)
    assert message.startswith(f"{NAME}: set_timing raised KeyError: ")
    assert "tXX" in message


def test_unknown_stat_is_a_failure_report_and_returns_0(fast: FlashBackend) -> None:
    assert fast.get_stat("nope") == 0
    message = only_report(fast, Severity.FAILURE)
    assert message.startswith(f"{NAME}: get_stat raised KeyError: ")


def test_a_stat_beyond_32_bits_is_a_failure_report_and_returns_0() -> None:
    backend = make()
    backend.set_timing("tSE", *split_time(MS))
    transaction(backend, [0x06], now_fs=SEC)
    transaction(backend, [0x20, 0, 0, 0], now_fs=SEC)
    backend.device.stats["bytes_read"] = 2**31
    assert backend.num_reports() == 0
    assert backend.get_stat("bytes_read") == 0
    message = only_report(backend, Severity.FAILURE)
    assert message.startswith(f"{NAME}: get_stat raised ValueError: ")
    assert "'bytes_read'" in message
    assert str(2**31) in message
    # A value that fits is returned unchanged
    assert backend.get_stat("wip") == 1
    assert backend.num_reports() == 0


def test_get_stat_with_a_time_advances_the_device_time() -> None:
    backend = make()
    transaction(backend, [0x06], now_fs=SEC)
    transaction(backend, [0x02, 0, 0, 0, 0x00], now_fs=SEC)
    # Without a time, the stat is evaluated at the last time VHDL sent
    assert backend.get_stat("wip") == 1
    assert backend.get_stat("busy_remaining_us", *split_time(SEC + 200 * US)) == 500
    assert backend.get_stat("sr1", *split_time(SEC + 700 * US)) == 0x00
    assert backend.get_stat("wip") == 0
    # An earlier time does not move the device time back
    assert backend.get_stat("wip", *split_time(SEC)) == 0
    assert backend.device.now_fs == SEC + 700 * US
    assert backend.num_reports() == 0


def test_get_stat_with_invalid_time_halves_is_a_failure_report(fast: FlashBackend) -> None:
    assert fast.get_stat("wip", 0, 1 << 30) == 0
    assert only_report(fast, Severity.FAILURE).startswith(f"{NAME}: get_stat raised ValueError: ")


def test_clear_statistics_keeps_the_content(fast: FlashBackend) -> None:
    transaction(fast, [0x06])
    transaction(fast, [0x02, 0x00, 0x10, 0x00, 0x00])
    transaction(fast, [0x77])
    assert fast.clear_statistics() == 0
    assert fast.get_stat("program_count") == 0
    assert fast.get_stat("unknown_opcode_count") == 0
    assert list(fast.written_regions()) == []
    assert list(fast.read_back(0x1000, 1)) == [0x00]
    fast.get_stat("nope")
    assert fast.clear_statistics() == 1


def test_reports_are_taken_in_order(fast: FlashBackend) -> None:
    fast.get_stat("nope")
    fast.check_content([0x00], 0)
    assert fast.num_reports() == 2
    assert [report.severity for report in reports(fast)] == [Severity.FAILURE, Severity.ERROR]
    assert fast.take_reports() == ""
