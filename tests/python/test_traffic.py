"""Packet functions by name, safe argument parsing and the seeded traffic generators."""

from __future__ import annotations

import random
from collections.abc import Iterator

import pytest

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet import traffic
from awesome_vunit_vcs.ethernet.traffic import TrafficError, TrafficItem

SELF = __name__


class Packet:
    """Stands in for a Scapy packet: anything bytes() accepts."""

    def __bytes__(self) -> bytes:
        return bytes.fromhex("020000000001 020000000002 0800") + b"packet"


def frame_function(size: int) -> eth.Frame:
    return eth.Frame.from_payload(bytes(size))


def bytes_function() -> bytes:
    return bytes(20)


def packet_function() -> Packet:
    return Packet()


def pair_function(ifg: int) -> tuple[eth.Frame, eth.WireOptions]:
    return eth.Frame.from_payload(b"x"), eth.WireOptions(ifg_octets=ifg)


def seeded_function(seed: str) -> eth.Frame:
    return traffic.random_frame(traffic.rng_from(seed), max_payload_octets=64)


def generator_function(count: int, seed: int) -> Iterator[eth.Frame]:
    rng = traffic.rng_from(seed)
    for _ in range(count):
        yield traffic.random_frame(rng, max_payload_octets=64)


def not_a_frame() -> int:
    return 3


not_callable = 5


def test_resolve() -> None:
    assert traffic.resolve(f"{SELF}:frame_function") is frame_function
    assert traffic.resolve("awesome_vunit_vcs.ethernet.traffic:TrafficItem.to_wire") is TrafficItem.to_wire
    for spec, match in [
        ("frame_function", "spec"),
        (f"{SELF}:", "spec"),
        ("os.path:join; import os", "spec"),
        ("no_such_module_xyz:f", "Cannot import"),
        (f"{SELF}:missing", "no attribute"),
        (f"{SELF}:not_callable", "not callable"),
    ]:
        with pytest.raises(TrafficError, match=match):
            traffic.resolve(spec)


def test_parse_arguments() -> None:
    assert traffic.parse_arguments("") == {}
    parsed = traffic.parse_arguments("port=1234, name='a', sizes=(64, 1518), data=b'\\x00', flag=True, n=None")
    assert parsed == {"port": 1234, "name": "a", "sizes": (64, 1518), "data": b"\x00", "flag": True, "n": None}
    assert traffic.parse_arguments("values=[-1, 2.5], table={'a': 1}") == {"values": [-1, 2.5], "table": {"a": 1}}


@pytest.mark.parametrize(
    "text",
    [
        "a=__import__('os').system('true')",
        "a=open('/etc/passwd')",
        "a=1), __import__('os'), _(b=2",
        "a=1); import os; _(b=2",
        "**{'a': 1}",
        "1234",
        "a=lambda: 1",
        "a=[x for x in range(3)]",
        "a=b",
        "a=1 if True else 2",
        "a=",
        "a=(1",
    ],
)
def test_parse_arguments_evaluates_nothing(text: str) -> None:
    with pytest.raises(TrafficError):
        traffic.parse_arguments(text)


def test_call_packet_function_accepts_frames_bytes_packets_and_pairs() -> None:
    assert traffic.call_packet_function(f"{SELF}:frame_function", "size=10").frame == frame_function(10)
    assert traffic.call_packet_function(f"{SELF}:bytes_function").frame.data == bytes(20)
    assert traffic.call_packet_function(f"{SELF}:packet_function").frame.payload == b"packet"
    item = traffic.call_packet_function(f"{SELF}:pair_function", "ifg=3")
    assert item.options.ifg_octets == 3 and item.to_wire().ifg_octets == 3
    with pytest.raises(TrafficError, match="returned int"):
        traffic.call_packet_function(f"{SELF}:not_a_frame")
    with pytest.raises(TrafficError, match="Cannot call"):
        traffic.call_packet_function(f"{SELF}:frame_function", "length=10")


def test_seeds_are_reproducible_and_need_an_rng_parameter() -> None:
    first = traffic.call_packet_function(f"{SELF}:seeded_function", seed="8f3a51c0de2b4d17")
    assert first == traffic.call_packet_function(f"{SELF}:seeded_function", seed="8f3a51c0de2b4d17")
    assert first != traffic.call_packet_function(f"{SELF}:seeded_function", seed="8f3a51c0de2b4d18")
    assert bytes(first) == first.frame.data and bytes(first.frame) == first.frame.data
    with pytest.raises(TrafficError, match="seed"):
        traffic.call_packet_function(f"{SELF}:frame_function", "size=1", seed=1)
    with pytest.raises(TrafficError):
        traffic.rng_from(1.5)  # type: ignore[arg-type]


def test_sequence_and_batches() -> None:
    items = list(traffic.sequence(f"{SELF}:generator_function", "count=7", seed=42))
    assert items == list(traffic.sequence(f"{SELF}:generator_function", "count=7", seed=42))
    assert [len(batch) for batch in traffic.batches(items, 3)] == [3, 3, 1]
    with pytest.raises(TrafficError):
        list(traffic.batches(items, 0))
    with pytest.raises(TrafficError, match="not an iterable"):
        traffic.sequence(f"{SELF}:not_a_frame")


def test_generators_stay_within_the_limits() -> None:
    rng = random.Random(7)
    limits = eth.LIMITS
    for _ in range(200):
        frame = traffic.random_frame(rng)
        assert limits.header_octets <= len(frame.data) <= limits.header_octets + limits.max_payload_octets
        assert frame.ethertype is not None and limits.min_ethertype <= frame.ethertype <= limits.max_ethertype
        assert frame.octets[0] & 0x03 == 0x02  # locally administered unicast
        options = traffic.random_wire_options(rng)
        assert options.fcs == "auto" and options.pad and options.preamble_octets == limits.preamble_octets
        assert limits.min_ifg_octets <= options.ifg_octets <= limits.max_ifg_octets


@pytest.mark.parametrize("kind", list(eth.Malformation))
def test_random_wire_options_produce_their_malformation(kind: eth.Malformation) -> None:
    options = traffic.random_wire_options(random.Random(3), malformations=[kind.value])
    frame = traffic.random_frame(random.Random(3), max_payload_octets=20)
    expected = eth.expected_violations(frame, options, previous=options if kind is eth.Malformation.SHORT_IFG else None)
    if kind is eth.Malformation.GIANT:
        assert options == traffic.random_wire_options(random.Random(3))
    else:
        assert expected, kind


@pytest.mark.parametrize("interface", ["gmii", "mii", "xgmii"])
def test_random_traffic_matches_the_oracle(interface: str) -> None:
    items = traffic.random_traffic(
        60, seed=interface, interface=interface, malformations=list(eth.Malformation), malformed_fraction=0.5
    )
    assert items == traffic.random_traffic(
        60, seed=interface, interface=interface, malformations=list(eth.Malformation), malformed_fraction=0.5
    )
    iface = traffic.interface_named(interface)
    with eth.Monitor(iface) as rx:
        rx.feed_frames(items)
    assert len(rx.frames) == len(items)
    for index, (frame, item) in enumerate(zip(rx.frames, items, strict=True)):
        previous = items[index - 1].options if index else None
        expected = eth.expected_violations(item.frame, item.options, interface=iface, previous=previous)
        assert {violation.check for violation in frame.violations} == expected, (index, item.options)
    with pytest.raises(TrafficError):
        traffic.random_traffic(-1, seed=1)
    with pytest.raises(TrafficError):
        traffic.interface_named("sgmii")
