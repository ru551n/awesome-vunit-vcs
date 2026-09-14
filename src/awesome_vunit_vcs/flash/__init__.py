# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Python device model of a generic JEDEC QSPI NOR flash.

The VHDL verification component (``vhdl/flash/flash.vhd``) owns pins and
time and nothing else: every byte of device behaviour -- the opcode table,
the array, protection, timing, SFDP -- lives here, because a protocol state
machine is far cheaper to write, read and unit test in Python than in VHDL,
and because the same model can then be exercised with no simulator in the
loop::

    from awesome_vunit_vcs.flash import FlashConfig, FlashDevice

    device = FlashDevice(FlashConfig(size_bytes=32 * 1024 * 1024, addr_bytes=4))

Layering, outermost first:

* ``vunit_backend``: the object the VHDL component creates. It converts
  arguments, turns exceptions into reports and delegates. It holds no
  device logic.
* ``device``: the protocol state machine -- ``cs_assert`` / ``xfer`` /
  ``cs_deassert``, status registers, the page-program latch.
* ``commands``: the JEDEC opcode table as *data*. Adding an opcode is a
  table entry, never a new branch.
* ``array``: the storage. NOR program/erase semantics (program is AND-only,
  erase sets 0xFF) live here and nowhere else.
* ``config``, ``protection``, ``timing``, ``mode``, ``sfdp``, ``images``,
  ``directive``: one concern each.

``directive.LAYOUT_VERSION`` is the run-time guard against the VHDL and
Python halves of the packed directive drifting apart.
"""

from __future__ import annotations

from .config import AddrModes, FlashConfig
from .device import ContentMismatch, FlashDevice
from .directive import LAYOUT_VERSION

__all__ = ["LAYOUT_VERSION", "AddrModes", "ContentMismatch", "FlashConfig", "FlashDevice"]
