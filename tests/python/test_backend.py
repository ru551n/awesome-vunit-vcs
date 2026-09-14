"""The VHDL-facing backends, driven the way the VHDL components drive them."""

import numpy as np
import pytest
from helpers import GmiiLine, ethernet_payload, reference_frame

from awesome_vunit_vcs.common.reports import Severity, decode_reports
from awesome_vunit_vcs.common.vunit_bridge import encode_samples, split_time
from awesome_vunit_vcs.ethernet.vunit_backend import STATISTICS_FIELDS, MonitorBackend, SourceBackend


def push_line(backend: MonitorBackend, line: GmiiLine) -> int:
    base = line.times[0]
    return backend.push(encode_samples(line.words, line.times, base), *split_time(base))


def test_monitor_backend_reports_violations_as_errors() -> None:
    backend = MonitorBackend("tb:gmii_monitor_0", "gmii")
    line = GmiiLine(time_fs=5 << 40)
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    line.frame(reference_frame(ethernet_payload(60), bad_fcs=True))
    assert push_line(backend, line) == 1
    reports = decode_reports(backend.take_reports())
    assert [report.severity for report in reports] == [Severity.ERROR]
    assert reports[0].message.startswith("ETH_FCS: bad FCS on frame 1")
    assert backend.take_reports() == ""
    assert backend.frame_count() == 2
    assert backend.good_frame_count() == 1
    assert backend.check_count("ETH_FCS") == 1
    assert backend.last_payload_hex() == ethernet_payload(60).hex()


def test_disabled_check_and_unknown_check() -> None:
    backend = MonitorBackend("m", "gmii")
    backend.set_check_enabled("ETH_FCS", False)
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60), bad_fcs=True))
    assert push_line(backend, line) == 0
    with pytest.raises(ValueError, match="Unknown Ethernet check"):
        backend.set_check_enabled("ETH_BOGUS", False)


def test_bad_batch_becomes_a_failure_report_not_an_exception() -> None:
    backend = MonitorBackend("m", "gmii")
    assert backend.push(np.array([1, 2, 3], dtype=np.int32), 0, 0) == 1
    report = decode_reports(backend.take_reports())[0]
    assert report.severity is Severity.FAILURE
    assert "could not process samples" in report.message


def test_broken_subscriber_becomes_a_failure_report() -> None:
    backend = MonitorBackend("m", "gmii")

    def broken(_: object) -> None:
        raise RuntimeError("user callback bug")

    backend.monitor.frames.subscribe(broken)
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    assert push_line(backend, line) == 1
    report = decode_reports(backend.take_reports())[0]
    assert report.severity is Severity.FAILURE
    assert "user callback bug" in report.message
    assert backend.frame_count() == 1


def test_frame_logging() -> None:
    backend = MonitorBackend("m", "gmii", log_frames=True)
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    push_line(backend, line)
    report = decode_reports(backend.take_reports())[0]
    assert report.severity is Severity.DEBUG
    assert report.message.startswith("frame 0: 64 bytes, dst=02:00:00:00:00:01, fcs_ok=True")


def test_independent_backends_do_not_share_state() -> None:
    first, second = MonitorBackend("a", "gmii"), MonitorBackend("b", "gmii")
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    push_line(first, line)
    assert first.frame_count() == 1
    assert second.frame_count() == 0


def test_source_backend_from_vhdl_vector() -> None:
    backend = SourceBackend("s", "gmii")
    payload = b"\x00\x01" + ethernet_payload(58)[2:]
    frame_id = backend.queue_unsigned(int.from_bytes(payload, "big"), len(payload), fcs="bad", ifg_octets=3)
    symbols = backend.take_symbols(frame_id)
    octets = bytes(int(word) & 0xFF for word in symbols[:-3])
    assert octets[8:10] == b"\x00\x01"
    assert len(symbols) == 8 + 64 + 3


def test_unknown_interface() -> None:
    with pytest.raises(ValueError, match="Unknown Ethernet interface"):
        MonitorBackend("m", "xaui")


def test_monitor_backend_scoreboard_compares_payloads() -> None:
    backend = MonitorBackend("tb:gmii_monitor_0", "gmii")
    first, second = ethernet_payload(60), ethernet_payload(80)
    backend.expect_payload(list(first))
    backend.expect_payload(list(first))
    backend.expect_payload(list(second))
    line = GmiiLine(time_fs=1 << 40)
    line.idle(1)
    line.frame(reference_frame(first))
    line.frame(reference_frame(second))
    assert push_line(backend, line) == 1
    reports = decode_reports(backend.take_reports())
    assert reports[0].message.splitlines()[:2] == [
        "ETH_SCOREBOARD: frame 1 is not the expected frame",
        "expected length=60 bytes",
    ]
    assert backend.expected_count() == 1
    assert backend.finish() == 1
    assert "1 expected frame(s) were not received" in backend.take_reports()


def test_monitor_backend_statistics_values_are_vhdl_integers() -> None:
    backend = MonitorBackend("tb:gmii_monitor_0", "gmii")
    assert backend.statistics_values()[-4:] == [-1, -1, -1, -1]
    line = GmiiLine(time_fs=0)
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    line.frame(reference_frame(ethernet_payload(60), bad_fcs=True))
    push_line(backend, line)
    values = dict(zip(STATISTICS_FIELDS, backend.statistics_values(), strict=True))
    assert values["total_frames"] == 2
    assert values["good_frames"] == 1
    assert values["fcs_errors"] == 1
    assert values["min_frame_octets"] == 64
    assert all(isinstance(value, int) for value in values.values())


def test_monitor_backend_accepts_a_delta_unit() -> None:
    backend = MonitorBackend("tb:gmii_monitor_0", "gmii")
    line = GmiiLine(time_fs=0)
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    line.idle(1)
    samples = encode_samples(line.words, line.times, 0, delta_unit_fs=1000)
    assert backend.push(samples, 0, 0, 1000) == 0
    assert backend.good_frame_count() == 1


def test_source_backend_symbols_carry_the_options() -> None:
    backend = SourceBackend("tb:gmii_source_0", "gmii")
    data = list(ethernet_payload(60))
    symbols = backend.symbols(data, [3], fcs="bad", preamble_octets=5, ifg_octets=2)
    assert symbols.dtype == np.int32
    assert len(symbols) == 5 + 1 + 60 + 4 + 2
    assert symbols[3] & 0x200
    assert symbols[5] & 0xFF == 0xD5
    assert not symbols[-1] & 0x100
