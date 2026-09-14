# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Traffic functions that tb_cookbook.vhd names in push_ethernet_packet and the sequence procedures."""

from collections.abc import Iterator

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet import traffic


# docs-start: packet-function
def udp_to_dut(port: int, size: int) -> eth.Frame:
    """An IPv4 frame whose payload starts with the port number."""
    return eth.Frame.from_payload(port.to_bytes(2, "big") + bytes(size), ethertype=0x0800)


# docs-end: packet-function


# docs-start: sequence-function
def random_frames(seed: str, max_payload: int = 200) -> Iterator[eth.Frame]:
    """Frames of random size and content; the same seed gives the same frames."""
    rng = traffic.rng_from(seed)
    while True:
        yield traffic.random_frame(rng, max_payload_octets=max_payload)


# docs-end: sequence-function
