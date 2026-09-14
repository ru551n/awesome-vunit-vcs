"""
Property-based tests, with strategies built from the public constructors and LIMITS only.

They double as the proof that the API is easy to drive from Hypothesis: every
strategy here is a few lines, and the package itself never imports it.
"""

from __future__ import annotations

from pathlib import Path

import pytest

hypothesis = pytest.importorskip("hypothesis")
from hypothesis import assume, given  # noqa: E402
from hypothesis import strategies as st  # noqa: E402

from awesome_vunit_vcs import ethernet as eth  # noqa: E402

LIMITS = eth.LIMITS
K = eth.Malformation

mac_addresses = st.binary(min_size=LIMITS.mac_address_octets, max_size=LIMITS.mac_address_octets)
ethertypes = st.integers(LIMITS.min_ethertype, LIMITS.max_ethertype)


def payloads(max_octets: int = LIMITS.max_payload_octets) -> st.SearchStrategy[bytes]:
    return st.binary(min_size=LIMITS.min_payload_octets, max_size=max_octets)


def frames(max_payload_octets: int = LIMITS.max_payload_octets) -> st.SearchStrategy[eth.Frame]:
    return st.builds(
        eth.Frame.from_payload, payloads(max_payload_octets), dst=mac_addresses, src=mac_addresses, ethertype=ethertypes
    )


interfaces = st.sampled_from(
    [
        eth.GMII,
        eth.GMII.with_rate("2.5G"),
        eth.MII,
        eth.MII.with_rate("10M"),
        *[eth.XGMII(lanes=lanes, rate=rate) for lanes in LIMITS.xgmii_lanes for rate in (10**10, 10**11, 4 * 10**11)],
    ]
)


@st.composite
def wire_options(draw: st.DrawFn, interface: eth.Interface) -> eth.WireOptions:
    """Any combination of the malformations the oracle predicts on the interface, with drawn parameters."""
    kinds = draw(st.sets(st.sampled_from(sorted(eth.supported_malformations(interface) - {K.GIANT}))))
    preamble = LIMITS.preamble_octets
    if K.SHORT_PREAMBLE in kinds:
        preamble = draw(st.integers(1, LIMITS.preamble_octets - 1))
    elif K.LONG_PREAMBLE in kinds:
        preamble = draw(st.integers(LIMITS.preamble_octets + 1, LIMITS.max_preamble_octets))
    sfd = draw(st.sampled_from([v for v in range(256) if v not in (0x55, 0xD5)])) if K.BAD_SFD in kinds else 0xD5
    errors = ()
    if K.PHY_ERROR in kinds:
        errors = tuple(draw(st.sets(st.integers(-preamble, LIMITS.header_octets - 1), min_size=1, max_size=4)))
    low_ifg = 1 if K.SHORT_IFG in kinds else interface.min_ifg_octets + interface.lanes - 1
    return eth.WireOptions(
        fcs="bad" if K.BAD_FCS in kinds else "auto",
        pad=K.RUNT not in kinds,
        preamble_octets=preamble,
        sfd=sfd,
        ifg_octets=draw(st.integers(low_ifg, 40)),
        errors=tuple(sorted(errors)),
    )


@given(frame=frames(), interface=interfaces)
def test_every_interface_delivers_valid_frames(frame: eth.Frame, interface: eth.Interface) -> None:
    result = eth.decode(interface, interface.encode([frame]))
    assert result.ok and result.frames == (frame.padded(),)


@given(frame=frames())
def test_frame_round_trips(frame: eth.Frame) -> None:
    assert eth.Frame.from_bytes(frame.octets) == frame
    assert eth.Frame.from_bytes(frame.data, has_fcs=False) == frame
    assert eth.Frame.from_packet(frame.data) == frame
    assert eth.Frame(frame.to_wire().octets[8:]) == frame.padded()
    assert frame.padded().padded() == frame.padded()


@given(data=st.data(), interface=interfaces)
def test_the_checker_reports_exactly_the_generated_malformations(data: st.DataObject, interface: eth.Interface) -> None:
    sent = data.draw(
        st.lists(st.tuples(frames(max_payload_octets=120), wire_options(interface)), min_size=1, max_size=4)
    )
    # the XGMII family rejects errors on Start, the first wire octet
    assume(interface.name != "xgmii" or all(-o.preamble_octets not in o.errors for _, o in sent))
    result = eth.decode(interface, interface.encode([frame.to_wire(options) for frame, options in sent]))
    assert len(result.frames) == len(sent)
    for index, (received, (frame, options)) in enumerate(zip(result.frames, sent, strict=True)):
        previous = sent[index - 1][1] if index else None
        expected = eth.expected_violations(frame, options, interface=interface, previous=previous)
        assert {violation.check for violation in received.violations} == expected


@given(data=st.data())
def test_statistics_invariants(data: st.DataObject) -> None:
    sent = data.draw(st.lists(st.tuples(frames(max_payload_octets=200), wire_options(eth.GMII)), max_size=5))
    stats = eth.decode(eth.GMII, eth.GMII.encode([frame.to_wire(options) for frame, options in sent])).statistics
    assert stats.good_frames + stats.bad_frames == stats.total_frames == len(sent)
    assert stats.fcs_errors <= stats.bad_frames and stats.runts <= stats.bad_frames
    assert stats.wire_octets == sum(len(frame.to_wire(options).octets) for frame, options in sent)
    assert stats.frame_size.count == stats.total_frames - stats.sfd_errors


@given(frames=st.lists(frames(max_payload_octets=300), max_size=4))
def test_pcapng_round_trip(tmp_path_factory: pytest.TempPathFactory, frames: list[eth.Frame]) -> None:
    from test_pcap import parse_pcapng

    path: Path = tmp_path_factory.mktemp("pcap") / "frames.pcapng"
    assert eth.write_pcapng(path, frames) == len(frames)
    _, packets = parse_pcapng(path)
    assert [packet["data"] for packet in packets] == [frame.padded().octets for frame in frames]


@given(value=st.integers(0, 10**9), unit=st.sampled_from(sorted(eth.units.TIME_UNITS)))
def test_time_strings(value: int, unit: str) -> None:
    assert eth.fs(f"{value} {unit}") == value * eth.units.TIME_UNITS[unit]


def test_the_gap_before_a_burst_without_an_sfd_is_checked() -> None:
    # Regression: the checker returned on a missing SFD before checking the gap before the burst
    frame = eth.Frame.from_payload(b"", dst=bytes(6), src=bytes(6), ethertype=0x0600)
    # the gap after a frame is part of its options: a 1-octet gap precedes the second burst
    first = eth.WireOptions(ifg_octets=1)
    second = eth.WireOptions(fcs="bad", pad=False, preamble_octets=8, sfd=0)
    sent = [(frame, first), (frame, second)]
    result = eth.decode(eth.GMII, eth.GMII.encode([f.to_wire(o) for f, o in sent]))
    assert len(result.frames) == 2
    received = {violation.check for violation in result.frames[1].violations}
    assert received == eth.expected_violations(frame, second, interface=eth.GMII, previous=first)
    assert eth.CheckId.IFG in received and eth.CheckId.SFD in received
