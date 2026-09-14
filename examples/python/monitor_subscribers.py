# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
React to frames and violations as a Monitor finds them, with subscribers.
"""

from awesome_vunit_vcs import ethernet as eth

# docs-start: subscribers
rx = eth.Monitor(eth.GMII)
sizes: list[int] = []
problems: list[str] = []


@rx.on_frame  # called with every Frame received from now on
def record_size(frame: eth.Frame) -> None:
    sizes.append(len(frame.data))


@rx.on_violation  # called with every Violation, before the frame it concerns
def record_problem(violation: eth.Violation) -> None:
    problems.append(f"{violation.check.name} on frame {violation.frame_index} at {violation.timestamp_fs} fs")


rx.on_frame(lambda frame: print(frame.index, frame.ok))  # the same without a decorator

good = eth.Frame.from_payload(bytes(100))
bad = eth.Frame.from_payload(bytes(46)).to_wire(eth.WireOptions(fcs="bad"))
with rx:
    rx.feed_frames([good, bad])
# docs-end: subscribers

assert sizes == [114, 60]
assert len(problems) == 1 and problems[0].startswith("FCS on frame 1 at ")
assert [frame.ok for frame in rx.frames] == [True, False]
