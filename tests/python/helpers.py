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


# XGMII control characters, IEEE 802.3 Table 46-3 as reproduced in Xilinx
# XAPP687 Table 2, and the link fault ordered sets of Table 46-5 as used by the
# UNH-IOL Clause 49 PCS test suite
XGMII_IDLE = 0x07
XGMII_START = 0xFB
XGMII_TERMINATE = 0xFD
XGMII_ERROR = 0xFE
XGMII_SEQUENCE = 0x9C
XGMII_CONTROL = 1 << 8
XGMII_10G_OCTET_FS = 800_000


@dataclass
class XgmiiLine:
    """
    Builds XGMII columns lane by lane, the way the VHDL monitor records them.

    A frame is written as the standard describes it: Start in place of the
    first preamble octet, data lanes, Terminate, then Idle up to the end of
    the column and for ``idle_columns`` more columns.
    """

    lanes: int = 4
    octet_fs: int = XGMII_10G_OCTET_FS
    time_fs: int = 0
    lane: int = 0
    words: list[int] = field(default_factory=list)
    times: list[int] = field(default_factory=list)

    def lane_word(self, word: int) -> None:
        self.words.append(word)
        self.times.append(self.time_fs)
        self.lane += 1
        if self.lane == self.lanes:
            self.lane = 0
            self.time_fs += self.lanes * self.octet_fs

    def control(self, code: int) -> None:
        self.lane_word(code | XGMII_CONTROL)

    def data(self, octets: bytes) -> None:
        for octet in octets:
            self.lane_word(octet)

    def idle_columns(self, columns: int) -> None:
        for _ in range(columns * self.lanes):
            self.control(XGMII_IDLE)

    def fill_column(self) -> None:
        while self.lane:
            self.control(XGMII_IDLE)

    def frame(
        self,
        frame: bytes,
        *,
        preamble: bytes = b"\x55" * 6 + b"\xd5",
        error_offsets: tuple[int, ...] = (),
        terminate: bool = True,
        idle_columns: int = 1,
    ) -> None:
        """``error_offsets`` index the octets after Start (0 is the first preamble octet after it)."""
        assert self.lane == 0, "frames start on lane 0"
        self.control(XGMII_START)
        for offset, octet in enumerate(preamble + frame):
            if offset in error_offsets:
                self.control(XGMII_ERROR)
            else:
                self.lane_word(octet)
        if terminate:
            self.control(XGMII_TERMINATE)
        self.fill_column()
        self.idle_columns(idle_columns)
