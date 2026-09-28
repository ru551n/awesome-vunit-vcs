# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Drive an I2C target and check a bus without a simulator.

The target's calls are the ones the VHDL target makes: start at a START,
received after every byte it receives, transmitted after every byte it sends
and stop at a STOP. The monitor and the protocol checker take the samples the
VHDL monitor records: bit 0 SCL, bit 1 SDA, with the time in fs.
"""

# docs-start: imports
from awesome_vunit_vcs.i2c import Eeprom24, I2cCheckId, I2cMonitor, I2cProtocolChecker, I2cTarget, SpeedMode, bus_limits
from awesome_vunit_vcs.i2c.target import Action

# docs-end: imports

# docs-start: target
eeprom = Eeprom24(size_bytes=256, page_bytes=8, t_wr_fs=5_000_000_000_000)
target = I2cTarget(eeprom, address=0x50)

# A write of 0x42 to address 0x10: address byte, memory address, data, STOP at 10 us
target.start(now_fs=0)
acks = [target.received(value, now_fs=0).ack for value in (0xA0, 0x10, 0x42)]
target.stop(now_fs=10_000_000_000)
assert acks == [True, True, True]
assert eeprom.memory[0x10] == 0x42

# During the 5 ms write cycle the EEPROM does not acknowledge its address
target.start(now_fs=20_000_000_000)
assert not target.received(0xA0, now_fs=20_000_000_000).ack
target.stop(now_fs=30_000_000_000)

# After it, a read returns the byte at the current address, 0x11, still erased
target.start(now_fs=6_000_000_000_000)
directive = target.received(0xA1, now_fs=6_000_000_000_000)
assert directive.ack and directive.action is Action.TRANSMIT
assert directive.byte_out == 0xFF
# docs-end: target

# docs-start: monitor
NS = 1_000_000
words, times = [], []


def sample(scl: int, sda: int, time_ns: int) -> None:
    words.append(scl | sda << 1)
    times.append(time_ns * NS)


# A START, the address 0x50 with W clocked with 500 ns high and low times, and a STOP
sample(1, 1, 0)
sample(1, 0, 1000)
time_ns = 1600
for bit in (1, 0, 1, 0, 0, 0, 0, 0, 0):
    sample(0, bit, time_ns)
    sample(1, bit, time_ns + 500)
    time_ns += 1000
sample(0, 0, time_ns)
sample(1, 0, time_ns + 500)
sample(1, 1, time_ns + 1100)

monitor = I2cMonitor()
monitor.transfers.subscribe(print)
monitor.feed(words, times)

checker = I2cProtocolChecker(bus_limits(SpeedMode.FAST))
checker.feed(words, times)
# 1 MHz is too fast for Fast-mode, and 500 ns is too short for its tLOW
assert checker.count(I2cCheckId.F_SCL) > 0 and checker.count(I2cCheckId.T_LOW) > 0
# docs-end: monitor
