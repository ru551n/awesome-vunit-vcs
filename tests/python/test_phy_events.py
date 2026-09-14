"""PHY events: what control character PHYs (XGMII) report besides octets."""

import numpy as np
import pytest

from awesome_vunit_vcs.common.vunit_bridge import decode_samples, encode_samples
from awesome_vunit_vcs.ethernet import CheckId, EthernetMonitor
from awesome_vunit_vcs.ethernet.phy.common import Int32Array, Int64Array, OctetBatch, PhyEvent, WireFrame


class ControlCharacterPhy:
    """A stand-in decoder that reports an event for every sample word 0x1FE."""

    name = "control_character"
    link_rate_bps = 10_000_000_000

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        faults = np.flatnonzero(words == 0x1FE)
        events = tuple(
            PhyEvent(int(times[index]), "ETH_LINK_FAULT", "local fault ordered set", ("lane=0",)) for index in faults
        )
        keep = words != 0x1FE
        return OctetBatch(words[keep] & 0xFF, times[keep], events)

    def encode(self, wire: WireFrame) -> Int32Array:
        raise NotImplementedError


def test_phy_events_reach_the_checker() -> None:
    monitor = EthernetMonitor(ControlCharacterPhy())
    seen = []
    monitor.checker.violations.subscribe(seen.append)
    monitor.feed(np.array([0x07, 0x1FE, 0x07], dtype=np.int64), np.array([0, 10, 20], dtype=np.int64))
    assert [violation.check for violation in seen] == [CheckId.LINK_FAULT]
    assert seen[0].message.splitlines() == ["ETH_LINK_FAULT: local fault ordered set", "lane=0", "time=10 fs"]
    assert monitor.checker.count("link_fault") == 1


def test_phy_events_follow_check_enables() -> None:
    monitor = EthernetMonitor(ControlCharacterPhy())
    monitor.checker.disable(CheckId.LINK_FAULT)
    monitor.feed(np.array([0x1FE], dtype=np.int64), np.array([0], dtype=np.int64))
    assert monitor.checker.count(CheckId.LINK_FAULT) == 0


def test_octet_batches_default_to_no_events() -> None:
    assert OctetBatch(np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int64)).events == ()


def test_lanes_share_a_time_with_zero_deltas() -> None:
    # XGMII: one word per lane, the lanes after the first at the same time
    times = [1000, 1000, 1000, 1000, 7400, 7400, 7400, 7400]
    encoded = encode_samples(list(range(8)), times, 0, delta_unit_fs=200)
    assert encoded[1::2].tolist() == [5, 0, 0, 0, 32, 0, 0, 0]
    assert decode_samples(encoded, 0, delta_unit_fs=200)[1].tolist() == times


def test_delta_unit_must_divide_the_times() -> None:
    with pytest.raises(ValueError, match="multiples"):
        encode_samples([1], [1500], 0, delta_unit_fs=1000)
    with pytest.raises(ValueError, match="at least"):
        decode_samples(np.array([1, 1], dtype=np.int32), 0, delta_unit_fs=0)
