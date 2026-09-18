# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The I2C family: bus decoding, protocol checks, a master's transfers and target device models.

The VHDL components (``vhdl/i2c``) drive and sample SCL and SDA with the
timing of the bus and nothing else. Everything the bits mean lives here and
works without a simulator:

* :mod:`~awesome_vunit_vcs.i2c.bus`: SCL and SDA samples to START, STOP and bit events
* :mod:`~awesome_vunit_vcs.i2c.transfer`: events to transfers, with reserved and 10-bit addresses
* :mod:`~awesome_vunit_vcs.i2c.monitor`: transfers and statistics
* :mod:`~awesome_vunit_vcs.i2c.checker`: the timing and protocol checks, each with a :class:`CheckId`
* :mod:`~awesome_vunit_vcs.i2c.timing`: the speed modes and their limits
* :mod:`~awesome_vunit_vcs.i2c.master`: transfers compiled into operations for the VHDL master
* :mod:`~awesome_vunit_vcs.i2c.target` and :mod:`~awesome_vunit_vcs.i2c.devices`: the target's
  protocol engine and its device models
* :mod:`~awesome_vunit_vcs.i2c.pec`: the SMBus PEC
* :mod:`~awesome_vunit_vcs.i2c.vunit_backend`: the objects the VHDL components create

Times are integers in femtoseconds (fs), frequencies in Hz.
"""

from __future__ import annotations

from .checker import CheckId, I2cProtocolChecker, Violation
from .devices import Eeprom24, I2cDevice, RegisterDevice
from .errors import I2cError, I2cValueError
from .master import I2cResult, I2cStatus, compile_ops, compile_transfer
from .monitor import I2cMonitor, I2cStatistics
from .pec import smbus_pec
from .target import I2cTarget
from .timing import BusLimits, MasterTiming, SpeedMode, bus_limits, master_timing
from .transfer import AddressKind, I2cTransfer

__all__ = [
    "AddressKind",
    "BusLimits",
    "CheckId",
    "Eeprom24",
    "I2cDevice",
    "I2cError",
    "I2cMonitor",
    "I2cProtocolChecker",
    "I2cResult",
    "I2cStatistics",
    "I2cStatus",
    "I2cTarget",
    "I2cTransfer",
    "I2cValueError",
    "MasterTiming",
    "RegisterDevice",
    "SpeedMode",
    "Violation",
    "bus_limits",
    "compile_ops",
    "compile_transfer",
    "master_timing",
    "smbus_pec",
]
