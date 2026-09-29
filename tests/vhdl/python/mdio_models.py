# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A device model of tb_mdio_phy_vci: a PHY ID and a reset bit that clears itself."""

from __future__ import annotations

from awesome_vunit_vcs.mdio import MdioDevice


class SelfClearingReset(MdioDevice):
    """Register 2 is ``id_1``; bit 15 of register 0 reads 0 after a write."""

    def __init__(self, id_1: int = 0) -> None:
        super().__init__(registers={2: id_1})

    def write(self, register_address: int, value: int, now_fs: int) -> None:
        if register_address == 0:
            value &= 0x7FFF
        super().write(register_address, value, now_fs)
