# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A device model of examples/mdio: a PHY whose reset bit clears itself and whose link comes up later."""

# docs-start: link-phy
from collections.abc import Sequence

from awesome_vunit_vcs.common.vunit_bridge import decode_time_fs
from awesome_vunit_vcs.mdio import MdioDevice

CONTROL = 0
STATUS = 1
RESET = 0x8000
LINK_UP = 0x0004


class LinkPhy(MdioDevice):
    """
    The link is up from ``link_up_fs`` on, a time as ``kwarg_time`` sends it or in fs; a reset
    (bit 15 of register 0) clears itself.
    """

    def __init__(self, link_up_fs: int | Sequence[int], phy_id: int = 0x01410E40) -> None:
        super().__init__(registers={CONTROL: 0x1140, STATUS: 0x7969, 2: phy_id >> 16, 3: phy_id & 0xFFFF})
        self.link_up_fs = decode_time_fs(link_up_fs)

    def read(self, register_address: int, now_fs: int) -> int:
        value = super().read(register_address, now_fs)
        if register_address == STATUS and now_fs >= self.link_up_fs:
            value |= LINK_UP
        return value

    def write(self, register_address: int, value: int, now_fs: int) -> None:
        if register_address == CONTROL:
            value &= ~RESET
        super().write(register_address, value, now_fs)


# docs-end: link-phy
