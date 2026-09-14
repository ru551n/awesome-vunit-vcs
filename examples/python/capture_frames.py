# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Write frames to PCAPNG files that Wireshark opens.

A capture never contains the preamble or the SFD. Received frames keep their
simulation timestamps and error flags; built frames are timed as if sent back
to back.
"""

# docs-start: example

from awesome_vunit_vcs import ethernet as eth

frames = [eth.Frame.from_payload(bytes(size)) for size in (46, 100, 1500)]
assert eth.write_pcapng("frames.pcapng", frames) == 3

# A monitor captures what it receives, here without the FCS
with eth.Monitor(eth.XGMII()) as rx:
    rx.capture("received.pcapng", fcs=False)
    rx.feed_frames(frames)
assert rx.frames == [frame.padded() for frame in frames]
# docs-end: example
