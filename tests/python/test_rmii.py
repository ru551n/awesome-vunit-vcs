"""RMII decoder and encoder tests against hand-built dibit streams (see helpers.RmiiLine)."""

import numpy as np
import pytest
from helpers import (
    ERROR,
    META_DATA,
    RMII_10M_PERIOD_FS,
    VALID,
    RmiiLine,
    ethernet_mac_octets,
    reference_frame,
)

import awesome_vunit_vcs.ethernet as eth
from awesome_vunit_vcs.ethernet.errors import EthernetValueError
from awesome_vunit_vcs.ethernet.lowlevel import CheckId, EthernetConfig, EthernetFrame, EthernetMonitor, Violation
from awesome_vunit_vcs.ethernet.phy import RmiiPhy, WireFrame, create_phy


class Recorder:
    def __init__(self, config: EthernetConfig | None = None, link_rate_bps: int = 100_000_000) -> None:
        self.monitor = EthernetMonitor(RmiiPhy(link_rate_bps), config or EthernetConfig(), name="rmii_monitor")
        self.frames: list[EthernetFrame] = []
        self.violations: list[Violation] = []
        self.monitor.frames.subscribe(self.frames.append)
        self.monitor.checker.violations.subscribe(self.violations.append)

    def feed(self, line: RmiiLine, batch: int | None = None) -> "Recorder":
        words = np.array(line.words, dtype=np.int64)
        times = np.array(line.times, dtype=np.int64)
        step = batch or len(line.words) or 1
        for start in range(0, len(line.words), step):
            self.monitor.feed(words[start : start + step], times[start : start + step])
        return self

    def checks(self) -> list[CheckId]:
        return [violation.check for violation in self.violations]


def test_encode_is_least_significant_dibit_first() -> None:
    wire = WireFrame(octets=b"\x55\xd5\x02\xb5", wire_error_offsets=(2,), ifg_octets=1)
    expected = [1, 1, 1, 1, 1, 1, 1, 3, 2, 0, 0, 0, 1, 1, 3, 2]
    words = RmiiPhy().encode(wire).tolist()
    assert [word & 3 for word in words[:16]] == expected
    assert all(word & VALID for word in words[:16])
    assert [bool(word & ERROR) for word in words[:16]] == [False] * 8 + [True] * 4 + [False] * 4
    assert words[16:] == [0, 0, 0, 0]


def test_encoded_frame_matches_the_reference_line() -> None:
    frame = reference_frame(ethernet_mac_octets(60, seed=1))
    line = RmiiLine()
    line.frame(frame)
    wire = WireFrame(octets=b"\x55" * 7 + b"\xd5" + frame, ifg_octets=12)
    assert RmiiPhy().encode(wire).tolist() == line.words


@pytest.mark.parametrize("batch", [None, 1, 3, 17])
def test_frames_are_reconstructed_across_batches(batch: int | None) -> None:
    payloads = [ethernet_mac_octets(60, seed=1), ethernet_mac_octets(1514, seed=2)]
    line = RmiiLine()
    line.idle(4)
    for payload in payloads:
        line.frame(reference_frame(payload))
    recorder = Recorder().feed(line, batch)
    assert recorder.violations == []
    assert [frame.mac_octets for frame in recorder.frames] == payloads
    assert recorder.frames[1].ifg_octets == 12


def test_octet_time_is_the_time_of_its_first_dibit() -> None:
    line = RmiiLine(period_fs=RMII_10M_PERIOD_FS)
    line.idle(2)
    line.frame(reference_frame(ethernet_mac_octets(60)))
    recorder = Recorder(link_rate_bps=10_000_000).feed(line)
    frame = recorder.frames[0]
    assert frame.phy.octet_times_fs[0] == 2 * line.period_fs
    assert frame.phy.octet_period_fs == 4 * line.period_fs


def test_zero_dibits_before_the_preamble_are_dropped() -> None:
    payload = ethernet_mac_octets(64, seed=3)
    line = RmiiLine()
    line.idle(2)
    line.frame(reference_frame(payload), leading_zero_dibits=7)
    recorder = Recorder().feed(line)
    assert recorder.violations == []
    assert recorder.frames[0].mac_octets == payload


@pytest.mark.parametrize("preamble_dibits", [29, 30, 32, 33])
def test_preamble_dibit_count_is_aligned_on_the_sfd(preamble_dibits: int) -> None:
    payload = ethernet_mac_octets(64, seed=4)
    line = RmiiLine()
    line.idle(2)
    line.frame(reference_frame(payload), preamble_dibits=preamble_dibits)
    recorder = Recorder(EthernetConfig(min_preamble_octets=6, max_preamble_octets=8)).feed(line)
    assert recorder.violations == []
    assert recorder.frames[0].mac_octets == payload


def test_toggling_crs_dv_still_carries_data() -> None:
    frame = reference_frame(ethernet_mac_octets(60, seed=5))
    dibits = [1] * 31 + [3] + RmiiLine.octet_dibits(frame)
    # The carrier ends three octets before the data: CRS_DV is low on the first dibit of every nibble
    low = tuple(index for index in range(len(dibits) - 12, len(dibits)) if (index - len(dibits)) % 2 == 0)
    line = RmiiLine()
    line.idle(2)
    line.dibits(dibits, valid_low_at=low)
    line.idle(48)
    recorder = Recorder().feed(line)
    assert recorder.violations == []
    assert recorder.frames[0].mac_octets == frame[:-4]


@pytest.mark.parametrize("batch", [None, 1, 2, 5])
def test_encoder_toggles_crs_dv_and_decodes_unchanged(batch: int | None) -> None:
    frames = [eth.Frame.from_payload(bytes(range(46))), eth.Frame.from_payload(bytes(range(100)))]
    interface = eth.Interface("rmii", 100_000_000, crs_dv_toggle_octets=3)
    samples = interface.encode(frames)
    valid = (samples.words & VALID) != 0
    assert not valid.all() and valid.any()
    words = samples.words.tolist()
    step = batch or len(words)
    with eth.Monitor(interface) as monitor:
        received = []
        for start in range(0, len(words), step):
            part = eth.Samples.from_arrays(words[start : start + step], samples.times.tolist()[start : start + step])
            received += monitor.feed(part)
        assert monitor.violations == []
    assert [frame.payload for frame in received] == [frame.payload for frame in frames]


def test_trailing_dibit_is_an_alignment_error() -> None:
    line = RmiiLine()
    line.idle(2)
    line.frame(reference_frame(ethernet_mac_octets(60)), extra_dibits=(2, 1))
    recorder = Recorder().feed(line)
    assert recorder.frames[0].phy.alignment_error
    assert CheckId.TERMINATION in recorder.checks()


def test_error_on_one_dibit_marks_the_octet() -> None:
    frame = reference_frame(ethernet_mac_octets(60))
    dibits = [1] * 31 + [3] + RmiiLine.octet_dibits(frame)
    line = RmiiLine()
    line.idle(2)
    # Octet 20 of the frame starts after the 32 preamble and SFD dibits; its third dibit is errored
    line.dibits(dibits, error_at=(32 + 4 * 20 + 2,))
    line.idle(48)
    recorder = Recorder().feed(line)
    assert recorder.frames[0].mac_error_offsets == (20,)
    assert recorder.checks() == [CheckId.PHY_ERROR]


def test_metavalue_dibit_marks_the_octet() -> None:
    frame = reference_frame(ethernet_mac_octets(60))
    dibits = [1] * 31 + [3] + RmiiLine.octet_dibits(frame)
    line = RmiiLine()
    line.idle(2)
    for index, dibit in enumerate(dibits):
        line.cycle(dibit | VALID | (META_DATA if index == 32 + 4 * 10 else 0))
    line.idle(48)
    recorder = Recorder().feed(line)
    assert CheckId.METAVALUE in recorder.checks()


def test_create_phy_and_interface() -> None:
    assert isinstance(create_phy("rmii", link_rate_bps=10_000_000), RmiiPhy)
    assert eth.RMII.clock_period_fs == eth.fs("20 ns")
    assert eth.RMII.with_rate("10M").clock_period_fs == eth.fs("200 ns")
    with pytest.raises(EthernetValueError):
        eth.RMII.with_rate("1G")
    with pytest.raises(EthernetValueError):
        eth.Interface("mii", 100_000_000, crs_dv_toggle_octets=1)
    with pytest.raises(EthernetValueError):
        RmiiPhy(crs_dv_toggle_octets=-1)
