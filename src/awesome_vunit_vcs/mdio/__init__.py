# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The MDIO family: Clause 22 management frames, their checks and PHY device models.

The VHDL components (``vhdl/mdio``) drive and sample MDC and MDIO with the timing
of the bus. What the frames mean lives here and works without a simulator:

* :mod:`~awesome_vunit_vcs.mdio.phy`: the protocol engine of the PHY, with the checks, each with an
  :class:`~awesome_vunit_vcs.mdio.phy.MdioCheckId`
* :mod:`~awesome_vunit_vcs.mdio.devices`: the register file of the PHY and the base of device models
* :mod:`~awesome_vunit_vcs.mdio.vunit_backend`: the object the VHDL PHY creates

Times are integers in femtoseconds (fs).
"""

from __future__ import annotations

from .devices import NUM_REGISTERS, MdioDevice
from .errors import MdioError, MdioValueError
from .phy import MdioAccess, MdioCheckId, MdioOperation, MdioPhy, MdioViolation

__all__ = [
    "NUM_REGISTERS",
    "MdioAccess",
    "MdioCheckId",
    "MdioDevice",
    "MdioError",
    "MdioOperation",
    "MdioPhy",
    "MdioValueError",
    "MdioViolation",
]
