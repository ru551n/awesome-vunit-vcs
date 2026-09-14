import numpy as np
import pytest
from helpers import GMII_PERIOD_FS, GmiiLine, ethernet_payload, reference_frame

from awesome_vunit_vcs.ethernet import EthernetMonitor
from awesome_vunit_vcs.ethernet.phy import GmiiPhy


def monitor_for(line: GmiiLine) -> EthernetMonitor:
    monitor = EthernetMonitor(GmiiPhy(), name="gmii")
    monitor.feed(np.array(line.words, dtype=np.int64), np.array(line.times, dtype=np.int64))
    return monitor


def test_statistics_of_known_traffic() -> None:
    line = GmiiLine()
    line.idle(1)
    sizes = [64, 128, 1518]
    for size in sizes:
        line.frame(reference_frame(ethernet_payload(size - 4)), ifg=20)
    line.frame(reference_frame(ethernet_payload(60), bad_fcs=True), ifg=12)
    stats = monitor_for(line).statistics.snapshot()

    assert stats.total_frames == 4
    assert stats.good_frames == 3
    assert stats.bad_frames == 1
    assert stats.fcs_errors == 1
    assert stats.frame_octets == sum(sizes) + 64
    assert stats.wire_octets == stats.frame_octets + 4 * 8
    assert stats.payload_octets == sum(size - 18 for size in sizes) + 46
    assert stats.frame_size.minimum == 64
    assert stats.frame_size.maximum == 1518
    assert stats.ifg_octets.minimum == 20
    assert stats.ifg_octets.maximum == 20
    assert dict(stats.size_histogram) == {
        "<64": 0, "64": 2, "65-127": 0, "128-255": 1, "256-511": 0, "512-1023": 0, "1024-1518": 1, ">1518": 0,
    }

    # Window: first frame start to end of the last frame (first idle cycle)
    wire_and_gaps = stats.wire_octets + 3 * 20
    assert stats.duration_fs == wire_and_gaps * GMII_PERIOD_FS
    assert stats.link_utilization == pytest.approx(stats.wire_octets / wire_and_gaps)
    assert stats.bit_rate_bps == pytest.approx(8 * stats.frame_octets * 1e15 / stats.duration_fs)
    assert stats.frames_per_second == pytest.approx(4 * 1e15 / stats.duration_fs)


def test_summary_is_readable_and_empty_statistics_do_not_divide_by_zero() -> None:
    monitor = EthernetMonitor(GmiiPhy(), name="gmii_monitor_0")
    empty = monitor.statistics.snapshot()
    assert empty.link_utilization is None
    assert "frames: total=0" in empty.summary("gmii_monitor_0")

    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    text = monitor_for(line).statistics.snapshot().summary("gmii_monitor_0")
    assert text.splitlines()[0] == "gmii_monitor_0 statistics"
    assert "utilization: link" in text


def test_reset() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_payload(60)))
    monitor = monitor_for(line)
    monitor.statistics.reset()
    assert monitor.statistics.snapshot().total_frames == 0
