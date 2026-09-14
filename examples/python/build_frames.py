# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Build Ethernet frames and malformed traffic without a simulator.

A Frame is the octets from the destination address up to the FCS. to_wire
adds what a transmitter puts around them; WireOptions describe deliberate
errors as data, and expected_violations says what a monitor reports for them.
"""

# docs-start: example

from awesome_vunit_vcs import ethernet as eth

# A frame with a correct FCS, and what a transmitter puts on the wire for it
frame = eth.Frame.from_payload(b"hello")
wire = frame.to_wire()
assert frame.fcs_ok and frame.payload == b"hello" and frame.dst == "02:00:00:00:00:01"
assert wire.octets[:8] == bytes.fromhex("55555555555555d5")  # 7 preamble octets and the SFD
assert len(wire.octets) == 8 + 64  # padded to the minimum frame size

# Malformed traffic: a bad FCS, a short preamble, no padding, a short gap and the error signal
bad = eth.WireOptions(fcs="bad", preamble_octets=5, pad=False, ifg_octets=4, errors=(0,))
assert frame.to_wire(bad).error_offsets == (0,)  # counted from the first octet after the SFD
assert eth.expected_violations(frame, bad) == {
    eth.CheckId.PREAMBLE,
    eth.CheckId.FCS,
    eth.CheckId.RUNT,
    eth.CheckId.PHY_ERROR,
}

# Frames are values: they compare and hash by content
assert eth.Frame.from_bytes(frame.octets) == frame
assert len({frame, eth.Frame.from_bytes(frame.data, has_fcs=False)}) == 1
print(f"{len(wire.octets)} octets on the wire, FCS 0x{frame.fcs:08X}")
# docs-end: example
