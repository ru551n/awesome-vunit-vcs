"""The I2C protocol checker, against timing violations built by hand."""

from __future__ import annotations

import pytest
from i2c_helpers import NS, US, Bus

from awesome_vunit_vcs.i2c import I2cCheckId, I2cProtocolChecker, I2cValueError, I2cViolation, SpeedMode, bus_limits

# Bus timing that meets each mode with some margin: t_low, t_high, t_hd_dat, t_su_sta, t_hd_sta, t_su_sto, t_buf
GOOD = {
    SpeedMode.STANDARD: (5 * US, 5 * US, 1 * US, 5 * US, 5 * US, 5 * US, 5 * US),
    SpeedMode.FAST: (1300 * NS, 1200 * NS, 300 * NS, 700 * NS, 700 * NS, 700 * NS, 1300 * NS),
    SpeedMode.FAST_PLUS: (500 * NS, 500 * NS, 100 * NS, 300 * NS, 300 * NS, 300 * NS, 500 * NS),
}


def _bus(mode: SpeedMode = SpeedMode.FAST, **changes: int) -> Bus:
    names = ("t_low", "t_high", "t_hd_dat", "t_su_sta", "t_hd_sta", "t_su_sto", "t_buf")
    return Bus(**{**dict(zip(names, GOOD[mode], strict=True)), **changes})


def _violations(bus: Bus, mode: SpeedMode = SpeedMode.FAST, **kwargs: int) -> list[I2cViolation]:
    checker = I2cProtocolChecker(bus_limits(mode), **kwargs)
    violations: list[I2cViolation] = []
    checker.violations.subscribe(violations.append)
    checker.feed(bus.words, bus.times)
    return violations


def _checks(bus: Bus, mode: SpeedMode = SpeedMode.FAST) -> list[I2cCheckId]:
    return [violation.check for violation in _violations(bus, mode)]


def _traffic(bus: Bus) -> Bus:
    bus.write(0x50, b"\x00\xff\x55")
    return bus.start().byte(0xA0).byte(0x01).start().byte(0xA1).byte(0x77, ack=False).stop()


@pytest.mark.parametrize("mode", list(SpeedMode))
def test_traffic_within_the_limits_passes(mode: SpeedMode) -> None:
    assert _checks(_traffic(_bus(mode)), mode) == []


def test_t_low() -> None:
    violations = _violations(_bus(t_low=1000 * NS, t_high=1500 * NS).write(0x50))
    assert {violation.check for violation in violations} == {I2cCheckId.T_LOW}
    message = violations[0].message
    assert message.startswith("I2C_T_LOW: SCL low for 1000000000 fs, less than the minimum 1300000000 fs at ")
    assert message.endswith(f" {violations[0].time_fs} fs")


def test_t_high_and_f_scl() -> None:
    # 1300 + 500 ns: tHIGH below 600 ns and a period below 2500 ns
    assert set(_checks(_bus(t_high=500 * NS).write(0x50))) == {I2cCheckId.T_HIGH, I2cCheckId.F_SCL}


def test_f_scl_alone() -> None:
    # Standard-mode low and high times, but a 9 us period is above 100 kHz
    bus = _bus(SpeedMode.STANDARD, t_low=4800 * NS, t_high=4200 * NS)
    assert set(_checks(bus.write(0x50), SpeedMode.STANDARD)) == {I2cCheckId.F_SCL}


def test_start_and_stop_setup_and_hold() -> None:
    assert set(_checks(_bus(t_hd_sta=400 * NS).write(0x50))) == {I2cCheckId.T_HD_STA}
    assert set(_checks(_bus(t_su_sto=400 * NS).write(0x50))) == {I2cCheckId.T_SU_STO}
    bus = _bus(t_su_sta=400 * NS).start().byte(0xA0).start().byte(0xA1, ack=False).stop()
    assert _checks(bus) == [I2cCheckId.T_SU_STA]


def test_t_buf() -> None:
    assert _checks(_bus(t_buf=1000 * NS).write(0x50).write(0x50)) == [I2cCheckId.T_BUF]


def test_data_setup_and_hold() -> None:
    # SDA changes 1250 ns into a 1300 ns low period: 50 ns setup
    assert set(_checks(_bus(t_hd_dat=1250 * NS).write(0x50, b"\x55"))) == {I2cCheckId.T_SU_DAT}
    limits = bus_limits(SpeedMode.FAST, t_hd_dat_fs=400 * NS)
    checker = I2cProtocolChecker(limits)
    bus = _bus().write(0x50, b"\x55")
    checker.feed(bus.words, bus.times)
    assert checker.count(I2cCheckId.T_HD_DAT) > 0


def test_a_stop_inside_a_byte_and_a_byte_without_acknowledge() -> None:
    bus = _bus().start().byte(0xA0)
    for bit in (1, 0, 1):
        bus.bit(bit)
    assert _checks(bus.stop()) == [I2cCheckId.SDA_STABLE]
    bus = _bus().start().byte(0xA0)
    for bit in (1, 0, 1, 0, 1, 0, 1, 0):
        bus.bit(bit)
    assert _checks(bus.start().byte(0xA1, ack=False).stop()) == [I2cCheckId.ACK_SLOT]


def test_metavalue_and_stuck_low() -> None:
    bus = _bus().write(0x50).metavalue("sda").metavalue("sda", after=10 * NS).set(sda=1, after=10 * NS)
    assert _checks(bus) == [I2cCheckId.METAVALUE]
    bus = _bus().set(scl=0).wait(2 * US)
    bus.words.append(bus.words[-1])
    bus.times.append(bus.time)
    violations = _violations(bus, t_stuck_fs=1 * US)
    assert [violation.check for violation in violations] == [I2cCheckId.STUCK_LOW]
    assert "SCL low since 0 fs" in violations[0].message


def test_enable_disable_count_and_reset() -> None:
    checker = I2cProtocolChecker(bus_limits(SpeedMode.FAST))
    bus = _bus(t_buf=1000 * NS).write(0x50).write(0x50).write(0x50)
    checker.disable("i2c_t_buf")
    checker.feed(bus.words, bus.times)
    assert checker.count(I2cCheckId.T_BUF) == 0 and not checker.is_enabled("T_BUF")
    checker.enable(I2cCheckId.T_BUF)
    checker.reset()
    checker.feed(bus.words, bus.times)
    assert checker.count("I2C_T_BUF") == 2
    checker.reset()
    assert checker.count(I2cCheckId.T_BUF) == 0
    with pytest.raises(I2cValueError):
        checker.count(I2cCheckId.SCOREBOARD)
    with pytest.raises(I2cValueError):
        checker.enable("I2C_NOPE")
