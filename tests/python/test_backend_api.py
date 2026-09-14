"""The Python API of the monitor backend: vc.on_frame, vc.frames, vc.statistics and vc.error."""

from __future__ import annotations

import runpy
from pathlib import Path

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.common.reports import Severity, decode_reports
from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend

EXAMPLE = Path(__file__).resolve().parents[2] / "examples" / "gmii" / "python" / "frame_sizes.py"


def feed(backend: MonitorBackend, frames: list[eth.Frame]) -> None:
    samples = eth.GMII.encode(frames)
    backend.monitor.feed(samples.words, samples.times)


def test_on_frame_delivers_frames_and_logs_subscriber_exceptions() -> None:
    backend = MonitorBackend("rx", "gmii")
    seen: list[eth.Frame] = []

    @backend.on_frame
    def record(frame: eth.Frame) -> None:
        seen.append(frame)

    @backend.on_frame
    def broken(frame: eth.Frame) -> None:
        raise RuntimeError("subscriber bug")

    frame = eth.Frame.from_payload(bytes(80))
    feed(backend, [frame])
    assert seen == [frame] and backend.frames == [frame]
    reports = decode_reports(backend.take_reports())
    assert [report.severity for report in reports] == [Severity.FAILURE]
    assert "broken" in reports[0].message and "subscriber bug" in reports[0].message


def test_error_is_a_counted_check_error() -> None:
    backend = MonitorBackend("rx", "gmii", checks=False)
    backend.error("ETH_SCOREBOARD", "frame 0 is wrong\nexpected=1\nreceived=2")
    reports = decode_reports(backend.take_reports())
    assert [(report.severity, report.message.splitlines()[0]) for report in reports] == [
        (Severity.ERROR, "ETH_SCOREBOARD: frame 0 is wrong")
    ]
    assert backend.check_count("ETH_SCOREBOARD") == 1
    backend.set_check_enabled("ETH_SCOREBOARD", False)
    backend.error("ETH_SCOREBOARD", "not counted")
    backend.error("ETH_FCS", "disabled in a monitor without protocol checks")
    assert backend.check_count("ETH_SCOREBOARD") == 1 and backend.take_reports() == ""


def test_statistics_is_a_property_that_still_calls() -> None:
    backend = MonitorBackend("rx", "gmii")
    feed(backend, [eth.Frame.from_payload(bytes(60))] * 3)
    assert backend.statistics.total_frames == 3
    assert backend.statistics() == backend.statistics
    assert backend.good_frame_count() == 3 and backend.statistics_values()[0] == 3


def test_the_simulation_subscriber_example() -> None:
    backend = MonitorBackend("rx", "gmii", checks=False)
    namespace = runpy.run_path(str(EXAMPLE), init_globals={"vc": backend})
    feed(backend, [eth.Frame.from_payload(bytes(46)), eth.Frame.from_payload(bytes(186)), eth.Frame(bytes(1600))])
    assert namespace["frame_sizes"] == [60, 200, 1596]
    reports = decode_reports(backend.take_reports())
    assert [report.severity for report in reports] == [Severity.ERROR]
    assert backend.check_count("ETH_SCOREBOARD") == 1
