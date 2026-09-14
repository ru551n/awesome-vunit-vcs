"""The happy-path Ethernet API: units, interfaces, frames, wire options, the monitor and the oracle."""

from __future__ import annotations

import subprocess
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest
from helpers import GMII_PERIOD_FS, GmiiLine, ethernet_mac_octets, reference_crc32, reference_frame

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet import lowlevel


def test_units() -> None:
    assert eth.fs("8 ns") == 8_000_000
    assert eth.fs("1.5 ps") == 1500
    assert eth.fs(12) == 12
    assert eth.bps("2.5G") == 2_500_000_000
    assert eth.bps("100 Mbps") == 100_000_000
    assert eth.bps(10) == 10
    for bad in ("8", "8 hours", "0.5 fs", "-1 ns"):
        with pytest.raises(eth.EthernetValueError):
            eth.fs(bad)
    for bad_rate in ("fast", "0G", 0, "1.5"):
        with pytest.raises(eth.EthernetValueError):
            eth.bps(bad_rate)


def test_every_validation_raises_the_package_exception() -> None:
    assert issubclass(eth.EthernetValueError, ValueError)
    cases = [
        lambda: eth.XGMII(lanes=6),
        lambda: eth.Interface("sgmii", 1),
        lambda: eth.MII.with_rate("1G"),
        lambda: eth.Frame.from_payload(b"", dst="02:00"),
        lambda: eth.Frame.from_payload(b"", ethertype=0x10000),
        lambda: eth.WireOptions(sfd=256),
        lambda: eth.WireOptions(fcs="maybe"),  # type: ignore[arg-type]
        lambda: eth.Frame.from_payload(b"").to_wire(eth.WireOptions(errors=(500,))),
        lambda: eth.WireOptions.malformed(eth.Malformation.GIANT),
        lambda: eth.Limits(min_frame_octets=2000),
        lambda: lowlevel.CheckId.parse("ETH_NOPE"),
        lambda: lowlevel.MonitorConfig(min_frame_octets=-1),
    ]
    for case in cases:
        with pytest.raises(eth.EthernetValueError):
            case()


def test_interfaces() -> None:
    assert eth.GMII.clock_period_fs == GMII_PERIOD_FS
    assert eth.MII.clock_period_fs == eth.fs("40 ns")
    assert eth.MII.with_rate("10M").clock_period_fs == eth.fs("400 ns")
    xgmii = eth.XGMII(lanes=8, rate="100G")
    assert (xgmii.lanes, xgmii.words_per_clock, xgmii.clock_period_fs) == (8, 8, 8 * 80_000)
    assert (eth.GMII.min_ifg_octets, xgmii.min_ifg_octets) == (12, 5)
    assert eth.GMII.with_rate("2.5G").link_rate_bps == 2_500_000_000
    assert eth.XGMII() == eth.XGMII(lanes=4, rate=10_000_000_000)
    assert len({eth.GMII, eth.MII, eth.XGMII()}) == 3


def test_encode_matches_the_reference_gmii_line() -> None:
    mac = ethernet_mac_octets(80, seed=1)
    line = GmiiLine()
    line.idle(12)
    line.frame(reference_frame(mac))
    samples = eth.GMII.encode([eth.Frame.from_bytes(mac, has_fcs=False)])
    assert samples == eth.Samples.from_arrays(line.words, line.times)


def test_samples() -> None:
    first = eth.GMII.idle(2)
    second = eth.GMII.idle(3, start_fs=eth.fs("16 ns"))
    joined = first + second
    assert len(joined) == 5 and joined.times.tolist() == [0, 8_000_000, 16_000_000, 24_000_000, 32_000_000]
    with pytest.raises(eth.EthernetValueError):
        eth.Samples(np.zeros(2, dtype=np.int64), np.zeros(3, dtype=np.int64))
    assert eth.XGMII(lanes=8).idle(1).words.tolist() == [0x107] * 8


def test_frame_views_against_the_reference() -> None:
    mac = ethernet_mac_octets(40, seed=2)
    frame = eth.Frame.from_bytes(mac, has_fcs=False)
    assert frame.fcs == reference_crc32(mac)
    assert frame.octets == mac + reference_crc32(mac).to_bytes(4, "little")
    assert frame.fcs_ok and frame.ok and frame.size == 44
    assert frame.data == mac and frame.dst == "02:00:00:00:00:01" and frame.src == "02:00:00:00:00:02"
    assert frame.ethertype == 0x0800 and frame.payload == mac[14:]
    assert eth.Frame.from_bytes(frame.octets) == frame
    assert not eth.Frame(frame.octets[:-1] + b"\x00").fcs_ok
    assert eth.Frame.from_payload(b"ab", ethertype=2).payload == b"ab"  # a length field strips padding


def test_frame_from_payload_defaults_and_addresses() -> None:
    frame = eth.Frame.from_payload(b"x", dst=bytes(6), src="02-11-22-33-44-55", ethertype=0x88B5)
    assert frame.data == bytes(6) + bytes.fromhex("021122334455") + b"\x88\xb5x"
    assert eth.mac_address("02:00:00:00:00:01") == bytes.fromhex("020000000001")


def test_frames_are_values_regardless_of_reception() -> None:
    frame = eth.Frame.from_payload(bytes(50))
    received = eth.decode(eth.GMII, eth.GMII.encode([frame])).frames[0]
    assert received == frame and hash(received) == hash(frame)
    assert received.timestamp_fs == (12 + 7) * GMII_PERIOD_FS and received.index == 0
    assert received.received is not None


def test_to_wire_fcs_kinds_and_error_offsets() -> None:
    frame = eth.Frame.from_payload(b"hi")
    assert eth.Frame(frame.to_wire().octets[8:]).fcs_ok
    assert eth.Frame(frame.to_wire(eth.WireOptions(fcs="bad")).octets[8:]).fcs_ok is False
    assert frame.to_wire(eth.WireOptions(fcs="none")).octets[8:] == frame.data
    corrupted = eth.Frame(frame.octets[:-1] + bytes([frame.octets[-1] ^ 1]))
    assert corrupted.to_wire().octets[8:] == corrupted.octets  # "auto" keeps a wrong FCS and does not pad
    wire = frame.to_wire(eth.WireOptions(preamble_octets=3, errors=(-4, -1, 0, 5)))
    assert wire.error_offsets == (-4, -1, 0, 5) and wire.wire_error_offsets == (0, 3, 4, 9)


def test_malformed_options() -> None:
    kinds = eth.Malformation
    assert eth.WireOptions.malformed() == eth.WireOptions()
    options = eth.WireOptions.malformed(kinds.BAD_FCS, kinds.SHORT_PREAMBLE, kinds.RUNT, kinds.PHY_ERROR)
    assert (options.fcs, options.preamble_octets, options.pad, options.errors) == ("bad", 5, False, (0,))
    assert eth.WireOptions.malformed(kinds.SHORT_IFG).ifg_octets < eth.XGMII().min_ifg_octets
    assert eth.WireOptions.malformed(kinds.BAD_SFD).sfd not in (0x55, 0xD5)


def test_monitor_attributes_violations_to_frames() -> None:
    frame = eth.Frame.from_payload(bytes(60))
    seen: list[eth.Frame] = []
    with eth.Monitor(eth.GMII, keep_frames=2) as rx:
        rx.on_frame(seen.append)
        violations = rx.on_violation([].append)
        assert callable(violations)
        rx.feed_frames([frame.to_wire(eth.WireOptions(fcs="bad", ifg_octets=3)), frame, frame])
    assert len(seen) == 3 and len(rx.frames) == 2
    assert [v.check for v in seen[0].violations] == [eth.CheckId.FCS]
    assert [v.check for v in seen[1].violations] == [eth.CheckId.IFG]
    assert seen[2].violations == () and seen[2].ok and not seen[0].ok
    assert rx.count("ETH_FCS") == 1 and rx.statistics.total_frames == 3


def test_monitor_checks_selection_and_unfinished_frame() -> None:
    frame = eth.Frame.from_payload(bytes(60))
    wire = frame.to_wire(eth.WireOptions(fcs="bad", ifg_octets=3))
    with eth.Monitor(eth.GMII, checks=["ETH_IFG"]) as only_ifg:
        only_ifg.feed_frames([wire, frame])
    assert [v.check for v in only_ifg.violations] == [eth.CheckId.IFG]
    with eth.Monitor(eth.GMII, checks=False) as silent:
        silent.feed_frames([wire, frame])
    assert silent.violations == [] and len(silent.frames) == 2

    samples = eth.GMII.encode([frame])
    rx = eth.Monitor(eth.GMII)
    assert rx.feed(eth.Samples(samples.words[:40], samples.times[:40])) == []
    rx.finish()
    rx.finish()
    assert [v.check for v in rx.violations] == [eth.CheckId.FRAME_STATE]


def test_monitor_feed_returns_completed_frames_across_batches() -> None:
    frames = [eth.Frame.from_payload(bytes(size)) for size in (46, 200, 1000)]
    samples = eth.MII.encode(frames)
    rx = eth.Monitor(eth.MII)
    completed = []
    for start in range(0, len(samples), 333):
        completed += rx.feed(eth.Samples(samples.words[start : start + 333], samples.times[start : start + 333]))
    rx.finish()
    assert completed == [frame.padded() for frame in frames] and rx.violations == []


def test_decode_result() -> None:
    frame = eth.Frame.from_payload(bytes(10))
    result = eth.decode(eth.GMII, eth.GMII.encode([frame.to_wire(eth.WireOptions(fcs="bad")), frame]))
    assert not result.ok and result.checks == {eth.CheckId.FCS}
    assert result.statistics.total_frames == 2 and len(result.frames) == 2
    assert eth.decode(eth.GMII, eth.GMII.encode([frame]), checks=False).violations == ()


def test_write_pcapng_reads_back(tmp_path: Path) -> None:
    from test_pcap import parse_pcapng

    frames = [eth.Frame.from_payload(bytes(size)) for size in (46, 300)]
    assert eth.write_pcapng(tmp_path / "built.pcapng", frames) == 2
    _, packets = parse_pcapng(tmp_path / "built.pcapng")
    assert [packet["data"] for packet in packets] == [frame.padded().octets for frame in frames]

    received = eth.decode(eth.MII, eth.MII.encode(frames)).frames
    assert eth.write_pcapng(tmp_path / "received.pcapng", received, fcs=False) == 2
    _, packets = parse_pcapng(tmp_path / "received.pcapng")
    assert [packet["data"] for packet in packets] == [frame.data for frame in received]


@pytest.mark.parametrize("interface", [eth.GMII, eth.MII, eth.XGMII(lanes=8, rate="25G")])
def test_expected_violations_match_the_checker(interface: eth.Interface) -> None:
    frame = eth.Frame.from_payload(bytes(20))
    for kinds in [(), *[(kind,) for kind in eth.supported_malformations(interface)]]:
        if kinds == (eth.Malformation.GIANT,):
            sent, options = eth.Frame.from_payload(bytes(1600)), eth.WireOptions()
        else:
            sent, options = frame, eth.WireOptions.malformed(*kinds)
        with eth.Monitor(interface) as rx:
            rx.feed_frames([sent.to_wire(options), frame])
        first, second = ({v.check for v in received.violations} for received in rx.frames)
        assert first == eth.expected_violations(sent, options, interface=interface), kinds
        assert second == eth.expected_violations(frame, interface=interface, previous=options), kinds


def test_expected_violations_refuses_what_it_cannot_predict() -> None:
    frame = eth.Frame.from_payload(b"")
    with pytest.raises(eth.EthernetValueError):
        eth.expected_violations(frame, eth.WireOptions(sfd=0x55))
    with pytest.raises(eth.EthernetValueError):
        eth.expected_violations(frame, eth.WireOptions(sfd=0xD4), interface=eth.MII)
    with pytest.raises(eth.EthernetValueError):
        eth.expected_violations(frame, eth.WireOptions(preamble_octets=0), interface=eth.XGMII())
    with pytest.raises(eth.EthernetValueError):
        eth.expected_violations(frame, interface=eth.XGMII(), previous=eth.WireOptions(ifg_octets=6))
    assert eth.Malformation.BAD_SFD not in eth.supported_malformations(eth.MII)


def test_deprecated_names_warn_and_lowlevel_does_not() -> None:
    with pytest.warns(DeprecationWarning, match="MacFrame"):
        assert eth.MacFrame is lowlevel.MacFrame  # type: ignore[attr-defined]
    with pytest.warns(DeprecationWarning):
        assert eth.EthernetSource is not None  # type: ignore[attr-defined]
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        assert lowlevel.EthernetStatistics is eth.Statistics
        assert lowlevel.EthernetConfig is eth.MonitorConfig
    with pytest.raises(AttributeError):
        _ = eth.NoSuchThing  # type: ignore[attr-defined]


def test_the_package_never_imports_hypothesis() -> None:
    code = (
        "import pkgutil, sys, awesome_vunit_vcs\n"
        "for module in pkgutil.walk_packages(awesome_vunit_vcs.__path__, 'awesome_vunit_vcs.'):\n"
        "    if 'scapy' not in module.name:\n"
        "        __import__(module.name)\n"
        "assert 'hypothesis' not in sys.modules, sorted(m for m in sys.modules if 'hypothesis' in m)\n"
    )
    subprocess.run([sys.executable, "-c", code], check=True)


@pytest.mark.parametrize(("rate", "octet_period_fs"), [("200G", 40_000), ("400G", 20_000)])
def test_200gmii_and_400gmii_timestamps_are_exact(rate: str, octet_period_fs: int) -> None:
    interface = eth.XGMII(lanes=8, rate=rate)
    frames = [eth.Frame.from_payload(bytes(range(46))), eth.Frame.from_payload(bytes(100))]
    samples = interface.encode([frame.to_wire() for frame in frames])
    column_period_fs = 8 * octet_period_fs
    assert set((samples.times[8::8] - samples.times[:-8:8]).tolist()) == {column_period_fs}
    result = eth.decode(interface, samples)
    assert [frame.data for frame in result.frames] == [frame.data for frame in frames]
    assert not result.violations
    start_fs = result.frames[1].timestamp_fs
    assert start_fs is not None and start_fs % octet_period_fs == 0
