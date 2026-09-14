# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Property-based tests with Hypothesis, from the public constructors and limits.

awesome-vunit-vcs does not depend on Hypothesis. Its value types are typed,
immutable and validated with one exception, LIMITS bounds the parameter space
and expected_violations is the oracle, so strategies are a few lines each.
"""

from hypothesis import given, settings
from hypothesis import strategies as st

from awesome_vunit_vcs import ethernet as eth

LIMITS = eth.LIMITS
mac_addresses = st.binary(min_size=LIMITS.mac_address_octets, max_size=LIMITS.mac_address_octets)
frames = st.builds(
    eth.Frame.from_payload,
    st.binary(max_size=LIMITS.max_payload_octets),
    dst=mac_addresses,
    src=mac_addresses,
    ethertype=st.integers(LIMITS.min_ethertype, LIMITS.max_ethertype),
)
interfaces = st.sampled_from([eth.GMII, eth.MII, eth.XGMII(lanes=4), eth.XGMII(lanes=8, rate="100G")])
malformations = st.sets(st.sampled_from([kind for kind in eth.Malformation if kind is not eth.Malformation.GIANT]))


@settings(max_examples=20, deadline=None)
@given(frame=frames, interface=interfaces)
def test_every_interface_delivers_the_frame(frame: eth.Frame, interface: eth.Interface) -> None:
    assert eth.decode(interface, interface.encode([frame])).frames == (frame.padded(),)


@settings(max_examples=20, deadline=None)
@given(frame=frames, kinds=malformations)
def test_the_checker_reports_exactly_the_malformations(frame: eth.Frame, kinds: set[eth.Malformation]) -> None:
    options = eth.WireOptions.malformed(*kinds)
    result = eth.decode(eth.GMII, eth.GMII.encode([frame.to_wire(options)]))
    assert result.checks == eth.expected_violations(frame, options)


if __name__ == "__main__":
    test_every_interface_delivers_the_frame()
    test_the_checker_reports_exactly_the_malformations()
    print("Both properties hold")
