# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Packet functions and seeded traffic: what a VHDL source sends, decided in Python.

A testbench names a function ("my_packets:udp_to_dut") and passes literal
keyword arguments as a string; nothing is evaluated. Functions that take a
seed get the seed of the call, so the same seed, such as VUnit's
get_seed(runner_cfg), gives the same traffic.
Here the functions live in this file, so their module is __main__.
"""

# docs-start: example

from collections.abc import Iterator

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet import traffic


def udp_to_dut(port: int, size: int) -> eth.Frame:
    return eth.Frame.from_payload(port.to_bytes(2, "big") + bytes(size), ethertype=0x0800)


def mixed(count: int, seed: str) -> Iterator[tuple[eth.Frame, eth.WireOptions]]:
    rng = traffic.rng_from(seed)
    for _ in range(count):
        yield traffic.random_frame(rng, max_payload_octets=200), eth.WireOptions(ifg_octets=rng.randint(12, 40))


item = traffic.call_packet_function("__main__:udp_to_dut", "port=1234, size=64")
assert item.frame.payload[:2] == (1234).to_bytes(2, "big")

# The same seed gives the same traffic; VUnit's string seed works as it is
seed = "8f3a51c0de2b4d17"
assert [i.frame for i in traffic.sequence("__main__:mixed", "count=5", seed=seed)] == [
    i.frame for i in traffic.sequence("__main__:mixed", "count=5", seed=seed)
]

# Built-in random traffic with malformations, checked against the oracle
items = traffic.random_traffic(20, seed=seed, malformations=("bad_fcs", "runt"), malformed_fraction=0.5)
with eth.Monitor(eth.GMII) as rx:
    rx.feed_frames(items)
previous = [None, *items]
for frame, sent, before in zip(rx.frames, items, previous, strict=False):
    expected = eth.expected_violations(sent.frame, sent.options, previous=before and before.options)
    assert {violation.check for violation in frame.violations} == expected
print(f"{len(rx.frames)} frames, {len(rx.violations)} violations, all as expected")
# docs-end: example
