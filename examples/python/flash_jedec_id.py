# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Read the JEDEC ID of the flash device model without a simulator.

The calls are the ones the VHDL flash makes: cs_assert when CS falls, xfer
after every byte and cs_deassert when CS rises. cs_assert and xfer return a
packed directive saying what to do with the next byte.
"""

from awesome_vunit_vcs.flash import FlashConfig, FlashDevice
from awesome_vunit_vcs.flash.directive import Action, unpack

device = FlashDevice(FlashConfig(jedec_id=0xC22018, timing_enabled=False))

# CS falls at 0 fs: the device wants the opcode, on one lane outside QPI
directive = unpack(device.cs_assert(now_fs=0))
assert directive.action is Action.RECEIVE
assert directive.lanes == 1

# The master sends 0x9F (RDID). Every answer holds the next byte to transmit,
# and xfer(-1) tells the device that the byte was clocked out.
directive = unpack(device.xfer(0x9F))
jedec_id = []
for _ in range(3):
    assert directive.action is Action.TRANSMIT
    jedec_id.append(directive.byte_out)
    directive = unpack(device.xfer(-1))

# CS rises at 1 ns. RDID starts no busy time.
assert device.cs_deassert(trailing_bits=0, now_fs=1_000_000) == 0
assert jedec_id == [0xC2, 0x20, 0x18]
assert device.get_stat("cmd_count") == 1

print("JEDEC ID:", " ".join(f"{byte:02X}" for byte in jedec_id))
