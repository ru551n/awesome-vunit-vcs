# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Build and inspect packets with Scapy.

Scapy is optional (pip install awesome-vunit-vcs[scapy]): frames are built,
monitored, checked and captured without it. It adds the protocol layers above
Ethernet.
"""

from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether
from scapy.packet import Raw

from awesome_vunit_vcs.ethernet import MacFrame, append_fcs, build_wire_frame
from awesome_vunit_vcs.ethernet.scapy_adapter import packet_bytes, to_scapy

packet = Ether(dst="02:00:00:00:00:01") / IP(dst="192.168.1.10") / UDP(dport=1234) / Raw(b"hello")

# A packet becomes MAC octets, which is what a source transmits
wire = build_wire_frame(packet_bytes(packet))

# A received frame, here rebuilt from those octets, decodes back into a packet
received = to_scapy(MacFrame(append_fcs(packet_bytes(packet))))
assert received.dst == "02:00:00:00:00:01"
assert IP in received and UDP in received
assert received[UDP].dport == 1234
print(received.summary(), f"({len(wire.octets)} octets on the wire)")
