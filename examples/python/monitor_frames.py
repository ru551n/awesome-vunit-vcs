# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Run the monitor pipeline of a VHDL monitor in plain Python.

GMII samples, one word per clock cycle, go through the PHY decoder into
frames. The frames fan out to the protocol checker, the statistics, a PCAPNG
capture and any subscriber you add: the same objects a VHDL monitor uses.
"""

import numpy as np

from awesome_vunit_vcs.ethernet import (
    CaptureOptions,
    CheckId,
    EthernetConfig,
    EthernetMonitor,
    FcsMode,
    build_wire_frame,
    create_phy,
)

mac_octets = bytes.fromhex("020000000001 020000000002 88b5") + bytes(range(100))

# The PHY decoder and encoder of an interface are created by name
phy = create_phy("gmii", link_rate_bps=1_000_000_000)
monitor = EthernetMonitor(phy, EthernetConfig(max_frame_octets=1522), name="rx")

# Subscribers are called with every frame and every violation, in order
frames = []
violations = []
monitor.frames.subscribe(frames.append)
monitor.checker.violations.subscribe(violations.append)

# Frames are written as they arrive; the capture has no preamble or SFD
capture = monitor.start_capture("rx.pcapng", CaptureOptions(include_fcs=True, include_errored=True))

# Sample words the way the VHDL monitor records them: data, valid and error
# bits of each clock cycle with its time in femtoseconds (8 ns at 1G). The line
# is idle first; a frame already in progress at the first sample is reported.
words = np.concatenate(
    [
        np.zeros(12, dtype=np.int32),
        phy.encode(build_wire_frame(mac_octets)),
        phy.encode(build_wire_frame(mac_octets, fcs=FcsMode.BAD)),
        phy.encode(build_wire_frame(mac_octets, ifg_octets=4)),
        phy.encode(build_wire_frame(mac_octets)),
    ]
).astype(np.int64)
times = np.arange(words.size, dtype=np.int64) * 8_000_000
monitor.feed(words, times)
monitor.stop_captures()

assert [frame.index for frame in frames] == [0, 1, 2, 3]
assert frames[0].is_good and frames[0].mac_octets == mac_octets
assert frames[0].timestamp_sfd_fs == (12 + 7) * 8_000_000  # 12 idle cycles, 7 preamble octets
assert frames[1].fcs_ok is False
assert frames[3].ifg_octets == 4  # the gap before a frame is measured on that frame

# A violation names its check and carries a readable message
assert [violation.check for violation in violations] == [CheckId.FCS, CheckId.IFG]
print(violations[0].message)

# Checks are individually disabled and counted
monitor.checker.disable(CheckId.IFG)
assert monitor.checker.count(CheckId.FCS) == 1

statistics = monitor.statistics.snapshot()
assert (statistics.total_frames, statistics.good_frames, statistics.fcs_errors) == (4, 3, 1)
assert statistics.payload_octets == 4 * 100
assert capture.frames_written == 4
print(statistics.summary("rx"))
