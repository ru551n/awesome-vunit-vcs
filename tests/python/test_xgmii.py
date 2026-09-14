"""XGMII decoder and encoder tests against hand-built columns (see helpers.XgmiiLine)."""

import numpy as np
import pytest
from helpers import (
    XGMII_10G_OCTET_FS,
    XGMII_CONTROL,
    XGMII_ERROR,
    XGMII_IDLE,
    XGMII_SEQUENCE,
    XGMII_START,
    XGMII_TERMINATE,
    XgmiiLine,
    ethernet_mac_octets,
    reference_frame,
)

from awesome_vunit_vcs.ethernet import CheckId, EthernetConfig, EthernetFrame, EthernetMonitor, Violation
from awesome_vunit_vcs.ethernet.phy import WireFrame, XgmiiPhy, create_phy
from awesome_vunit_vcs.ethernet.source import build_wire_frame


class Recorder:
    def __init__(self, lanes: int = 4, config: EthernetConfig | None = None, **options: object) -> None:
        self.phy = XgmiiPhy(lanes=lanes, **options)  # type: ignore[arg-type]
        self.monitor = EthernetMonitor(self.phy, config or EthernetConfig(min_ifg_octets=5), name="xgmii_monitor")
        self.frames: list[EthernetFrame] = []
        self.violations: list[Violation] = []
        self.monitor.frames.subscribe(self.frames.append)
        self.monitor.checker.violations.subscribe(self.violations.append)

    def feed(self, words: list[int], times: list[int], batch: int | None = None) -> None:
        word_array = np.array(words, dtype=np.int64)
        time_array = np.array(times, dtype=np.int64)
        step = batch or len(words) or 1
        for start in range(0, len(words), step):
            self.monitor.feed(word_array[start : start + step], time_array[start : start + step])

    def checks(self) -> list[CheckId]:
        return [violation.check for violation in self.violations]


def run(line: XgmiiLine, batch: int | None = None, **options: object) -> Recorder:
    recorder = Recorder(line.lanes, **options)  # type: ignore[arg-type]
    recorder.feed(line.words, line.times, batch)
    return recorder


@pytest.mark.parametrize("lanes", [4, 8])
def test_terminate_on_every_lane(lanes: int) -> None:
    line = XgmiiLine(lanes=lanes)
    line.idle_columns(2)
    payloads = [ethernet_mac_octets(60 + extra, seed=extra) for extra in range(lanes)]
    for payload in payloads:
        line.frame(reference_frame(payload), idle_columns=2)
    recorder = run(line)
    assert recorder.violations == []
    assert [frame.mac_octets for frame in recorder.frames] == payloads
    for frame in recorder.frames:
        # Start replaces the first of the seven preamble octets
        assert frame.preamble_octets == 7
        assert frame.is_good


@pytest.mark.parametrize("batch", [1, 3, 5, 64])
def test_batches_split_columns_anywhere(batch: int) -> None:
    line = XgmiiLine(lanes=8)
    for seed in range(3):
        line.frame(reference_frame(ethernet_mac_octets(100 + seed, seed)))
    recorder = run(line, batch=batch)
    assert len(recorder.frames) == 3
    assert recorder.violations == []


def test_ifg_counts_terminate_and_idles() -> None:
    line = XgmiiLine(lanes=4)
    line.frame(reference_frame(ethernet_mac_octets(60)), idle_columns=2)
    line.frame(reference_frame(ethernet_mac_octets(60)), idle_columns=0)
    recorder = run(line)
    # 1 + 7 + 64 = 72 octets end on lane 3 of a column: T and 3 idles fill the next one
    first_gap, second_gap = recorder.frames[1].ifg_octets, 4
    assert first_gap == 4 + 8
    assert recorder.frames[1].ifg_fs == 12 * XGMII_10G_OCTET_FS
    line = XgmiiLine(lanes=4)
    line.frame(reference_frame(ethernet_mac_octets(60)), idle_columns=0)
    line.frame(reference_frame(ethernet_mac_octets(60)))
    recorder = run(line)
    assert recorder.frames[1].ifg_octets == second_gap
    assert recorder.checks() == [CheckId.IFG]


def test_error_character_in_frame() -> None:
    line = XgmiiLine()
    line.frame(reference_frame(ethernet_mac_octets(60)), error_offsets=(20,))
    recorder = run(line)
    assert CheckId.PHY_ERROR in recorder.checks()
    assert CheckId.FCS in recorder.checks()
    assert recorder.frames[0].phy.error_offsets == (21,)


def test_error_character_outside_frame() -> None:
    line = XgmiiLine()
    line.control(XGMII_ERROR)
    line.fill_column()
    recorder = run(line)
    assert recorder.checks() == [CheckId.CARRIER]


def test_start_on_wrong_lane() -> None:
    line = XgmiiLine()
    line.control(XGMII_IDLE)
    line.control(XGMII_START)
    line.data(b"\x55" * 6 + b"\xd5" + reference_frame(ethernet_mac_octets(60)))
    line.control(XGMII_TERMINATE)
    line.fill_column()
    recorder = run(line)
    assert recorder.checks() == [CheckId.CONTROL]
    assert "lane 1" in recorder.violations[0].message
    assert recorder.frames[0].is_good


def test_lane4_start_when_allowed() -> None:
    line = XgmiiLine(lanes=8)
    for _ in range(4):
        line.control(XGMII_IDLE)
    line.control(XGMII_START)
    line.data(b"\x55" * 6 + b"\xd5" + reference_frame(ethernet_mac_octets(60)))
    line.control(XGMII_TERMINATE)
    line.fill_column()
    assert run(line, allow_lane4_start=True).violations == []
    assert run(line).checks() == [CheckId.CONTROL]


def test_missing_terminate() -> None:
    line = XgmiiLine()
    line.frame(reference_frame(ethernet_mac_octets(60)), terminate=False)
    recorder = run(line)
    assert recorder.checks() == [CheckId.TERMINATION]
    assert len(recorder.frames) == 1


def test_start_inside_frame() -> None:
    line = XgmiiLine()
    line.control(XGMII_START)
    line.data(b"\x55" * 6 + b"\xd5" + bytes(9))
    line.fill_column()
    line.frame(reference_frame(ethernet_mac_octets(60)))
    recorder = run(line)
    assert recorder.checks()[0] == CheckId.TERMINATION
    assert recorder.frames[-1].is_good


def test_unknown_control_character_and_stray_terminate() -> None:
    line = XgmiiLine()
    line.control(0x1C)
    line.control(XGMII_TERMINATE)
    line.fill_column()
    recorder = run(line)
    assert recorder.checks() == [CheckId.CONTROL, CheckId.CONTROL]


def test_data_outside_frame_reported_once_per_run() -> None:
    line = XgmiiLine()
    line.data(bytes([1, 2, 3]))
    line.fill_column()
    recorder = run(line)
    assert recorder.checks() == [CheckId.CONTROL]


@pytest.mark.parametrize(("value", "name"), [(0x000001, "local fault"), (0x000002, "remote fault")])
def test_link_fault_reported_once_per_onset(value: int, name: str) -> None:
    line = XgmiiLine()
    for _ in range(5):
        line.control(XGMII_SEQUENCE)
        line.data(value.to_bytes(3, "big"))
    line.idle_columns(1)
    line.control(XGMII_SEQUENCE)
    line.data(value.to_bytes(3, "big"))
    recorder = run(line)
    assert recorder.checks() == [CheckId.LINK_FAULT, CheckId.LINK_FAULT]
    assert name in recorder.violations[0].message


def test_reserved_ordered_set_and_wrong_lane() -> None:
    line = XgmiiLine()
    line.control(XGMII_SEQUENCE)
    line.data(bytes([0x12, 0x34, 0x56]))
    line.control(XGMII_IDLE)
    line.control(XGMII_SEQUENCE)
    line.data(bytes([0, 0]))
    # An Idle before the third ordered set octet leaves it incomplete
    line.idle_columns(1)
    recorder = run(line)
    assert recorder.checks() == [CheckId.CONTROL, CheckId.CONTROL, CheckId.CONTROL]


def test_metavalue_in_frame() -> None:
    line = XgmiiLine()
    line.control(XGMII_START)
    line.data(b"\x55" * 6 + b"\xd5" + reference_frame(ethernet_mac_octets(60))[:10])
    line.lane_word(0x00 | (1 << 10))
    line.data(reference_frame(ethernet_mac_octets(60))[11:])
    line.control(XGMII_TERMINATE)
    line.fill_column()
    recorder = run(line)
    assert CheckId.METAVALUE in recorder.checks()


@pytest.mark.parametrize("lanes", [4, 8])
def test_encoder_alignment_and_round_trip(lanes: int) -> None:
    phy = XgmiiPhy(lanes=lanes)
    words: list[int] = []
    payloads = [ethernet_mac_octets(60 + seed, seed) for seed in range(20)]
    for payload in payloads:
        symbols = phy.encode(build_wire_frame(payload, ifg_octets=12))
        assert symbols.size % lanes == 0
        assert symbols[0] == XGMII_START | XGMII_CONTROL
        words.extend(symbols.tolist())
    times = [(index // lanes) * lanes * XGMII_10G_OCTET_FS for index in range(len(words))]
    recorder = Recorder(lanes)
    recorder.feed(words, times)
    assert recorder.violations == []
    assert [frame.mac_octets for frame in recorder.frames] == [reference_frame(p)[:-4] for p in payloads]
    gaps = [frame.ifg_octets for frame in recorder.frames[1:]]
    assert all(gap is not None and 12 - (lanes - 1) <= gap <= 12 + lanes - 1 for gap in gaps)
    # The deficit keeps the average close to the requested gap
    assert abs(sum(gaps) / len(gaps) - 12) < lanes / len(gaps) + 1  # type: ignore[arg-type]


def test_encoder_matches_hand_built_columns() -> None:
    frame = reference_frame(ethernet_mac_octets(60))
    line = XgmiiLine(lanes=4)
    line.frame(frame, idle_columns=2)
    phy = XgmiiPhy(lanes=4, deficit_idle=False)
    # 72 octets end a column: T and three idles, then two idle columns
    symbols = phy.encode(WireFrame(b"\x55" * 7 + b"\xd5" + frame, ifg_octets=12))
    assert symbols.tolist() == line.words


def test_encoder_error_offsets_and_short_gap() -> None:
    phy = XgmiiPhy(lanes=8, deficit_idle=False)
    symbols = phy.encode(WireFrame(bytes(76), error_offsets=(10,), ifg_octets=1)).tolist()
    assert symbols[10] == XGMII_ERROR | XGMII_CONTROL
    assert symbols[76] == XGMII_TERMINATE | XGMII_CONTROL
    assert len(symbols) == 80


def test_ordered_set_and_raw_columns() -> None:
    phy = XgmiiPhy(lanes=8)
    column = phy.ordered_set_symbols(0x000002, columns=2).tolist()
    assert column[:8] == [XGMII_SEQUENCE | XGMII_CONTROL, 0, 0, 2] + [XGMII_IDLE | XGMII_CONTROL] * 4
    assert len(column) == 16
    raw = phy.column_symbols([0xFB, 1, 2, 3, 4, 5, 6, 7], [1, 0, 0, 0, 0, 0, 0, 0]).tolist()
    assert raw[0] == XGMII_START | XGMII_CONTROL
    with pytest.raises(ValueError, match="multiple of 8"):
        phy.column_symbols([1], [0])


def test_create_phy_options() -> None:
    phy = create_phy("xgmii", link_rate_bps=25_000_000_000, lanes=8)
    assert isinstance(phy, XgmiiPhy)
    assert phy.octet_period_fs == 320_000
    with pytest.raises(ValueError, match="4 or 8"):
        XgmiiPhy(lanes=2)
