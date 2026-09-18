# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The memory behind the AXI4 read and write slaves: VUnit's ``memory_t`` on a sparse store.

A :class:`MemoryModel` has what VUnit's ``memory_pkg`` has -- per-byte permissions, expected data,
named buffers, words with an endianness -- on top of
:class:`~awesome_vunit_vcs.common.sparse_memory.SparseMemory`, so a 64-bit address space costs
nothing until it is touched, and a permission or a fill over a gigabyte is one run.

Accesses do not raise when they break a rule. Like VUnit's memory they return what they could do and
the failures, as messages worded like VUnit's (``Reading from address 5 at offset 3 within buffer
'b' at range (2 to 11) without permission (no_access)``), which the backend logs as check failures.
One message is produced per access and rule, naming the first byte and how many more there are.

Addresses and sizes are in bytes.
"""

from __future__ import annotations

import enum
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import numpy.typing as npt

from ..common.sparse_memory import SparseMemory
from ..flash import images
from .errors import Axi4ValueError

__all__ = ["Buffer", "Endianness", "MemoryModel", "Permission"]


class Permission(enum.IntEnum):
    """What a slave may do with a byte; the values are the positions of VUnit's ``permissions_t``."""

    NO_ACCESS = 0
    WRITE_ONLY = 1
    READ_ONLY = 2
    READ_AND_WRITE = 3


class Endianness(enum.IntEnum):
    """The byte order of words; the values are the positions of VUnit's ``endianness_arg_t``."""

    LITTLE = 0
    BIG = 1


@dataclass(frozen=True)
class Buffer:
    """
    An allocated region of a memory.

    Attributes:
        name: The name given at allocation, empty for an anonymous buffer.
        address: The first address.
        num_bytes: The size.
    """

    name: str
    address: int
    num_bytes: int

    @property
    def last_address(self) -> int:
        """The last address, ``address + num_bytes - 1``."""
        return self.address + self.num_bytes - 1


class MemoryModel:
    """
    A sparse memory with permissions, expected data and buffers.

    Args:
        size_bytes: The number of addresses, or None for the whole 64-bit space. An access beyond it
            is a failure, ``address N out of range 0 to M``.
        default_value: The value of a byte never written.
        default_permission: The permission of a byte never allocated or given one. ``NO_ACCESS``
            makes slaves fail on anything not allocated, like VUnit's memory; ``READ_AND_WRITE``
            makes the memory a plain RAM.
        endian: The byte order of words when a call does not give one.
        page_bytes: The unit the sparse stores materialize bytes in.

    Attributes:
        data: The content.
        buffers: The allocated buffers, in allocation order.
        endian: The default byte order.
    """

    def __init__(
        self,
        size_bytes: int | None = None,
        default_value: int = 0,
        default_permission: Permission = Permission.READ_AND_WRITE,
        endian: Endianness = Endianness.LITTLE,
        page_bytes: int = 4096,
    ) -> None:
        if size_bytes is not None and size_bytes <= 0:
            raise Axi4ValueError(f"The memory size {size_bytes} is not positive")
        self.size_bytes = size_bytes
        self.endian = Endianness(endian)
        self.data = SparseMemory(page_bytes=page_bytes, default=default_value)
        self._permissions = SparseMemory(page_bytes=page_bytes, default=Permission(default_permission))
        self._expected = SparseMemory(page_bytes=page_bytes)
        # 1 where a byte has an expected value
        self._has_expected = SparseMemory(page_bytes=page_bytes)
        self.buffers: list[Buffer] = []
        self._next_address = 0

    # -- buffers ---------------------------------------------------------

    def clear(self) -> None:
        """Forget the content, permissions, expected data and buffers, like VUnit's ``clear``."""
        for store in (self.data, self._permissions, self._expected, self._has_expected):
            store.clear()
        self.buffers.clear()
        self._next_address = 0

    @property
    def num_bytes(self) -> int:
        """The end of the last buffer :meth:`allocate` placed, where the next one starts."""
        return self._next_address

    def allocate(
        self,
        num_bytes: int,
        name: str = "",
        alignment: int = 1,
        permission: Permission = Permission.READ_AND_WRITE,
        address: int | None = None,
    ) -> Buffer:
        """
        Allocate a buffer and give its bytes a permission.

        Args:
            num_bytes: The size.
            name: The name in failure messages.
            alignment: The alignment of an automatically placed buffer.
            permission: The permission of the bytes of the buffer.
            address: Where the buffer starts; None places it after the last one placed this way, aligned,
                as VUnit does. A buffer at an address given here does not move where the next one is placed.

        Returns:
            The buffer.

        Raises:
            Axi4ValueError: The alignment is not positive, or the buffer does not fit the memory.
        """
        if alignment <= 0 or num_bytes < 0:
            raise Axi4ValueError(f"Cannot allocate {num_bytes} bytes with the alignment {alignment}")
        if address is None:
            address = -(-self._next_address // alignment) * alignment
            self._next_address = address + num_bytes
        if address < 0 or (self.size_bytes is not None and address + num_bytes > self.size_bytes):
            raise Axi4ValueError(f"A buffer of {num_bytes} bytes at {address} does not fit the memory")
        buffer = Buffer(name, address, num_bytes)
        self.buffers.append(buffer)
        self._permissions.fill(address, num_bytes, permission)
        return buffer

    def buffer_at(self, address: int) -> Buffer | None:
        """The buffer holding an address, the first allocated if several overlap."""
        # ponytail: linear scan, only failure messages describe addresses; bisect if that ever shows up
        return next((b for b in self.buffers if b.address <= address <= b.last_address), None)

    def describe_address(self, address: int) -> str:
        """The address with its buffer, worded like VUnit's ``describe_address``."""
        buffer = self.buffer_at(address)
        if buffer is None:
            return f"address {address} at unallocated location"
        description = f"buffer '{buffer.name}'" if buffer.name else "anonymous buffer"
        return (
            f"address {address} at offset {address - buffer.address} within {description} at range "
            f"({buffer.address} to {buffer.last_address})"
        )

    # -- checks ------------------------------------------------------------

    def _in_range(self, address: int, length: int, reading: bool, failures: list[str]) -> int:
        """The number of bytes from ``address`` on inside the memory; a failure for the others."""
        limit = self.size_bytes if self.size_bytes is not None else 2**64
        inside = max(0, min(length, limit - address))
        if inside < length:
            verb = "Reading from" if reading else "Writing to"
            first = max(address, limit)
            failures.append(_more(f"{verb} address {first} out of range 0 to {limit - 1}", length - inside - 1))
        return inside

    def _allowed(
        self, address: int, length: int, reading: bool, failures: list[str], touched: npt.NDArray[np.bool_]
    ) -> npt.NDArray[np.bool_]:
        """For each byte, whether the permissions allow the access; a failure for the touched others."""
        permissions = np.frombuffer(self._permissions.read(address, length), dtype=np.uint8)
        denied = (permissions == Permission.NO_ACCESS) | (
            permissions == (Permission.WRITE_ONLY if reading else Permission.READ_ONLY)
        )
        denied &= touched
        if denied.any():
            offset = int(np.argmax(denied))
            verb = "Reading from" if reading else "Writing to"
            name = Permission(int(permissions[offset])).name.lower()
            message = f"{verb} {self.describe_address(address + offset)} without permission ({name})"
            failures.append(_more(message, int(denied.sum()) - 1))
        allowed: npt.NDArray[np.bool_] = ~denied
        return allowed

    # -- access ----------------------------------------------------------

    def access(
        self,
        address: int,
        length: int,
        reading: bool,
        check_permissions: bool = True,
        touched: npt.NDArray[np.bool_] | None = None,
    ) -> tuple[npt.NDArray[np.bool_], list[str]]:
        """
        Which bytes of a range an access may touch: those inside the memory, and with
        ``check_permissions`` those the permissions allow.

        Args:
            address: The first address.
            length: The number of bytes.
            reading: A read; a write otherwise.
            check_permissions: Check the permissions too.
            touched: The bytes the access touches, all when None; only those can fail.

        Returns:
            One boolean per byte, and a failure for each rule broken.
        """
        failures: list[str] = []
        touched = np.ones(length, dtype=np.bool_) if touched is None else touched
        allowed = np.ones(length, dtype=np.bool_)
        inside = self._in_range(address, int(np.flatnonzero(touched).max(initial=-1)) + 1, reading, failures)
        allowed[inside:] = False
        if check_permissions and inside:
            allowed[:inside] &= self._allowed(address, inside, reading, failures, touched[:inside])
        return allowed, failures

    def read(self, address: int, length: int, check_permissions: bool = False) -> tuple[bytes, list[str]]:
        """
        Read bytes, as a slave (``check_permissions``) or the testbench does.

        Returns:
            The bytes, 0 where the access failed, and the failures.
        """
        allowed, failures = self.access(address, length, True, check_permissions)
        data = np.frombuffer(self.data.read(address, length), dtype=np.uint8)
        return (data * allowed).astype(np.uint8).tobytes(), failures

    def write(
        self,
        address: int,
        data: bytes,
        strobes: Iterable[bool] | None = None,
        check_permissions: bool = False,
        skip_mismatches: bool = True,
    ) -> list[str]:
        """
        Write bytes, as a slave (``check_permissions``) or the testbench does.

        A byte with an expected value must be written with it. Like VUnit, the testbench's write of a
        different value is not done, while a slave writes it anyway (``skip_mismatches`` False).

        Args:
            address: The first address.
            data: The bytes.
            strobes: Which bytes to write, all when None.
            check_permissions: Only write bytes the permissions allow.
            skip_mismatches: Do not write bytes that differ from their expected value.

        Returns:
            The failures.
        """
        mask = None if strobes is None else np.array(list(strobes), dtype=np.bool_)
        write, failures = self.access(address, len(data), False, check_permissions, mask)
        if mask is not None:
            write &= mask
        if not write.any():
            return failures
        values = np.frombuffer(bytes(data), dtype=np.uint8)
        has = np.frombuffer(self._has_expected.read(address, len(data)), dtype=np.uint8).astype(np.bool_)
        expected = np.frombuffer(self._expected.read(address, len(data)), dtype=np.uint8)
        mismatch = write & has & (values != expected)
        if mismatch.any():
            offset = int(np.argmax(mismatch))
            message = (
                f"Writing to {self.describe_address(address + offset)}. "
                f"Got {int(values[offset])} expected {int(expected[offset])}"
            )
            failures.append(_more(message, int(mismatch.sum()) - 1))
            if skip_mismatches:
                write &= ~mismatch
        for start, end in _spans(write):
            self.data.write(address + start, bytes(values[start:end]))
        return failures

    def fill(self, address: int, length: int, value: int) -> list[str]:
        """Set a range to one value, without checks beyond the size. Returns the failures."""
        failures: list[str] = []
        self.data.fill(address, self._in_range(address, length, False, failures), value)
        return failures

    # -- words -------------------------------------------------------------

    def serialize(self, value: int, bytes_per_word: int, endian: Endianness | None = None) -> bytes:
        """A word as bytes in memory order; a negative value is two's complement."""
        order = self.endian if endian is None else endian
        return (value % (1 << (8 * bytes_per_word))).to_bytes(
            bytes_per_word, "little" if order == Endianness.LITTLE else "big"
        )

    def deserialize(self, data: bytes, endian: Endianness | None = None) -> int:
        """Bytes in memory order as an unsigned word."""
        order = self.endian if endian is None else endian
        return int.from_bytes(data, "little" if order == Endianness.LITTLE else "big")

    # -- permissions -------------------------------------------------------

    def set_permission(self, address: int, length: int, permission: Permission) -> list[str]:
        """Give a range a permission. Returns the failures."""
        failures: list[str] = []
        self._permissions.fill(address, self._in_range(address, length, False, failures), Permission(permission))
        return failures

    def permission(self, address: int) -> Permission:
        """The permission of a byte."""
        return Permission(self._permissions.read_byte(address))

    # -- expected data -------------------------------------------------------

    def set_expected(self, address: int, data: bytes) -> list[str]:
        """The bytes a slave must write from ``address`` on. Returns the failures."""
        failures: list[str] = []
        inside = self._in_range(address, len(data), False, failures)
        self._expected.write(address, data[:inside])
        self._has_expected.fill(address, inside, 1)
        return failures

    def clear_expected(self, address: int, length: int = 1) -> list[str]:
        """Forget the expected bytes of a range. Returns the failures."""
        failures: list[str] = []
        inside = self._in_range(address, length, False, failures)
        self._has_expected.fill(address, inside, 0)
        self._expected.fill(address, inside, 0)
        return failures

    def has_expected(self, address: int) -> bool:
        """Whether a byte has an expected value."""
        return bool(self._has_expected.read_byte(address))

    def expected(self, address: int) -> int:
        """The expected value of a byte, 0 when it has none."""
        return self._expected.read_byte(address)

    def unwritten_expected(self, address: int = 0, length: int | None = None) -> list[tuple[int, int]]:
        """
        The bytes whose expected value was not written.

        Args:
            address: The first address.
            length: The number of bytes; None for all up to the end of the memory.

        Returns:
            ``(address, expected value)`` of each byte holding something else than its expected
            value, the work proportional to the bytes that have one.
        """
        if length is None:
            length = (self.size_bytes if self.size_bytes is not None else 2**64) - address
        missing: list[tuple[int, int]] = []
        for start, end in self._has_expected.touched(address, length):
            has = np.frombuffer(self._has_expected.read(start, end - start), dtype=np.uint8).astype(np.bool_)
            expected = np.frombuffer(self._expected.read(start, end - start), dtype=np.uint8)
            actual = np.frombuffer(self.data.read(start, end - start), dtype=np.uint8)
            for offset in np.flatnonzero(has & (actual != expected)):
                missing.append((start + int(offset), int(expected[offset])))
        return missing

    def check_expected_was_written(self, address: int = 0, length: int | None = None) -> list[str]:
        """One failure per byte whose expected value was not written, worded like VUnit's."""
        return [
            f"The {self.describe_address(a)} was never written with expected byte {value}"
            for a, value in self.unwritten_expected(address, length)
        ]

    # -- images ------------------------------------------------------------

    def load_image(self, path: str | Path, fmt: str | None = None, base: int = 0) -> int:
        """
        Load an image file in a format of the flash family (Intel HEX, S-record, raw binary, JSON).

        Sparse formats stay sparse: bytes the image does not describe keep their content, and a fill
        segment is one run. Loading is atomic: nothing is written when a segment does not fit.

        Args:
            path: The image file.
            fmt: The format, see :func:`~awesome_vunit_vcs.flash.images.format_for`; None infers it
                from the extension.
            base: The load address of a raw binary, an offset for the other formats.

        Returns:
            The number of bytes the image described.

        Raises:
            Axi4ValueError: A segment does not fit the memory.
            FlashValueError: The file is malformed, see :func:`~awesome_vunit_vcs.flash.images.load`.
            OSError: The file cannot be read.
        """
        segments = images.load(path, fmt, base)
        limit = self.size_bytes if self.size_bytes is not None else 2**64
        for segment in segments:
            if segment.addr < 0 or segment.addr + segment.size > limit:
                raise Axi4ValueError(f"The image segment at {segment.addr} of {segment.size} bytes does not fit")
        for segment in segments:
            if segment.data is not None:
                self.data.write(segment.addr, segment.data)
            else:
                assert segment.fill is not None
                self.data.fill(segment.addr, segment.length, segment.fill)
        return sum(segment.size for segment in segments)


def _more(message: str, more: int) -> str:
    return f"{message} (and {more} more bytes)" if more > 0 else message


def _spans(mask: npt.NDArray[np.bool_]) -> list[tuple[int, int]]:
    """The ``[start, end)`` ranges where mask is True."""
    edges = np.flatnonzero(np.diff(np.concatenate(([0], mask.astype(np.int8), [0]))))
    return [(int(edges[i]), int(edges[i + 1])) for i in range(0, len(edges), 2)]
