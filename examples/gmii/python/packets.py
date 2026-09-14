# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
A packet function for push_ethernet_packet.

tb_gmii_example.vhd transmits ``push_ethernet_packet(net, source,
"packets:udp_packet", "dport=1234")``: the source calls this function with the
keyword arguments and transmits the octets it returns.
"""

from scapy.all import IP, UDP, Ether, Raw


def udp_packet(dport: int = 1234) -> bytes:
    """A UDP packet to 02:00:00:00:00:01 carrying hello."""
    return bytes(Ether(dst="02:00:00:00:00:01") / IP(dst="192.168.1.10") / UDP(dport=dport) / Raw(b"hello"))
