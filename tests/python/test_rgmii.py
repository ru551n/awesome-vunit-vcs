"""RGMII decoder and encoder tests: the combined edges are GMII octets at 1 Gb/s and MII nibbles below."""

import numpy as np
import pytest
from helpers import GmiiLine, MiiLine, ethernet_mac_octets, reference_frame

import awesome_vunit_vcs.ethernet as eth
from awesome_vunit_vcs.ethernet.errors import EthernetValueError
from awesome_vunit_vcs.ethernet.lowlevel import EthernetConfig, EthernetFrame, EthernetMonitor
from awesome_vunit_vcs.ethernet.phy import GmiiPhy, MiiPhy, RgmiiPhy, WireFrame, create_phy


def frames_of(phy: RgmiiPhy, words: list[int], times: list[int]) -> list[EthernetFrame]:
    monitor = EthernetMonitor(phy, EthernetConfig(), name="rgmii_monitor")
    frames: list[EthernetFrame] = []
    violations: list[object] = []
    monitor.frames.subscribe(frames.append)
    monitor.checker.violations.subscribe(violations.append)
    monitor.feed(np.array(words, dtype=np.int64), np.array(times, dtype=np.int64))
    assert violations == []
    return frames


def test_gigabit_decodes_octet_words() -> None:
    payload = ethernet_mac_octets(100, seed=1)
    line = GmiiLine()
    line.idle(4)
    line.frame(reference_frame(payload))
    frames = frames_of(RgmiiPhy(), line.words, line.times)
    assert [frame.mac_octets for frame in frames] == [payload]


@pytest.mark.parametrize("link_rate_bps", [10_000_000, 100_000_000])
def test_ten_and_hundred_decode_nibble_words(link_rate_bps: int) -> None:
    payload = ethernet_mac_octets(80, seed=2)
    line = MiiLine()
    line.idle(4)
    line.frame(reference_frame(payload))
    frames = frames_of(RgmiiPhy(link_rate_bps), line.words, line.times)
    assert [frame.mac_octets for frame in frames] == [payload]


@pytest.mark.parametrize(
    "link_rate_bps,reference", [(1_000_000_000, GmiiPhy), (100_000_000, MiiPhy), (10_000_000, MiiPhy)]
)
def test_encode_matches_the_symbols_of_the_rate(link_rate_bps: int, reference: type) -> None:
    wire = WireFrame(octets=b"\x55" * 7 + b"\xd5" + bytes(range(60)), wire_error_offsets=(10,), ifg_octets=12)
    assert RgmiiPhy(link_rate_bps).encode(wire).tolist() == reference(link_rate_bps).encode(wire).tolist()


def test_create_phy_and_interface() -> None:
    assert isinstance(create_phy("rgmii", link_rate_bps=100_000_000), RgmiiPhy)
    assert eth.RGMII.clock_period_fs == eth.fs("8 ns")
    assert eth.RGMII.with_rate("100M").clock_period_fs == eth.fs("40 ns")
    assert eth.RGMII.with_rate("10M").clock_period_fs == eth.fs("400 ns")
    with pytest.raises(EthernetValueError):
        eth.RGMII.with_rate("2.5G")
    with pytest.raises(EthernetValueError):
        RgmiiPhy(0)
