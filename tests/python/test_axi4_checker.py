# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The AXI4 protocol checker, one hand-built violation at a time."""

from __future__ import annotations

from collections.abc import Callable

import pytest
from axi4_helpers import PERIOD_FS, Recorder

from awesome_vunit_vcs.axi4 import Axi4CheckId, Axi4Config, Axi4ProtocolChecker, Axi4ValueError, Axi4Violation
from awesome_vunit_vcs.axi4.checks import PROTOCOL_CHECKS

C = Axi4CheckId
INCR, FIXED, WRAP = 1, 0, 2


def _check(
    bus: Recorder, timeout_cycles: int = 0, lite: bool = False
) -> tuple[Axi4ProtocolChecker, list[Axi4Violation]]:
    checker = Axi4ProtocolChecker(
        Axi4Config(data_width=bus.data_width, id_width=0 if lite else bus.id_width, lite=lite), timeout_cycles
    )
    violations: list[Axi4Violation] = []
    checker.violations.subscribe(violations.append)
    checker.feed(*bus.take())
    return checker, violations


def _checks(violations: list[Axi4Violation]) -> list[Axi4CheckId]:
    return [violation.check for violation in violations]


def _write(bus: Recorder, **aw: int) -> Recorder:
    beats = aw.get("len", 0) + 1
    bus.aw(**aw).step()
    for index in range(beats):
        bus.w(index, last=index == beats - 1).step()
    return bus.b(id=aw.get("id", 0)).step()


def _read(bus: Recorder, **ar: int) -> Recorder:
    beats = ar.get("len", 0) + 1
    bus.ar(**ar).step()
    for index in range(beats):
        bus.r(id=ar.get("id", 0), data=index, last=index == beats - 1).step()
    return bus


def test_legal_traffic_has_no_violations() -> None:
    bus = Recorder()
    bus.period()
    _write(bus, id=1, addr=0x100, len=3)
    _write(bus, addr=0x38, len=3, burst=WRAP)
    _read(bus, id=2, addr=0x1003, len=2)
    _read(bus, addr=0x7, len=15, size=1, burst=FIXED)
    _write(bus, addr=0x80, len=3, lock=1)
    bus.ar(addr=0x80, lock=1).step().r(resp=1).step()
    checker, violations = _check(bus)
    assert violations == []
    assert all(count == 0 for count in checker.counts.values())


@pytest.mark.parametrize(
    ("ar", "check", "text"),
    [
        ({"addr": 0xFF0, "len": 4}, C.BURST_4K, "up to 0x1003 crosses a 4 KB boundary"),
        ({"addr": 0x40, "len": 2, "burst": WRAP}, C.WRAP_LEN, "WRAP burst of 3 beats"),
        ({"addr": 0x42, "len": 3, "burst": WRAP}, C.WRAP_ALIGN, "not aligned to its 4 byte beats"),
        ({"addr": 0x40, "len": 16, "burst": FIXED}, C.LEN_FIXED, "FIXED burst of 17 beats"),
        ({"addr": 0x40, "size": 3}, C.SIZE, "ARSIZE 3 (8 bytes) is wider than the 4 byte data bus"),
        ({"addr": 0x40, "burst": 3}, C.BURST_TYPE, "reserved value 0b11"),
        ({"addr": 0x40, "cache": 0b0100}, C.CACHE, "ARCACHE 0b0100"),
        ({"addr": 0x44, "len": 1, "lock": 1}, C.EXCL, "not aligned to its 8 bytes"),
        ({"addr": 0x40, "len": 2, "lock": 1}, C.EXCL, "12 bytes, not a power of 2"),
    ],
)
def test_address_rules(ar: dict[str, int], check: Axi4CheckId, text: str) -> None:
    bus = Recorder()
    bus.period()
    _read(bus, id=5, **ar)
    checker, violations = _check(bus)
    assert _checks(violations) == [check]
    assert violations[0].message.startswith(f"{check.value}: ARID 5 ARADDR 0x{ar['addr']:X}")
    assert text in violations[0].message
    assert checker.count(check) == 1


def test_an_exclusive_access_of_more_than_16_beats() -> None:
    bus = Recorder()
    bus.period()
    _read(bus, addr=0x0, len=31, size=0, lock=1)
    _, violations = _check(bus)
    assert _checks(violations) == [C.EXCL]
    assert "32 beats, more than 16" in violations[0].message


def test_wlast_on_the_wrong_beat() -> None:
    bus = Recorder()
    bus.period().aw(id=1, addr=0x10, len=2).step()
    bus.w(0, last=True).step().w(1, last=False).step().w(2, last=False).step().b(id=1)
    _, violations = _check(bus)
    assert _checks(violations) == [C.WLAST, C.WLAST]
    assert "WLAST is 1 on beat 0 of 3 of the write ID 1 at 0x10" in violations[0].message
    assert "WLAST is 0 on beat 2 of 3" in violations[1].message


def test_rlast_on_the_wrong_beat() -> None:
    bus = Recorder()
    bus.period().ar(id=1, addr=0x10, len=1).step()
    bus.r(id=1, last=False).step().r(id=1, last=False)
    _, violations = _check(bus)
    assert _checks(violations) == [C.RLAST]
    assert "RLAST is 0 on beat 1 of 2 of the read ID 1" in violations[0].message


def test_wstrb_outside_the_lanes_of_a_beat() -> None:
    bus = Recorder()
    bus.period().aw(addr=0x2, size=1).step().w(0, strb=0b0111).step().b()
    _, violations = _check(bus)
    assert _checks(violations) == [C.WSTRB]
    assert "lanes 0x3 outside the lanes 2 to 3 of beat 0" in violations[0].message


@pytest.mark.parametrize(
    ("traffic", "text"),
    [
        (lambda bus: bus.b(id=3), "BID 3 BRESP OKAY"),
        (lambda bus: bus.r(id=2), "read data RID 2"),
        (lambda bus: bus.aw(id=3, len=1).step().w(0, last=False).step().b(id=3), "before the last write data beat"),
    ],
)
def test_responses_without_an_outstanding_transaction(traffic: Callable[[Recorder], Recorder], text: str) -> None:
    bus = Recorder()
    traffic(bus.period())
    _, violations = _check(bus)
    assert _checks(violations) == [C.UNEXPECTED_RESP]
    assert text in violations[0].message


def test_exokay_to_a_normal_access() -> None:
    bus = Recorder()
    bus.period().ar(id=1).step().r(id=1, resp=1).step().aw().w(0).step().b(resp=1)
    _, violations = _check(bus)
    assert _checks(violations) == [C.EXCL, C.EXCL]
    assert "EXOKAY response" in violations[0].message


def test_payload_changes_while_waiting_for_ready() -> None:
    bus = Recorder()
    bus.period().aw(addr=0x10, ready=False).step().aw(addr=0x14, len=1, ready=False).step().aw(addr=0x14, len=1)
    _, violations = _check(bus)
    assert _checks(violations) == [C.STABLE]
    assert "AWADDR, AWLEN changed while AWVALID was 1 and AWREADY 0" in violations[0].message


def test_write_data_is_compared_on_strobed_lanes_only() -> None:
    bus = Recorder()
    bus.period().aw().step()
    bus.w(0x11000022, strb=0b0001, ready=False).step().w(0x99999922, strb=0b0001).step()
    bus.b()
    _, violations = _check(bus)
    assert violations == []


def test_valid_falls_before_ready() -> None:
    bus = Recorder()
    bus.period().ar(ready=False).step().ar(valid=False, ready=False)
    _, violations = _check(bus)
    assert _checks(violations) == [C.VALID_DROP]
    assert "ARVALID fell before ARREADY accepted the payload offered since 0 fs" in violations[0].message


def test_valid_during_and_right_after_reset() -> None:
    bus = Recorder()
    bus.period().reset(True).aw(resetn=False, ready=False).step()
    bus.reset(False).w(0).step()
    bus.aw().step().b()
    _, violations = _check(bus)
    assert _checks(violations) == [C.RESET_VALID, C.RESET_VALID]
    assert "AWVALID is 1 while ARESETn is 0" in violations[0].message
    assert "WVALID is 1 at the first rising edge of ACLK after reset" in violations[1].message


def test_metavalues() -> None:
    bus = Recorder()
    bus.period().reset(False, resetn_x=True).step()
    bus.ar(valid=False, valid_x=True).step()
    bus.r(valid=False, ready=False, ready_x=True).step()
    bus.aw(payload_x=True).step()
    bus.w(0, strb=0b0011, lane_x=0b0110).step().b().step()
    bus.ar().step().r(lane_x=0b1000).step()
    bus.ar(addr=0x1, size=0).step().r(lane_x=0b0001)  # lane 0 is not a lane of this read
    _, violations = _check(bus)
    assert _checks(violations) == [C.METAVALUE] * 6
    assert [v.message.split(": ")[1].split(" at ")[0] for v in violations] == [
        "metavalue on ARESETn",
        "metavalue on ARVALID",
        "metavalue on RREADY",
        "metavalue on the AW payload while AWVALID is 1",
        "metavalue on strobed WDATA lanes 0x2",
        "metavalue on RDATA lanes 0x8 of beat 0 of the read ID 0",
    ]


def test_timeouts() -> None:
    bus = Recorder()
    bus.period().ar(id=1).step().aw(ready=False).step(5).aw(ready=False).step().w(0).step(5).tick()
    checker, violations = _check(bus, timeout_cycles=4)
    messages = [v.message for v in violations]
    assert _checks(violations) == [C.TIMEOUT] * 3
    assert any("the read ID 1 at 0x0 (1 x 4 bytes) with its address handshake at 0 fs" in m for m in messages)
    assert any("AWVALID has waited for AWREADY since 10000000 fs" in m for m in messages)
    assert any("write data beat at 70000000 fs is still waiting for its AW handshake" in m for m in messages)
    checker.advance(100 * PERIOD_FS)
    assert checker.count(C.TIMEOUT) == 3  # each once


def test_a_disabled_check_neither_reports_nor_counts() -> None:
    checker = Axi4ProtocolChecker(Axi4Config(id_width=4))
    checker.disable("axi4_wlast", "BURST_4K")
    assert not checker.is_enabled(C.WLAST)
    bus = Recorder()
    bus.period().aw(addr=0xFFC, len=1).step().w(0).step().w(1).step().b()
    violations: list[Axi4Violation] = []
    checker.violations.subscribe(violations.append)
    checker.feed(*bus.take())
    assert violations == [] and checker.count("WLAST") == 0
    checker.enable(C.WLAST)
    assert checker.is_enabled("wlast")


def test_unknown_and_monitor_checks_are_rejected() -> None:
    checker = Axi4ProtocolChecker()
    with pytest.raises(Axi4ValueError, match="Unknown AXI4 check"):
        checker.disable("AXI4_NOPE")
    with pytest.raises(Axi4ValueError, match="check of the monitor"):
        checker.count(C.SCOREBOARD)
    assert C.SCOREBOARD not in PROTOCOL_CHECKS


def test_lite_exokay_is_a_violation() -> None:
    bus = Recorder(data_width=32, id_width=0)
    bus.period().ar().step().r(resp=1)
    _, violations = _check(bus, lite=True)
    assert _checks(violations) == [C.EXCL]


def test_reset_clears_counts_and_history() -> None:
    bus = Recorder()
    bus.period().aw(ready=False)
    checker, _ = _check(bus)
    bus.step().aw(valid=False, ready=False)
    checker.reset()
    checker.feed(*bus.take())
    assert checker.count(C.VALID_DROP) == 0
