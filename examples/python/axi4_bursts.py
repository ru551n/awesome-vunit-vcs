# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Use the AXI4 burst arithmetic, monitor and protocol checker without a simulator.

The monitor and the protocol checker take the records the VHDL components
record at every rising edge of ACLK, as sample words with their times in fs;
the layout is described in awesome_vunit_vcs/axi4/bus.py.
"""

# docs-start: imports
from awesome_vunit_vcs.axi4 import (
    Axi4CheckId,
    Axi4Config,
    Axi4Monitor,
    Axi4ProtocolChecker,
    Axi4Transaction,
    BurstType,
    beat_addresses,
    beat_lanes,
    crosses_4k,
)

# docs-end: imports

# docs-start: bursts
# A WRAP burst of 4 beats of 4 bytes from 0x38 wraps at the 16-byte boundary 0x30
assert beat_addresses(0x38, length=3, size=2, burst=BurstType.WRAP) == [0x38, 0x3C, 0x30, 0x34]
# Beats of 2 bytes from 0x6 on a 64-bit bus move across the byte lanes
assert beat_lanes(0x6, length=3, size=1, burst=BurstType.INCR, data_bytes=8) == [(6, 7), (0, 1), (2, 3), (4, 5)]
# 5 beats of 4 bytes from 0xFF0 end at 0x1003, over a 4 KB boundary
assert crosses_4k(0xFF0, length=4, size=2, burst=BurstType.INCR)
# docs-end: bursts

# docs-start: monitor
PERIOD_FS = 10_000_000  # a 100 MHz clock
config = Axi4Config(data_width=32, address_width=32, id_width=4)
words: list[int] = []
times: list[int] = []


def record(cycle: int, channel: int, *fields: tuple[int, int]) -> None:
    """One handshake: the header word (VALID, READY and ARESETn 1) and the fields, 32 bits a word."""
    value = offset = 0
    for field, bits in fields:
        value |= field << offset
        offset += bits
    payload = [(value >> (32 * index)) & 0xFFFFFFFF for index in range((offset + 31) // 32)]
    header = channel | 1 << 3 | 1 << 4 | 1 << 8
    words.extend(word - (1 << 32) if word >= 1 << 31 else word for word in (header, *payload))
    times.extend([cycle * PERIOD_FS] * (1 + len(payload)))


# The clock period, then a write of 0xDDCCBBAA to 0x100 with ID 2: AW and W at cycle 1, B at cycle 4
words += [5 | 1 << 8 | 1 << 10, PERIOD_FS // 1000]
times += [0, 0]
record(1, 0, (2, 4), (0x100, 32), (0, 8), (2, 3), (1, 2), (0, 16))  # AW: ID, ADDR, LEN, SIZE, BURST, the rest 0
record(1, 1, (0xDDCCBBAA, 32), (0xF, 4), (1, 1), (0, 4))  # W: DATA, STRB, LAST, lane metavalues
record(4, 2, (2, 4), (0, 2))  # B: ID, RESP

monitor = Axi4Monitor(config, shadow_memory=True)
writes: list[Axi4Transaction] = []
monitor.transactions.subscribe(writes.append)
monitor.feed(words, times)
assert writes[0].id == 2 and writes[0].data() == bytes([0xAA, 0xBB, 0xCC, 0xDD])
statistics = monitor.statistics()
assert statistics.write.address_to_response.maximum == 3  # cycles from AW to B
print(statistics.summary("example"))

checker = Axi4ProtocolChecker(config, timeout_cycles=100)
checker.feed(words, times)
assert all(count == 0 for count in checker.counts.values())
assert checker.count(Axi4CheckId.WLAST) == 0
# docs-end: monitor
