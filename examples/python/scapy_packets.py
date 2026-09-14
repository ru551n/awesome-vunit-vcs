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

from awesome_vunit_vcs import ethernet as eth

packet = Ether(dst="02:00:00:00:00:01") / IP(dst="192.168.1.10") / UDP(dport=1234) / b"hello"
frame = eth.Frame.from_packet(packet)

received = eth.decode(eth.GMII, eth.GMII.encode([frame])).frames[0].to_scapy()
assert received.dst == "02:00:00:00:00:01"
assert IP in received and received[UDP].dport == 1234
print(received.summary())
