import numpy as np
import pytest
from helpers import VALID, ethernet_payload, reference_frame

from awesome_vunit_vcs.ethernet import CheckId, EthernetMonitor, EthernetSource, FcsMode, build_wire_frame
from awesome_vunit_vcs.ethernet.phy import GmiiPhy, WireFrame


def test_wire_frame_matches_reference() -> None:
    payload = ethernet_payload(30)
    wire = build_wire_frame(payload)
    assert wire.octets == b"\x55" * 7 + b"\xd5" + reference_frame(payload)
    assert wire.ifg_octets == 12


def test_bad_fcs_no_padding_and_raw_modes() -> None:
    payload = ethernet_payload(30)
    bad = build_wire_frame(payload, fcs=FcsMode.BAD, pad=False)
    good = build_wire_frame(payload, pad=False)
    assert bad.octets[:-4] == good.octets[:-4]
    assert int.from_bytes(bad.octets[-4:], "little") == int.from_bytes(good.octets[-4:], "little") ^ 0xFFFFFFFF
    raw = build_wire_frame(b"\x01\x02", fcs="none", preamble_octets=2, sfd=0x5D)
    assert raw.octets == b"\x55\x55\x5d\x01\x02"


def test_invalid_requests() -> None:
    with pytest.raises(ValueError):
        build_wire_frame(b"", fcs="sometimes")
    with pytest.raises(ValueError):
        build_wire_frame(b"", error_offsets=(1000,))
    with pytest.raises(ValueError):
        WireFrame(b"\x55", ifg_octets=-1)


def test_error_offsets_count_from_the_first_octet_after_the_sfd() -> None:
    wire = build_wire_frame(ethernet_payload(60), preamble_octets=5, error_offsets=(0, 20, -1, -6))
    # 5 preamble octets and the SFD come first on the wire
    assert wire.error_offsets == (6, 26, 5, 0)
    with pytest.raises(ValueError):
        build_wire_frame(ethernet_payload(60), error_offsets=(-9,))


def test_error_offsets_match_the_phy_error_report() -> None:
    source = EthernetSource(GmiiPhy())
    symbols = source.take_symbols(source.queue(build_wire_frame(ethernet_payload(60), error_offsets=(20,))))
    monitor = EthernetMonitor(GmiiPhy())
    violations: list[str] = []
    monitor.checker.violations.subscribe(lambda violation: violations.append(violation.message))
    words = np.concatenate([np.zeros(1, dtype=np.int32), symbols]).astype(np.int64)
    monitor.feed(words, np.arange(len(words), dtype=np.int64) * 8_000_000)
    assert monitor.history[0].mac_error_offsets == (20,)
    assert any("frame offsets=20 " in message for message in violations)


def test_gmii_encoding() -> None:
    wire = WireFrame(b"\x55\xd5\x01", error_offsets=(2,), ifg_octets=2)
    symbols = GmiiPhy().encode(wire)
    assert symbols.dtype == np.int32
    assert symbols.tolist() == [0x55 | VALID, 0xD5 | VALID, 0x01 | VALID | (1 << 9), 0, 0]


def test_source_to_monitor_round_trip_with_malformed_traffic() -> None:
    source = EthernetSource(GmiiPhy())
    transmitted: list[WireFrame] = []
    source.transmitted.subscribe(transmitted.append)
    requests = [
        build_wire_frame(ethernet_payload(60, seed=1)),
        build_wire_frame(ethernet_payload(80, seed=2), fcs=FcsMode.BAD),
        build_wire_frame(ethernet_payload(20, seed=3), pad=False),
        build_wire_frame(ethernet_payload(60, seed=4), preamble_octets=5),
        build_wire_frame(ethernet_payload(60, seed=5), error_offsets=(30,), ifg_octets=4),
        build_wire_frame(ethernet_payload(60, seed=6)),
    ]
    ids = [source.queue(request) for request in requests]
    symbols = np.concatenate([np.zeros(1, dtype=np.int32)] + [source.take_symbols(i) for i in ids])
    assert source.pending == 0
    assert transmitted == requests

    monitor = EthernetMonitor(GmiiPhy())
    checks: list[CheckId] = []
    monitor.checker.violations.subscribe(lambda violation: checks.append(violation.check))
    monitor.feed(symbols.astype(np.int64), np.arange(len(symbols), dtype=np.int64) * 8_000_000)
    assert checks == [CheckId.FCS, CheckId.RUNT, CheckId.PREAMBLE, CheckId.PHY_ERROR, CheckId.IFG]
    assert monitor.history[0].payload == ethernet_payload(60, seed=1)


def test_unknown_frame_id() -> None:
    with pytest.raises(KeyError):
        EthernetSource(GmiiPhy()).take_symbols(3)
