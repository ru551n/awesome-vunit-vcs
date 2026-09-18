# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
SMBus Packet Error Checking: CRC-8 with the polynomial x^8 + x^2 + x + 1 (0x07).

The PEC covers every byte of a transaction as it appears on the bus, address
bytes with their R/W bit included, from the START to the PEC byte. A receiver
that runs the CRC over the bytes and the PEC gets 0.
"""

from __future__ import annotations

from collections.abc import Iterable

__all__ = ["pec_update", "smbus_pec"]


def _table() -> tuple[int, ...]:
    table = []
    for value in range(256):
        crc = value
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07 if crc & 0x80 else crc << 1) & 0xFF
        table.append(crc)
    return tuple(table)


_TABLE = _table()


def pec_update(crc: int, value: int) -> int:
    """The CRC-8 after one more byte."""
    return _TABLE[(crc ^ value) & 0xFF]


def smbus_pec(data: Iterable[int], crc: int = 0) -> int:
    """
    The SMBus PEC of bytes.

    Args:
        data: The bytes, address bytes included.
        crc: The CRC of the bytes before these, 0 at the START.
    """
    for value in data:
        crc = pec_update(crc, value)
    return crc
