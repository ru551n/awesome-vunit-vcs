"""GMII monitor pipeline tests: the numbered GMII scenarios, simulator independent."""

import random

import numpy as np
import pytest
from helpers import ERROR, GMII_PERIOD_FS, META_CTRL, META_DATA, VALID, GmiiLine, ethernet_mac_octets, reference_frame

from awesome_vunit_vcs.ethernet import CheckId, EthernetConfig, EthernetFrame, EthernetMonitor, Violation
from awesome_vunit_vcs.ethernet.phy import GmiiPhy


class Recorder:
    def __init__(self, config: EthernetConfig | None = None) -> None:
        self.monitor = EthernetMonitor(GmiiPhy(), config, name="gmii_monitor_0")
        self.frames: list[EthernetFrame] = []
        self.violations: list[Violation] = []
        self.monitor.frames.subscribe(self.frames.append)
        self.monitor.checker.violations.subscribe(self.violations.append)

    def feed(self, line: GmiiLine, batch: int | None = None) -> None:
        words = np.array(line.words, dtype=np.int64)
        times = np.array(line.times, dtype=np.int64)
        step = batch or len(words) or 1
        for start in range(0, len(words), step):
            self.monitor.feed(words[start : start + step], times[start : start + step])

    def checks(self) -> list[CheckId]:
        return [violation.check for violation in self.violations]


def run(line: GmiiLine, config: EthernetConfig | None = None, batch: int | None = None) -> Recorder:
    recorder = Recorder(config)
    recorder.feed(line, batch)
    return recorder


def test_valid_minimum_size_frame() -> None:
    payload = ethernet_mac_octets(60)
    line = GmiiLine()
    line.idle(4)
    line.frame(reference_frame(payload))
    recorder = run(line)
    assert len(recorder.frames) == 1
    frame = recorder.frames[0]
    assert frame.mac_octets == payload
    assert frame.mac is not None and frame.mac.size_with_fcs == 64
    assert frame.is_good
    assert recorder.violations == []


def test_valid_larger_frame() -> None:
    payload = ethernet_mac_octets(1514, seed=9)
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(payload))
    recorder = run(line)
    assert recorder.frames[0].mac_octets == payload
    assert recorder.frames[0].mac.size_with_fcs == 1518  # type: ignore[union-attr]
    assert recorder.violations == []


def test_preamble_and_sfd_timestamps() -> None:
    line = GmiiLine(time_fs=1_000_000_000)
    line.idle(3)
    line.frame(reference_frame(ethernet_mac_octets(60)))
    frame = run(line).frames[0]
    start = 1_000_000_000 + 3 * GMII_PERIOD_FS
    assert frame.preamble_octets == 7
    assert frame.sfd_offset == 7
    assert frame.timestamp_start_fs == start
    assert frame.timestamp_sfd_fs == start + 7 * GMII_PERIOD_FS
    assert frame.timestamp_mac_fs == start + 8 * GMII_PERIOD_FS
    assert frame.timestamp_end_fs == start + (8 + 64) * GMII_PERIOD_FS


def test_fcs_pass() -> None:
    line = GmiiLine()
    line.idle(1)
    for seed in range(5):
        line.frame(reference_frame(ethernet_mac_octets(100 + seed, seed=seed)))
    recorder = run(line)
    assert [frame.fcs_ok for frame in recorder.frames] == [True] * 5


def test_bad_fcs_message() -> None:
    line = GmiiLine()
    line.idle(1)
    payload = ethernet_mac_octets(124)
    line.frame(reference_frame(payload))
    line.frame(reference_frame(payload, bad_fcs=True))
    recorder = run(line)
    assert recorder.checks() == [CheckId.FCS]
    good = recorder.frames[0].mac
    assert good is not None
    expected = good.fcs_received
    sfd_time = recorder.frames[1].timestamp_sfd_fs
    assert recorder.violations[0].message == (
        f"ETH_FCS: bad FCS on frame 1\n"
        f"expected=0x{expected:08X}\n"
        f"received=0x{expected ^ 0x10000000:08X}\n"
        f"SFD time={sfd_time} fs\n"
        f"length=128 octets"
    )


def test_runt_frame() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(20), pad_to=0))
    recorder = run(line)
    assert recorder.checks() == [CheckId.RUNT]
    assert recorder.frames[0].is_runt


def test_oversized_frame_with_configured_maximum() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(1518)))
    assert run(line).checks() == [CheckId.GIANT]
    assert run(line, EthernetConfig(max_frame_octets=1522)).checks() == []


def test_phy_error_offsets() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), error_offsets=(20,))
    recorder = run(line)
    assert recorder.checks() == [CheckId.PHY_ERROR]
    frame = recorder.frames[0]
    assert frame.phy.wire_error_offsets == (20,)
    assert frame.error_offsets == (12,)
    assert frame.mac_error_offsets == (12,)
    assert "frame offsets=12" in recorder.violations[0].message


def test_legal_ifg() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), ifg=12)
    line.frame(reference_frame(ethernet_mac_octets(60)), ifg=12)
    recorder = run(line)
    assert recorder.violations == []
    assert recorder.frames[1].ifg_octets == 12
    assert recorder.frames[1].ifg_fs == 12 * GMII_PERIOD_FS


def test_too_short_ifg() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), ifg=11)
    line.frame(reference_frame(ethernet_mac_octets(60)))
    recorder = run(line)
    assert recorder.checks() == [CheckId.IFG]
    assert "is 11 octets" in recorder.violations[0].message


def test_back_to_back_frames() -> None:
    line = GmiiLine()
    line.idle(1)
    payloads = [ethernet_mac_octets(60 + index, seed=index) for index in range(4)]
    for payload in payloads:
        line.frame(reference_frame(payload), ifg=12)
    recorder = run(line)
    assert [frame.mac_octets for frame in recorder.frames] == payloads
    assert [frame.ifg_octets for frame in recorder.frames] == [None, 12, 12, 12]


def test_frames_without_gap_merge_and_are_reported() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), ifg=0)
    line.frame(reference_frame(ethernet_mac_octets(60)))
    recorder = run(line)
    # Without a single idle cycle GMII cannot separate the frames
    assert len(recorder.frames) == 1
    assert CheckId.FCS in recorder.checks()


@pytest.mark.parametrize(
    ("preamble", "check"),
    [
        (b"\x55" * 5 + b"\xd5", CheckId.PREAMBLE),
        (b"\x55" * 7 + b"\x5d", CheckId.SFD),
        (b"\xd5", CheckId.PREAMBLE),
        (b"\x55" * 3 + b"\x57" + b"\x55" * 3 + b"\xd5", CheckId.SFD),
    ],
)
def test_malformed_preamble_and_sfd(preamble: bytes, check: CheckId) -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), preamble=preamble)
    assert check in run(line).checks()


def test_preamble_tolerance() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60)), preamble=b"\x55" * 5 + b"\xd5")
    assert run(line, EthernetConfig(min_preamble_octets=5)).checks() == []


def test_frame_ending_in_preamble() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(b"", preamble=b"\x55" * 4)
    recorder = run(line)
    assert recorder.checks() == [CheckId.PREAMBLE, CheckId.SFD] or recorder.checks() == [CheckId.SFD]
    assert "received=end of frame" in recorder.violations[-1].message


def test_disabled_check_is_silent_and_not_counted() -> None:
    line = GmiiLine()
    line.idle(1)
    line.frame(reference_frame(ethernet_mac_octets(60), bad_fcs=True))
    recorder = Recorder()
    recorder.monitor.checker.disable("ETH_FCS")
    recorder.feed(line)
    assert recorder.violations == []
    assert recorder.monitor.checker.count(CheckId.FCS) == 0
    assert recorder.monitor.statistics.snapshot().fcs_errors == 1


def test_unknown_check_name() -> None:
    with pytest.raises(ValueError, match="Unknown Ethernet check"):
        Recorder().monitor.checker.disable("ETH_NOPE")


def test_metavalues_are_reported() -> None:
    line = GmiiLine()
    line.idle(1)
    line.cycle(META_CTRL)
    for octet in b"\x55" * 7 + b"\xd5":
        line.cycle(octet | VALID)
    frame = reference_frame(ethernet_mac_octets(60))
    for offset, octet in enumerate(frame):
        line.cycle(octet | VALID | (META_DATA if offset == 3 else 0))
    line.idle(2)
    recorder = run(line)
    assert recorder.checks().count(CheckId.METAVALUE) == 2


def test_error_outside_frame_is_carrier_violation() -> None:
    line = GmiiLine()
    line.idle(1)
    line.cycle(0x0E | ERROR)
    line.idle(1)
    recorder = run(line)
    assert recorder.checks() == [CheckId.CARRIER]
    assert "data=0x0E" in recorder.violations[0].message


def test_monitor_started_inside_frame() -> None:
    line = GmiiLine()
    for octet in reference_frame(ethernet_mac_octets(60)):
        line.cycle(octet | VALID)
    line.idle(1)
    assert CheckId.FRAME_STATE in run(line).checks()


def test_unfinished_frame_at_end() -> None:
    line = GmiiLine()
    line.idle(1)
    for octet in b"\x55" * 7 + b"\xd5" + b"\x00" * 10:
        line.cycle(octet | VALID)
    recorder = run(line)
    assert recorder.frames == []
    recorder.monitor.finish(line.time_fs)
    assert recorder.checks() == [CheckId.FRAME_STATE]


@pytest.mark.parametrize("batch", [1, 2, 7, 64, 1000])
def test_batching_does_not_change_the_result(batch: int) -> None:
    rng = random.Random(1234)
    line = GmiiLine()
    line.idle(2)
    for index in range(20):
        line.frame(reference_frame(ethernet_mac_octets(rng.randrange(46, 1500), seed=index)), ifg=rng.randrange(12, 40))
    reference = run(line)
    batched = run(line, batch=batch)
    assert [f.mac_octets for f in batched.frames] == [f.mac_octets for f in reference.frames]
    assert [f.timestamp_sfd_fs for f in batched.frames] == [f.timestamp_sfd_fs for f in reference.frames]
    assert [f.ifg_octets for f in batched.frames] == [f.ifg_octets for f in reference.frames]


def test_long_randomized_traffic_sequence() -> None:
    rng = random.Random(20260914)
    line = GmiiLine()
    line.idle(3)
    expected = []
    for index in range(300):
        length = rng.choice([60, 61, 128, 512, 1000, 1514, rng.randrange(60, 1515)])
        payload = ethernet_mac_octets(length, seed=index)
        bad = rng.random() < 0.05
        error = (rng.randrange(8, 8 + length),) if rng.random() < 0.03 else ()
        line.frame(reference_frame(payload, bad_fcs=bad), error_offsets=error, ifg=rng.randrange(12, 100))
        expected.append((payload, not bad, bool(error)))
    recorder = run(line, batch=257)
    assert [(f.mac_octets, f.fcs_ok, f.has_phy_error) for f in recorder.frames] == expected
    stats = recorder.monitor.statistics.snapshot()
    assert stats.total_frames == 300
    assert stats.fcs_errors == sum(1 for _, ok, _ in expected if not ok)
    assert stats.good_frames == sum(1 for _, ok, err in expected if ok and not err)
