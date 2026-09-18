"""The I2C backends, called the way the VHDL components call them."""

from __future__ import annotations

import numpy as np
from i2c_helpers import NS, US, Bus

from awesome_vunit_vcs.common.reports import Severity, decode_reports
from awesome_vunit_vcs.common.vunit_bridge import encode_samples, split_time
from awesome_vunit_vcs.i2c import Eeprom24, I2cDevice, RegisterDevice
from awesome_vunit_vcs.i2c.vunit_backend import (
    I2cMasterBackend,
    I2cMonitorBackend,
    I2cProtocolCheckerBackend,
    I2cTargetBackend,
)


def _text(value: str) -> list[int]:
    """Text as arg_text sends it."""
    return [ord(character) for character in value]


def _push(backend: I2cMonitorBackend | I2cProtocolCheckerBackend, bus: Bus) -> int:
    samples = encode_samples(bus.words, bus.times, 0, 1000)
    return backend.push(samples, list(split_time(0)), list(split_time(1000)))


class Doubler(I2cDevice):
    """A user device model: reads return twice the last byte written."""

    def __init__(self, offset: int = 0) -> None:
        super().__init__()
        self.value = offset

    def write(self, value: int, now_fs: int) -> bool:
        self.value = value
        return True

    def read(self, now_fs: int) -> int:
        return 2 * self.value


def test_master_timing_and_a_transfer() -> None:
    master = I2cMasterBackend(_text("tb:master"), 1, t_low=list(split_time(2 * US)))
    assert master.timing().tolist() == [2_000_000, 1_200_000, 300_000, 700_000, 700_000, 700_000, 1_300_000]
    words = master.transfer(0x50, np.array([0x12]), 1)
    assert words.dtype == np.int32 and len(words) == 7
    result = master.complete(np.array([0, 0, 0, 0, 0, 0x99, 0], dtype=np.int32)).tolist()
    assert result == [0, 0, 1, 0x99, 3, 1, 1, 1]


def test_master_reports_a_nack_only_when_it_expects_acknowledges() -> None:
    master = I2cMasterBackend("m")
    master.transfer(0x50, [1])
    result = master.complete([0, 1, -1, 0])
    assert result[:2].tolist() == [1, 1]
    [report] = decode_reports(master.take_reports())
    assert report.severity is Severity.ERROR and report.message == "m: write of 0x50: address nack"
    master.transfer(0x50, [1], expect_ack=False)
    assert master.complete([0, 1, -1, 0])[:2].tolist() == [1, 0]


def test_master_errors_become_reports() -> None:
    master = I2cMasterBackend("m", t_hd_dat=10**15)
    assert master.num_reports() == 1
    assert master.transfer(0x80).size == 0
    assert master.transfer_ops(_text("S 0xA0 P")).size == 3
    master.complete([0])
    reports = decode_reports(master.take_reports())
    assert [report.severity for report in reports] == [Severity.FAILURE] * 3


def test_target_directives_and_a_register_device() -> None:
    target = I2cTargetBackend(_text("t"), 0x20, stretch=10 * US)
    target.set_arguments(size_bytes=16)
    assert target.create_device(_text("registers")) == 0
    assert isinstance(target.device, RegisterDevice) and target.device.address == 0x20
    assert target.start([0, 0]).tolist() == [0, 0, 0, 0, 0]
    assert target.received(0x40, [0, 0]).tolist() == [0, 1, 0, 10_000_000, 0]
    target.received(0x03, 0)
    target.received(0x77, 0)
    assert target.stop(0) == 0
    assert target.read_memory(3, 1).tolist() == [0x77]
    target.check_memory([0x78], 3, _text("after the write"))
    [report] = decode_reports(target.take_reports())
    assert report.message == "t: after the write: memory at 0x3 is 0x77, expected 0x78"


def test_target_with_a_user_device_and_nack_injection() -> None:
    target = I2cTargetBackend("t", 0x20)
    target.set_arguments(offset=3)
    target.create_device("test_i2c_backend:Doubler")
    target.start(0)
    assert target.received(0x41, 0).tolist()[:3] == [1, 1, 6]
    target.inject_nack(0)
    target.start(0)
    assert target.received(0x41, 0).tolist()[:2] == [2, 0]
    target.create_device(_text("no_such_model"))
    target.preload([1], 0)
    reports = decode_reports(target.take_reports())
    assert [report.severity for report in reports] == [Severity.FAILURE, Severity.FAILURE]


def test_eeprom_through_the_backend() -> None:
    target = I2cTargetBackend("t", 0x50)
    target.set_arguments(size_bytes=512, page_bytes=16)
    target.create_device("eeprom")
    assert isinstance(target.device, Eeprom24) and target.device.responds_to(0x51)
    target.preload([1, 2], 0x1FE)
    assert target.read_memory(0x1FE, 2).tolist() == [1, 2]


def test_monitor_collects_transfers_for_vhdl() -> None:
    monitor = I2cMonitorBackend(_text("mon"))
    monitor.set_collect_transfers(True)
    bus = Bus().write(0x50, b"\x12\x34").start().byte(0xF4).byte(0xA5).start().byte(0xF5).byte(0x77, False).stop()
    assert _push(monitor, bus) == 0
    values = monitor.take_transfers().tolist()
    # address, flags, nack index, start hi, start lo, count, bytes
    assert values[:8] == [0x50, 0b11000, -1, 0, 0, 2, 0x12, 0x34]
    ten_bit_write = values[8:14]
    assert ten_bit_write[:3] == [0x2A5, 0b10010, -1] and ten_bit_write[5] == 0
    assert values[14:17] == [0x2A5, 0b11111, 0] and values[-2:] == [1, 0x77]
    assert monitor.take_transfers().size == 0
    assert monitor.transfer_count() == 3


def test_monitor_scoreboard_statistics_and_metavalues() -> None:
    monitor = I2cMonitorBackend("mon")
    monitor.check_transfer(0x50, False, [0x12, 0x34])
    monitor.check_transfer(0x50, True, [], _text("second"))
    monitor.check_transfer(0x51, False, [])
    bus = Bus().write(0x50, b"\x12\x34").write(0x50).metavalue("sda")
    assert _push(monitor, bus) == 2
    assert monitor.finish() == 3
    messages = [report.message for report in decode_reports(monitor.take_reports())]
    assert messages[0].startswith("mon: I2C_SCOREBOARD: second: transfer 1 at ")
    assert messages[0].endswith("has write, expected read")
    assert messages[1].startswith("mon: I2C_METAVALUE: metavalue on SDA at ")
    assert messages[2] == "mon: I2C_SCOREBOARD: expected transfer to 0x51 never came"
    values = monitor.statistics_values(list(split_time(bus.time))).tolist()
    assert values[:11] == [2, 2, 0, 2, 0, 2, 0, 0, 1, 400_000, 400_000]
    assert 0 < values[15] < 1_000_000
    assert (
        I2cMonitorBackend("quiet", report_metavalues=False).push(encode_samples([3 | 8], [0], 0), [0, 0], [0, 1]) == 0
    )


def test_protocol_checker_counts_switches_and_reset() -> None:
    checker = I2cProtocolCheckerBackend(_text("pc"), 1, t_buf=list(split_time(2 * US)))
    bus = Bus().write(0x50).write(0x50)
    assert _push(checker, bus) == 1
    [report] = decode_reports(checker.take_reports())
    assert report.severity is Severity.ERROR and report.message.startswith("pc: I2C_T_BUF: bus free for ")
    assert checker.check_count(_text("i2c_t_buf")) == 1
    checker.set_check_enabled(_text("i2c_t_buf"), False)
    checker.reset()
    assert _push(checker, Bus().write(0x50).write(0x50)) == 0
    assert checker.check_count("I2C_T_BUF") == 0
    checker.set_check_enabled("i2c_nothing", True)
    assert decode_reports(checker.take_reports())[0].severity is Severity.FAILURE


def test_protocol_checker_stuck_low_at_the_end() -> None:
    checker = I2cProtocolCheckerBackend("pc", 2, t_stuck=100 * NS)
    _push(checker, Bus().set(sda=0))
    assert checker.finish(1 * US) == 1
