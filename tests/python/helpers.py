"""
Independent reference implementations for the tests.

Nothing here imports the package under test: frames on the wire are built
octet by octet and the FCS is computed with a bitwise CRC-32, so that tests
never compare the implementation against itself.
"""

from __future__ import annotations

import random
import struct
from dataclasses import dataclass, field

GMII_PERIOD_FS = 8_000_000  # 125 MHz
VALID = 1 << 8
ERROR = 1 << 9
META_DATA = 1 << 10
META_CTRL = 1 << 11


def reference_crc32(data: bytes) -> int:
    """Bitwise reflected CRC-32 (polynomial 0x04C11DB7), as specified by IEEE 802.3."""
    crc = 0xFFFFFFFF
    for octet in data:
        crc ^= octet
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def reference_frame(payload: bytes, *, pad_to: int = 60, bad_fcs: bool = False) -> bytes:
    """Destination address .. FCS for a payload, padded like a MAC does."""
    body = payload + bytes(max(0, pad_to - len(payload)))
    crc = reference_crc32(body)
    if bad_fcs:
        crc ^= 0x10000000
    return body + struct.pack("<I", crc)


def ethernet_payload(length: int, seed: int = 0, dst: bytes = b"\x02\x00\x00\x00\x00\x01") -> bytes:
    """A payload of length octets starting with a unicast header and IPv4 EtherType."""
    rng = random.Random(seed)
    header = dst + b"\x02\x00\x00\x00\x00\x02" + b"\x08\x00"
    return (header + bytes(rng.randrange(256) for _ in range(max(0, length - len(header)))))[:length]


@dataclass
class GmiiLine:
    """Records GMII samples the way the VHDL monitor does: every clock cycle."""

    period_fs: int = GMII_PERIOD_FS
    time_fs: int = 0
    words: list[int] = field(default_factory=list)
    times: list[int] = field(default_factory=list)

    def cycle(self, word: int) -> None:
        self.words.append(word)
        self.times.append(self.time_fs)
        self.time_fs += self.period_fs

    def idle(self, cycles: int) -> None:
        for _ in range(cycles):
            self.cycle(0)

    def frame(
        self,
        frame: bytes,
        *,
        preamble: bytes = b"\x55" * 7 + b"\xd5",
        error_offsets: tuple[int, ...] = (),
        ifg: int = 12,
    ) -> None:
        for offset, octet in enumerate(preamble + frame):
            self.cycle(octet | VALID | (ERROR if offset in error_offsets else 0))
        self.idle(ifg)
