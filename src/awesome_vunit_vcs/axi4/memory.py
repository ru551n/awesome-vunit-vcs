# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The shadow memory scoreboard of the AXI4 monitor: reads must return what was written last.

A write takes effect at its B handshake, and only the bytes its WSTRB selects: a normal write with an
OKAY response, an exclusive write with an EXOKAY response. A read with an OKAY or EXOKAY response may
return, for each byte, the value it had at the read's AR handshake or a value written between the AR
handshake and the read's last beat, since the slave may order overlapping accesses either way. Bytes
never written or loaded are not checked.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Iterable

from .transaction import Axi4Transaction, Response

__all__ = ["ShadowMemory"]


class ShadowMemory:
    """
    The bytes an interface wrote, with enough history to judge reads that overlap writes.

    Args:
        history: The values kept per byte address. A byte whose value at the time of a read is older
            than the values kept is not checked.
    """

    def __init__(self, history: int = 16) -> None:
        self.history = history
        self._bytes: dict[int, deque[tuple[int, int]]] = {}
        self._truncated: set[int] = set()

    def clear(self) -> None:
        """Forget every byte."""
        self._bytes.clear()
        self._truncated.clear()

    def write(self, address: int, value: int, time_fs: int = 0) -> None:
        """Set one byte from ``time_fs`` on."""
        entries = self._bytes.setdefault(address, deque(maxlen=self.history))
        if len(entries) == self.history:
            self._truncated.add(address)
        entries.append((time_fs, value & 0xFF))

    def load(self, address: int, data: bytes | Iterable[int], time_fs: int = 0) -> None:
        """Set bytes from ``address`` on, as a memory initialized before the test."""
        for offset, value in enumerate(data):
            self.write(address + offset, value, time_fs)

    def value(self, address: int) -> int | None:
        """The latest value of a byte, None if it was never written."""
        entries = self._bytes.get(address)
        return entries[-1][1] if entries else None

    def allowed(self, address: int, since_fs: int, until_fs: int) -> set[int] | None:
        """
        The values a read may return for a byte: its value at ``since_fs`` and those written up to
        ``until_fs``. None when the byte is unknown at ``since_fs``.
        """
        entries = self._bytes.get(address)
        if not entries:
            return None
        values = {value for time_fs, value in entries if since_fs < time_fs <= until_fs}
        before = [value for time_fs, value in entries if time_fs <= since_fs]
        if before:
            values.add(before[-1])
        elif address in self._truncated:
            return None
        return values or None

    def commit(self, transaction: Axi4Transaction) -> bool:
        """Apply a write at its B handshake. Returns whether it took effect."""
        if not transaction.is_write:
            return False
        expected = Response.EXOKAY if transaction.exclusive else Response.OKAY
        if transaction.resp != expected:
            return False
        for address, value in transaction.transferred_bytes():
            self.write(address, value, transaction.response_fs)
        return True

    def check(self, transaction: Axi4Transaction) -> list[str]:
        """
        Compare a read with the memory.

        Returns:
            One line per byte that differs, with its address, the value read and the values allowed; empty
            for a write, a read with an error response, or a read of unknown bytes.
        """
        if transaction.is_write or transaction.resp not in (Response.OKAY, Response.EXOKAY):
            return []
        differences = []
        for address, value in transaction.transferred_bytes():
            allowed = self.allowed(address, transaction.address_fs, transaction.last_data_fs)
            if allowed is not None and value not in allowed:
                expected = " or ".join(f"0x{v:02X}" for v in sorted(allowed))
                differences.append(f"0x{address:X}: read 0x{value:02X}, expected {expected}")
        return differences
