# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Python device model of a generic JEDEC QSPI NOR flash.

The VHDL verification component (``vhdl/flash/flash.vhd``) owns pins and
time and nothing else. Every byte of device behavior -- the opcode table,
the array, protection, busy timing, SFDP -- lives here, because a protocol
state machine is far cheaper to write, read and unit test in Python than in
VHDL, and because the same model can then be exercised with no simulator in
the loop::

    from awesome_vunit_vcs.flash import FlashConfig, FlashDevice

    device = FlashDevice(FlashConfig(size_bytes=32 * 1024 * 1024, addr_bytes=4))

Sizes, addresses and lengths are in bytes. Times are integers in
femtoseconds (fs).

Layering, outermost first:

* :mod:`~awesome_vunit_vcs.flash.vunit_backend`: the object the VHDL
  component creates. It converts arguments, turns exceptions into reports
  and delegates. It holds no device logic.
* :mod:`~awesome_vunit_vcs.flash.device`: the protocol state machine --
  ``cs_assert`` / ``xfer`` / ``cs_deassert``, status registers, the
  page-program latch.
* :mod:`~awesome_vunit_vcs.flash.commands`: the JEDEC opcode table as
  *data*. Adding an opcode is a table entry, never a new branch.
* :mod:`~awesome_vunit_vcs.flash.array`: the storage. NOR program/erase
  semantics (program is AND-only, erase sets 0xFF) live here and nowhere
  else.
* :mod:`~awesome_vunit_vcs.flash.config`,
  :mod:`~awesome_vunit_vcs.flash.protection`,
  :mod:`~awesome_vunit_vcs.flash.timing`,
  :mod:`~awesome_vunit_vcs.flash.mode`,
  :mod:`~awesome_vunit_vcs.flash.sfdp`,
  :mod:`~awesome_vunit_vcs.flash.images` and
  :mod:`~awesome_vunit_vcs.flash.directive`: one concern each.

:data:`~awesome_vunit_vcs.flash.directive.LAYOUT_VERSION` is the run-time
guard against the VHDL and Python halves of the packed directive drifting
apart.

The package exports :class:`~awesome_vunit_vcs.flash.config.AddrModes`,
:class:`~awesome_vunit_vcs.flash.config.FlashConfig`,
:class:`~awesome_vunit_vcs.flash.device.FlashDevice`,
:data:`~awesome_vunit_vcs.flash.directive.LAYOUT_VERSION` and the
exceptions of :mod:`~awesome_vunit_vcs.flash.errors`:
:class:`~awesome_vunit_vcs.flash.errors.FlashError`, its subclass
:class:`~awesome_vunit_vcs.flash.errors.FlashValueError`, raised for every
invalid argument or configuration, and its subclass
:class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`, raised by a
content check that fails.
"""

from __future__ import annotations

from .config import AddrModes, FlashConfig
from .device import FlashDevice
from .directive import LAYOUT_VERSION
from .errors import ContentMismatch, FlashError, FlashValueError

__all__ = [
    "LAYOUT_VERSION",
    "AddrModes",
    "ContentMismatch",
    "FlashConfig",
    "FlashDevice",
    "FlashError",
    "FlashValueError",
]
