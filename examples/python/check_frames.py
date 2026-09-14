# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Check frames and collect statistics with a Monitor, the pipeline of a VHDL monitor.
"""

from awesome_vunit_vcs import ethernet as eth

frame = eth.Frame.from_payload(bytes(100))
short_gap = frame.to_wire(eth.WireOptions(ifg_octets=4))

with eth.Monitor(eth.GMII) as rx:
    rx.feed_frames([frame, frame.to_wire(eth.WireOptions(fcs="bad")), short_gap, frame])
    # Checks are disabled and enabled by name, from now on
    rx.disable("ETH_IFG")
    rx.feed_frames([short_gap, frame])

# Every violation names its check and carries a readable message
assert [violation.check for violation in rx.violations] == [eth.CheckId.FCS, eth.CheckId.IFG]
print(rx.violations[0].message)
assert not rx.frames[1].ok  # the frame with the bad FCS
assert rx.count("ETH_IFG") == 1  # the second short gap was not checked

statistics = rx.statistics
assert (statistics.total_frames, statistics.good_frames, statistics.fcs_errors) == (6, 5, 1)
print(statistics.summary("rx"))
