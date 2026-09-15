# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Traffic functions that tb_cookbook.vhd names in push_ethernet_packet and the sequence procedures."""

# docs-start: packet-function
from collections.abc import Iterator

from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.common.vunit_bridge import decode_text
from awesome_vunit_vcs.ethernet import traffic


def udp_to_dut(port: int, size: int, label: str | list[int] = "") -> eth.Frame:
    """An IPv4 frame whose payload is the port number, ``size`` zero octets and the label."""
    payload = port.to_bytes(2, "big") + bytes(size) + decode_text(label).encode()
    return eth.Frame.from_payload(payload, ethertype=0x0800)


# docs-end: packet-function


# docs-start: sequence-function
def random_frames(seed: str, max_payload: int = 200) -> Iterator[eth.Frame]:
    """Frames of random size and content; the same seed gives the same frames."""
    rng = traffic.rng_from(seed)
    while True:
        yield traffic.random_frame(rng, max_payload_octets=max_payload)


# docs-end: sequence-function
