"""Tests of the MDIO family without a simulator: the device model, the PHY engine and its backend."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.common.reports import Severity, decode_reports
from awesome_vunit_vcs.mdio import (
    NUM_REGISTERS,
    MdioCheckId,
    MdioDevice,
    MdioOperation,
    MdioPhy,
    MdioValueError,
    MdioViolation,
)
from awesome_vunit_vcs.mdio.phy import Action
from awesome_vunit_vcs.mdio.vunit_backend import MdioPhyBackend


def _header(phy_address: int, register_address: int, op: int, start: int = 0b01) -> int:
    """The bits from ST to REGAD, built field by field as the standard lists them."""
    bits = f"{start:02b}{op:02b}{phy_address:05b}{register_address:05b}"
    assert len(bits) == 14
    return int(bits, 2)


def test_device_holds_32_registers_with_initial_values() -> None:
    device = MdioDevice(registers={2: 0x0141, 3: 0x0E40})
    assert len(device.registers) == NUM_REGISTERS == 32
    assert device.read(2, 0) == 0x0141
    assert device.get_register(3) == 0x0E40
    assert device.get_register(31) == 0


def test_read_only_bits_keep_their_value_on_a_write_but_not_on_set() -> None:
    device = MdioDevice(registers={1: 0x796D}, read_only={1: 0xFFFF, 0: 0x00FF})
    device.write(1, 0x0000, 0)
    assert device.get_register(1) == 0x796D
    device.write(0, 0xABCD, 0)
    assert device.get_register(0) == 0xAB00
    device.set_register(1, 0x1234)
    assert device.get_register(1) == 0x1234


@pytest.mark.parametrize(("address", "value"), [(32, 0), (-1, 0), (0, 0x10000), (0, -1)])
def test_device_refuses_out_of_range_addresses_and_values(address: int, value: int) -> None:
    with pytest.raises(MdioValueError):
        MdioDevice().set_register(address, value)


def test_a_read_answers_with_the_register() -> None:
    phy = MdioPhy(MdioDevice(registers={17: 0xAC00}), phy_address=7)
    response = phy.header(32, _header(7, 17, 0b10), 0, now_fs=100)
    assert (response.action, response.data) == (Action.READ, 0xAC00)
    phy.read_end(False, 0, 0xAC00, 200)
    assert phy.violations == []
    assert phy.access_count(MdioOperation.READ, 17) == 1
    assert phy.accesses[0].time_fs == 200


def test_a_write_changes_the_register() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    assert phy.header(32, _header(7, 20, 0b01), 0, 0).action == Action.WRITE
    phy.write_end(0b10, 0x4C3A, 0, 0)
    assert phy.device.get_register(20) == 0x4C3A
    assert phy.access_count(MdioOperation.WRITE) == 1


def test_frames_to_other_phys_and_clause_45_frames_are_ignored_silently() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    assert phy.header(32, _header(3, 1, 0b10), 0, 0).action == Action.IGNORE
    assert phy.header(32, _header(7, 1, 0b10, start=0b00), 0, 0).action == Action.IGNORE
    assert phy.violations == []
    assert phy.access_count() == 0


def _only(phy: MdioPhy) -> MdioViolation:
    assert len(phy.violations) == 1, phy.violations
    return phy.violations[0]


def test_a_short_preamble_is_a_violation_and_the_frame_is_ignored() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    assert phy.header(31, _header(7, 1, 0b01), 0, 5).action == Action.IGNORE
    violation = _only(phy)
    assert violation.check is MdioCheckId.PREAMBLE
    assert violation.message == "MDIO_PREAMBLE: 31 preamble ones, the PHY needs 32 at 5 fs"


def test_a_suppressed_preamble_is_accepted_when_configured() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7, preamble_bits=0)
    assert phy.header(0, _header(7, 1, 0b01), 0, 0).action == Action.WRITE


@pytest.mark.parametrize("op", [0b00, 0b11])
def test_an_invalid_op_is_a_violation(op: int) -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    assert phy.header(32, _header(7, 1, op), 0, 0).action == Action.IGNORE
    assert _only(phy).check is MdioCheckId.OP


@pytest.mark.parametrize("ta", [0b00, 0b01, 0b11])
def test_a_write_with_a_bad_ta_is_a_violation_and_not_made(ta: int) -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    phy.header(32, _header(7, 1, 0b01), 0, 0)
    phy.write_end(ta, 0xFFFF, 0, 0)
    assert _only(phy).check is MdioCheckId.TA
    assert phy.device.get_register(1) == 0
    assert phy.access_count() == 0


def test_a_master_driving_the_read_ta_or_data_is_a_violation() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    phy.header(32, _header(7, 1, 0b10), 0, 0)
    phy.read_end(True, 3, 0, 0)
    assert [violation.check for violation in phy.violations] == [MdioCheckId.TA, MdioCheckId.CONTENTION]


def test_metavalues_are_violations() -> None:
    phy = MdioPhy(MdioDevice(), phy_address=7)
    assert phy.header(32, _header(7, 1, 0b01), 1, 0).action == Action.IGNORE
    phy.write_end(0b10, 0, 2, 0)
    assert [violation.check for violation in phy.violations] == [MdioCheckId.METAVALUE] * 2


def test_check_register_and_check_count() -> None:
    violations: list[MdioViolation] = []
    phy = MdioPhy(MdioDevice(registers={3: 1}), phy_address=7, on_violation=violations.append)
    assert phy.check_register(3, 1)
    assert not phy.check_register(3, 2, now_fs=9, message="after reset")
    assert violations[0].message == "after reset: MDIO_REGISTER: register 3 is 0x0001, expected 0x0002 at 9 fs"
    assert phy.check_count("register") == phy.check_count(MdioCheckId.REGISTER) == 1
    assert phy.check_count("MDIO_TA") == 0


def test_check_ids_parse_by_value_and_name() -> None:
    assert MdioCheckId.parse("mdio_ta") is MdioCheckId.TA
    assert MdioCheckId.parse("Contention") is MdioCheckId.CONTENTION
    with pytest.raises(MdioValueError, match="Unknown MDIO check"):
        MdioCheckId.parse("MDIO_CRC")


@pytest.mark.parametrize(("phy_address", "preamble_bits"), [(32, 32), (-1, 32), (0, -1)])
def test_phy_refuses_bad_configurations(phy_address: int, preamble_bits: int) -> None:
    with pytest.raises(MdioValueError):
        MdioPhy(MdioDevice(), phy_address, preamble_bits)


def test_backend_reports_violations_as_check_failures() -> None:
    backend = MdioPhyBackend("tb:phy", 5)
    assert backend.header(32, _header(5, 1, 0b01), 0, 0).tolist() == [int(Action.WRITE), 0, 0]
    assert backend.write_end(0b11, 0, 0, [0, 7]) == 1
    (report,) = decode_reports(backend.take_reports())
    assert report.severity is Severity.ERROR
    assert report.message == "tb:phy: MDIO_TA: the TA of a write is 11, expected 10 at 7 fs"
    assert backend.check_count([ord(char) for char in "mdio_ta"]) == 1


def test_backend_register_access_and_counts() -> None:
    backend = MdioPhyBackend("tb:phy", 5)
    assert backend.set_register(2, 0x0141) == 0
    assert backend.header(32, _header(5, 2, 0b10), 0, 0).tolist() == [int(Action.READ), 0x0141, 0]
    assert backend.read_end(False, 0, 0x0141, 0) == 0
    assert backend.get_register(2) == 0x0141
    assert backend.access_count() == 1
    assert backend.access_count(int(MdioOperation.WRITE)) == 0
    assert backend.access_count(int(MdioOperation.READ), 2) == 1
    assert backend.check_register(2, 0x0141) == 0


def test_backend_turns_exceptions_into_failure_reports() -> None:
    backend = MdioPhyBackend("tb:phy", 5)
    assert backend.get_register(40) == 0
    assert backend.set_register(0, 0x10000) == 2
    assert all(report.severity is Severity.FAILURE for report in decode_reports(backend.take_reports()))


def test_backend_creates_device_models_by_name() -> None:
    backend = MdioPhyBackend("tb:phy", 5)
    backend.set_arguments(registers={2: 0x0141})
    assert backend.create_device("registers") == 0
    assert backend.get_register(2) == 0x0141
    assert backend.create_device("unknown") == 1
    (report,) = decode_reports(backend.take_reports())
    assert "Unknown device model 'unknown'" in report.message
    assert backend.create_device("builtins:dict") == 1
    assert "is not an MdioDevice" in decode_reports(backend.take_reports())[0].message
