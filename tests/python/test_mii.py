"""MII decoder and encoder tests against hand-built nibble streams (see helpers.MiiLine)."""

import numpy as np
import pytest
from helpers import (
    ERROR,
    META_DATA,
    MII_10M_PERIOD_FS,
    VALID,
    MiiLine,
    ethernet_mac_octets,
    reference_frame,
)

from awesome_vunit_vcs.ethernet import CheckId, EthernetConfig, EthernetFrame, EthernetMonitor, Violation
from awesome_vunit_vcs.ethernet.phy import MiiPhy, WireFrame, create_phy


class Recorder:
    def __init__(self, config: EthernetConfig | None = None, link_rate_bps: int = 100_000_000) -> None:
        self.monitor = EthernetMonitor(MiiPhy(link_rate_bps), config or EthernetConfig(), name="mii_monitor")
        self.frames: list[EthernetFrame] = []
        self.violations: list[Violation] = []
        self.monitor.frames.subscribe(self.frames.append)
        self.monitor.checker.violations.subscribe(self.violations.append)

    def feed(self, line: MiiLine, batch: int | None = None) -> "Recorder":
        words = np.array(line.words, dtype=np.int64)
        times = np.array(line.times, dtype=np.int64)
        step = batch or len(line.words) or 1
        for start in range(0, len(line.words), step):
            self.monitor.feed(words[start : start + step], times[start : start + step])
        return self

    def checks(self) -> list[CheckId]:
        return [violation.check for violation in self.violations]


def test_encode_is_least_significant_nibble_first() -> None:
    wire = WireFrame(octets=b"\x55\xd5\x02\x88\xb5", error_offsets=(3,), ifg_octets=2)
    expected = [0x5, 0x5, 0x5, 0xD, 0x2, 0x0, 0x8, 0x8, 0x5, 0xB]
    words = MiiPhy().encode(wire).tolist()
    assert [word & 0xF for word in words[:10]] == expected
    assert all(word & VALID for word in words[:10])
    assert [bool(word & ERROR) for word in words[:10]] == [False] * 6 + [True, True] + [False] * 2
    assert words[10:] == [0, 0, 0, 0]


def test_encoded_frame_matches_the_reference_line() -> None:
    frame = reference_frame(ethernet_mac_octets(60, seed=1))
    line = MiiLine()
    line.frame(frame, preamble_nibbles=14, ifg_octets=12)
    wire = WireFrame(octets=b"\x55" * 7 + b"\xd5" + frame, ifg_octets=12)
    assert MiiPhy().encode(wire).tolist() == line.words


@pytest.mark.parametrize("batch", [None, 1, 3, 17])
def test_frames_are_reconstructed_across_batches(batch: int | None) -> None:
    payloads = [ethernet_mac_octets(60, seed=1), ethernet_mac_octets(1514, seed=2)]
    line = MiiLine()
    line.idle(4)
    for payload in payloads:
        line.frame(reference_frame(payload), preamble_nibbles=14)
    recorder = Recorder().feed(line, batch)
    assert recorder.violations == []
    assert [frame.mac_octets for frame in recorder.frames] == payloads
    assert recorder.frames[1].ifg_octets == 12


def test_octet_time_is_the_time_of_its_first_nibble() -> None:
    line = MiiLine()
    line.idle(2)
    line.frame(reference_frame(ethernet_mac_octets(60)), preamble_nibbles=14)
    recorder = Recorder().feed(line)
    frame = recorder.frames[0]
    assert frame.phy.octet_times_fs[0] == 2 * line.period_fs
    assert frame.phy.octet_period_fs == 2 * line.period_fs


def test_odd_preamble_nibble_count_is_aligned_on_the_sfd() -> None:
    payload = ethernet_mac_octets(64, seed=3)
    line = MiiLine()
    line.idle(2)
    # 15 preamble nibbles before the SFD: one unpaired nibble ahead of 7 octets
    line.frame(reference_frame(payload), preamble_nibbles=15)
    recorder = Recorder().feed(line)
    assert recorder.violations == []
    assert recorder.frames[0].mac_octets == payload


def test_trailing_nibble_is_an_alignment_error() -> None:
    line = MiiLine()
    line.idle(2)
    line.frame(reference_frame(ethernet_mac_octets(60)), preamble_nibbles=14, extra_nibbles=(0xA,))
    recorder = Recorder().feed(line)
    assert recorder.frames[0].phy.alignment_error
    assert CheckId.TERMINATION in recorder.checks()


def test_error_on_one_nibble_marks_the_octet() -> None:
    frame = reference_frame(ethernet_mac_octets(60))
    line = MiiLine()
    line.idle(2)
    # Octet 20 of the frame is preceded by 16 preamble nibbles, so its high nibble is 16 + 41
    nibbles = [0x5] * 15 + [0xD] + [nibble for octet in frame for nibble in (octet % 16, octet // 16)]
    line.nibbles(nibbles, error_at=(16 + 41,))
    line.idle(24)
    recorder = Recorder().feed(line)
    assert recorder.frames[0].mac_error_offsets == (20,)
    assert recorder.checks() == [CheckId.PHY_ERROR]


def test_metavalue_nibble_marks_the_octet() -> None:
    line = MiiLine()
    line.idle(2)
    frame = reference_frame(ethernet_mac_octets(60))
    nibbles = [0x5] * 15 + [0xD] + [nibble for octet in frame for nibble in (octet % 16, octet // 16)]
    for index, nibble in enumerate(nibbles):
        line.cycle(nibble | VALID | (META_DATA if index == 16 + 10 else 0))
    line.idle(24)
    recorder = Recorder().feed(line)
    assert recorder.frames[0].phy.metavalue_offsets == (8 + 5,)
    assert CheckId.METAVALUE in recorder.checks()


def test_short_ifg_is_measured_in_octets() -> None:
    line = MiiLine()
    line.idle(2)
    line.frame(reference_frame(ethernet_mac_octets(60, seed=1)), preamble_nibbles=14, ifg_octets=8)
    line.frame(reference_frame(ethernet_mac_octets(60, seed=2)), preamble_nibbles=14)
    recorder = Recorder().feed(line)
    assert recorder.frames[1].ifg_octets == 8
    assert recorder.checks() == [CheckId.IFG]


def test_frame_without_sfd_is_paired_from_its_start() -> None:
    line = MiiLine()
    line.idle(2)
    line.nibbles([0x5] * 14 + [0x3, 0x2] + [0x0, 0x1] * 30)
    line.idle(24)
    recorder = Recorder().feed(line)
    assert recorder.frames[0].phy.octets[:8] == b"\x55" * 7 + b"\x23"
    assert CheckId.SFD in recorder.checks()


def test_ten_megabit_timing() -> None:
    line = MiiLine(period_fs=MII_10M_PERIOD_FS)
    line.idle(2)
    for seed in range(2):
        line.frame(reference_frame(ethernet_mac_octets(60, seed=seed)), preamble_nibbles=14)
    recorder = Recorder(link_rate_bps=10_000_000).feed(line)
    assert recorder.violations == []
    assert recorder.frames[1].ifg_octets == 12


def test_create_phy_and_link_rate() -> None:
    phy = create_phy("mii", link_rate_bps=10_000_000)
    assert isinstance(phy, MiiPhy)
    assert phy.link_rate_bps == 10_000_000
    with pytest.raises(ValueError, match="link_rate_bps"):
        MiiPhy(0)
