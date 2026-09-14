# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Traffic functions the HDL tests give to push_ethernet_packet and the sequence procedures."""

from __future__ import annotations

import random
from collections.abc import Iterator

HEADER = bytes.fromhex("02000000000102000000000288B5")


def udp_packet(dport: int = 1234) -> bytes:
    """A UDP packet built with Scapy, destination 02:00:00:00:00:01."""
    from scapy.all import IP, UDP, Ether, Raw

    return bytes(Ether(dst="02:00:00:00:00:01") / IP(dst="192.168.1.10") / UDP(dport=dport) / Raw(b"hello"))


def counting_frame(size: int = 60) -> bytes:
    """A frame of size octets from the destination address: the header and a counting payload."""
    return HEADER + bytes(index % 256 for index in range(size - len(HEADER)))


def random_frames(min_size: int = 60, max_size: int = 1514, seed: str = "") -> Iterator[bytes]:
    """Frames of random size and payload, the same for the same seed; never ends."""
    rnd = random.Random(seed)
    while True:
        size = rnd.randint(min_size, max_size)
        yield HEADER + rnd.randbytes(size - len(HEADER))
