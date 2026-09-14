# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The traffic sequences a VHDL source transmits and a VHDL monitor checks, malformations included."""

from __future__ import annotations

import numpy as np

from awesome_vunit_vcs.common.vunit_bridge import encode_samples
from awesome_vunit_vcs.ethernet.api import Frame, WireOptions
from awesome_vunit_vcs.ethernet.checker import CheckId
from awesome_vunit_vcs.ethernet.traffic import TrafficItem
from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend, ProtocolCheckerBackend, SourceBackend

RANDOM_TRAFFIC = "awesome_vunit_vcs.ethernet.traffic:random_traffic"
# Without bad_sfd: after a short gap the checker does not report the gap before
# octets without an SFD, which expected_violations predicts
MALFORMED = {
    "count": 40,
    "malformations": "bad_fcs,short_preamble,long_preamble,runt,giant,phy_error,short_ifg",
    "malformed_fraction": 0.5,
}
BAD_SFD_TRAFFIC = "test_backend_sequences:bad_sfd_traffic"


def bad_sfd_traffic() -> list[TrafficItem]:
    """A frame, the same frame with a wrong SFD, and the frame again, with normal gaps."""
    frame = Frame.from_bytes(bytes.fromhex("02000000000102000000000288B5") + bytes(range(46)), has_fcs=False)
    return [TrafficItem(frame), TrafficItem(frame, WireOptions(sfd=0x65)), TrafficItem(frame)]


#: A GMII octet lasts 8 ns
GMII_PERIOD_FS = 8_000_000


def transmit(
    source: SourceBackend, arguments: dict[str, object], seed: str, function: str = RANDOM_TRAFFIC
) -> np.typing.NDArray[np.int32]:
    """The sample words a VHDL source drives for a sequence, after 12 idle clock cycles."""
    # As VHDL does: the function's arguments in a call of their own, then the sequence
    source.set_arguments(**arguments)
    sequence_id = source.start_sequence(function, 0, seed)
    batches = []
    while (batch := source.sequence_symbols(sequence_id, 16)).size:
        batches.append(batch)
    return np.concatenate([np.zeros(12, dtype=np.int32), *batches])


def push(backend: MonitorBackend | ProtocolCheckerBackend, words: np.typing.NDArray[np.int32]) -> None:
    times = np.arange(words.size, dtype=np.int64) * GMII_PERIOD_FS
    backend.push(encode_samples(words, times, 0), 0)


def test_malformed_sequence_matches_the_oracle() -> None:
    words = transmit(SourceBackend("tb:gmii_source", "gmii"), MALFORMED, "7")

    protocol_checker = ProtocolCheckerBackend("tb:gmii_monitor:protocol_checker", "gmii")
    push(protocol_checker, words)

    monitor = MonitorBackend("tb:gmii_monitor", "gmii", checks=False)
    monitor.check_sequence(RANDOM_TRAFFIC, 0, "7", kwargs=MALFORMED)
    push(monitor, words)

    found = {check: protocol_checker.check_count(check.value) for check in CheckId}
    predicted = {check: monitor.expected_violation_count(check.value) for check in CheckId}
    assert found == predicted
    assert sum(found.values()) > 0
    # Every frame received was expected as received, malformations included
    assert monitor.expected_count() == 0
    assert monitor.check_count("ETH_SCOREBOARD") == 0


def test_same_seed_gives_the_same_wire_traffic() -> None:
    first = transmit(SourceBackend("tb:first", "gmii"), MALFORMED, "seed")
    second = transmit(SourceBackend("tb:second", "gmii"), MALFORMED, "seed")
    other = transmit(SourceBackend("tb:other", "gmii"), MALFORMED, "other seed")
    assert np.array_equal(first, second)
    assert not np.array_equal(first, other)


def test_unpredictable_sequence_is_a_failure_report() -> None:
    monitor = MonitorBackend("tb:gmii_monitor", "gmii", checks=False)
    monitor.check_sequence("awesome_vunit_vcs.ethernet.traffic:no_such_function")
    assert "could not check the sequence" in monitor.take_reports()


def test_octets_without_sfd_are_not_compared_with_expected_frames() -> None:
    words = transmit(SourceBackend("tb:gmii_source", "gmii"), {}, "", BAD_SFD_TRAFFIC)

    protocol_checker = ProtocolCheckerBackend("tb:gmii_monitor:protocol_checker", "gmii")
    push(protocol_checker, words)

    monitor = MonitorBackend("tb:gmii_monitor", "gmii", checks=False)
    monitor.check_sequence(BAD_SFD_TRAFFIC)
    push(monitor, words)

    assert protocol_checker.check_count("ETH_SFD") == monitor.expected_violation_count("ETH_SFD") == 1
    assert monitor.compared_count() == 2
    assert monitor.expected_count() == 0
    assert monitor.check_count("ETH_SCOREBOARD") == 0
