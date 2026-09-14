# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
A user subscriber added to a running GMII monitor.

tb_gmii_example.vhd executes this file in the Python session of the monitor,
where the backend of the monitor is the object ``vc``. It subscribes to the
frames the monitor reconstructs; the testbench then reads the result with
eval. A subscriber sees frames, never signals, and an exception it raises
becomes a failure on the logger of the monitor.
"""

from awesome_vunit_vcs.ethernet import EthernetFrame

frame_sizes: list[int] = []


def record_frame_size(frame: EthernetFrame) -> None:
    frame_sizes.append(len(frame.mac_octets))


vc.monitor.frames.subscribe(record_frame_size)  # type: ignore[name-defined]  # noqa: F821
