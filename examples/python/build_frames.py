# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Build Ethernet frames without a simulator.

A frame is described by its MAC octets, from the destination address up to,
not including, the FCS. build_wire_frame adds what a transmitter puts on the
wire around them, including deliberate errors.
"""

from awesome_vunit_vcs.ethernet import FcsMode, MacFrame, append_fcs, build_wire_frame, fcs32

# Destination address, source address, the local experimental EtherType, payload
mac_octets = bytes.fromhex("020000000001 020000000002 88b5") + b"hello"

# The FCS is a CRC-32, transmitted least significant octet first
frame = MacFrame(append_fcs(mac_octets))
assert frame.fcs_ok
assert frame.fcs_received == fcs32(mac_octets)
assert frame.ethertype == 0x88B5
assert frame.payload == b"hello"

# On the wire: 7 preamble octets, the SFD, the frame padded to 60 octets, the FCS
wire = build_wire_frame(mac_octets)
assert wire.octets[:8] == bytes.fromhex("55555555555555d5")
assert len(wire.octets) == 8 + 64
assert wire.ifg_octets == 12

# Malformed traffic is intentional: a bad FCS, a short preamble, no padding, a
# short inter-frame gap, and the error signal with the first octet after the SFD
bad = build_wire_frame(mac_octets, fcs=FcsMode.BAD, preamble_octets=5, pad=False, ifg_octets=4, error_offsets=[0])
assert not MacFrame(bad.octets[6:]).fcs_ok
assert bad.error_offsets == (6,)  # wire octet index: 5 preamble octets and the SFD come first
print(f"{len(wire.octets)} octets on the wire, FCS 0x{frame.fcs_received:08X}")
