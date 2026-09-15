# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A subscriber tb_cookbook.vhd runs in the Python session of its monitor, where ``vc`` is the monitor."""

# docs-start: subscriber
from awesome_vunit_vcs.ethernet import Frame
from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend

vc: MonitorBackend = globals()["vc"]


@vc.on_frame
def check_frame_size(frame: Frame) -> None:
    if len(frame.data) > 100:
        vc.error("ETH_USER", f"frame {frame.index} has {len(frame.data)} octets, more than 100")


# docs-end: subscriber
