"""The AXI-Stream MAC client interface: decoding, the AXI-Stream rules and the oracle."""

from __future__ import annotations

import numpy as np
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet import (
    CheckId,
    EthernetValueError,
    Malformation,
    WireOptions,
    expected_violations,
    supported_malformations,
    traffic,
)
from awesome_vunit_vcs.ethernet.phy.axis import AXIS_KEEP, AXIS_READY, AXIS_VALID
from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend


def frames_of(sizes: list[int]) -> list[eth.Frame]:
    return [eth.Frame.from_payload(bytes(index % 256 for index in range(size))) for size in sizes]


@pytest.mark.parametrize("bytes_per_beat", [1, 3, 4, 8])
@pytest.mark.parametrize(("valid_low", "ready_low"), [(0, 0), (30, 40)])
def test_frames_survive_every_width_and_stall_pattern(bytes_per_beat: int, valid_low: int, ready_low: int) -> None:
    interface = eth.AXIS(bytes_per_beat, valid_low_percent=valid_low, ready_low_percent=ready_low, seed=5)
    frames = frames_of([1, 46, 47, 100, 1500])
    result = eth.decode(interface, interface.encode(frames))
    assert [frame.data for frame in result.frames] == [frame.padded().data for frame in frames]
    assert result.ok


def test_frames_without_fcs() -> None:
    interface = eth.AXIS(4, has_fcs=False)
    frames = frames_of([10, 300])
    result = eth.decode(interface, interface.encode(frames))
    assert [frame.data for frame in result.frames] == [frame.padded().data for frame in frames]
    assert result.ok


def test_frames_have_no_preamble_checks() -> None:
    assert not eth.AXIS().has_preamble
    assert eth.AXIS().min_ifg_octets == 0
    assert supported_malformations(eth.AXIS()) == {
        Malformation.BAD_FCS,
        Malformation.RUNT,
        Malformation.GIANT,
        Malformation.PHY_ERROR,
    }


def valid_columns(samples: eth.Samples, lanes: int) -> list[int]:
    return [index for index in range(0, samples.words.size, lanes) if samples.words[index] & AXIS_VALID]


def test_partial_beat_before_the_last_is_a_keep_violation() -> None:
    samples = eth.AXIS(4).encode(frames_of([60]))
    words = samples.words.copy()
    words[valid_columns(samples, 4)[1] + 3] &= ~AXIS_KEEP
    result = eth.decode(eth.AXIS(4), eth.Samples(words, samples.times))
    assert CheckId.KEEP in result.checks


def test_bus_change_while_waiting_for_tready_is_a_stability_violation() -> None:
    samples = eth.AXIS(4).encode(frames_of([60]))
    words, times = samples.words, samples.times
    index = valid_columns(samples, 4)[2]
    stalled = words[index : index + 4] & ~AXIS_READY
    changed = stalled.copy()
    changed[0] ^= 1
    stable = np.concatenate([words[:index], stalled, words[index:]])
    unstable = np.concatenate([words[:index], changed, words[index:]])
    stable_times = np.concatenate([times[:index], times[index : index + 4], times[index:]])
    assert eth.decode(eth.AXIS(4), eth.Samples(stable, stable_times)).ok
    assert eth.decode(eth.AXIS(4), eth.Samples(unstable, stable_times)).checks == {CheckId.STABLE}


def test_tvalid_dropped_before_the_handshake_is_a_valid_violation() -> None:
    samples = eth.AXIS(4).encode(frames_of([60]))
    words, times = samples.words, samples.times
    index = valid_columns(samples, 4)[2]
    stalled = words[index : index + 4] & ~AXIS_READY
    idle = np.full(4, AXIS_READY, dtype=np.int64)
    dropped = np.concatenate([words[:index], stalled, idle, words[index:]])
    dropped_times = np.concatenate([times[:index], times[index : index + 4], times[index : index + 4], times[index:]])
    assert CheckId.VALID in eth.decode(eth.AXIS(4), eth.Samples(dropped, dropped_times)).checks


def test_tuser_marks_an_errored_frame() -> None:
    frame = frames_of([60])[0]
    options = WireOptions(errors=(10,))
    interface = eth.AXIS(8)
    result = eth.decode(interface, interface.encode([frame.to_wire(options)]))
    assert result.checks == {CheckId.PHY_ERROR} == expected_violations(frame, options, interface=interface)


def test_invalid_interfaces_are_refused() -> None:
    with pytest.raises(EthernetValueError):
        eth.AXIS(0)
    with pytest.raises(EthernetValueError):
        eth.AXIS(valid_low_percent=100).phy()
    with pytest.raises(EthernetValueError):
        eth.Interface("gmii", 1_000_000_000, valid_low_percent=10)


def test_backends_run_without_preamble() -> None:
    backend = MonitorBackend("rx", "axis", lanes=4)
    assert not backend.monitor.config.has_preamble
    assert traffic.interface_named("axis") == eth.AXIS()


malformation_sets = st.sets(st.sampled_from(sorted(supported_malformations(eth.AXIS()), key=str)), max_size=2)


@settings(max_examples=40)
@given(
    payload=st.binary(min_size=0, max_size=200),
    kinds=malformation_sets,
    bytes_per_beat=st.sampled_from([1, 2, 4, 8]),
    stalls=st.integers(min_value=0, max_value=60),
    seed=st.integers(min_value=0, max_value=2**16),
)
def test_the_checker_reports_exactly_the_oracle(
    payload: bytes, kinds: set[Malformation], bytes_per_beat: int, stalls: int, seed: int
) -> None:
    interface = eth.AXIS(bytes_per_beat, valid_low_percent=stalls, ready_low_percent=stalls, seed=seed)
    frame = eth.Frame.from_payload(payload)
    if Malformation.GIANT in kinds:
        frame = eth.Frame.from_payload(bytes(1600))
    options = WireOptions.malformed(*(kind for kind in kinds if kind is not Malformation.GIANT))
    result = eth.decode(interface, interface.encode([frame.to_wire(options)]))
    assert result.checks == expected_violations(frame, options, interface=interface)


@settings(max_examples=25)
@given(
    sizes=st.lists(st.integers(min_value=1, max_value=400), min_size=1, max_size=6),
    first=st.integers(min_value=0, max_value=2**16),
    second=st.integers(min_value=0, max_value=2**16),
)
def test_backpressure_does_not_change_the_frames(sizes: list[int], first: int, second: int) -> None:
    frames = frames_of(sizes)
    received = [
        [frame.data for frame in eth.decode(interface, interface.encode(frames)).frames]
        for interface in (
            eth.AXIS(4, valid_low_percent=40, ready_low_percent=40, seed=first),
            eth.AXIS(4, valid_low_percent=10, ready_low_percent=70, seed=second),
        )
    ]
    assert received[0] == received[1] == [frame.padded().data for frame in frames]
