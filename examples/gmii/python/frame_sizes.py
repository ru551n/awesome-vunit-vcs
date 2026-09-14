# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
A user subscriber added to a running GMII monitor.

tb_gmii_example.vhd executes this file in the Python session of the monitor,
where the backend of the monitor is the object ``vc``. The subscriber gets
every frame the monitor reconstructs; the testbench then reads the result
with eval. A subscriber sees frames, never signals: it reports what it finds
with vc.error, a counted check error, while an exception it raises becomes a
failure on the logger of the monitor.
"""

from awesome_vunit_vcs.ethernet import Frame
from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend

vc: MonitorBackend = globals()["vc"]
frame_sizes: list[int] = []


@vc.on_frame
def record_frame_size(frame: Frame) -> None:
    frame_sizes.append(len(frame.data))
    if len(frame.data) > 1514:
        vc.error("ETH_SCOREBOARD", f"frame {frame.index} is longer than this test sends")
