# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Transfers reconstructed from bus events.

A *transaction* runs from a START to a STOP. It holds one or more *transfers*:
a transfer starts with a START or a repeated START, has an address with its
R/W bit and the data bytes after it, each with its acknowledge bit, and ends
at the next repeated START or at the STOP.
"""

from __future__ import annotations

import enum
from collections.abc import Callable
from dataclasses import dataclass, field

from .bus import BusEvent, EventKind

__all__ = ["AddressKind", "I2cTransfer", "TransferAssembler", "address_kind"]


class AddressKind(enum.Enum):
    """What the first byte after a START addresses (the reserved addresses of UM10204)."""

    #: A 7-bit target address
    SEVEN_BIT = "7-bit"
    #: ``1111 0XX``: a 10-bit address
    TEN_BIT = "10-bit"
    #: ``0000 000`` with W: the general call address
    GENERAL_CALL = "general call"
    #: ``0000 000`` with R: the START byte
    START_BYTE = "START byte"
    #: ``0000 001``: CBUS address
    CBUS = "CBUS"
    #: ``0000 010`` and ``0000 011``: reserved for a different bus format and future purposes
    RESERVED = "reserved"
    #: ``0000 1XX``: a Hs-mode controller code
    HS_MODE = "Hs-mode controller code"
    #: ``1111 1XX``: device ID
    DEVICE_ID = "device ID"


def address_kind(first_byte: int) -> AddressKind:
    """The kind of address of the first byte after a START, address and R/W bit."""
    address = first_byte >> 1
    if address == 0:
        return AddressKind.START_BYTE if first_byte & 1 else AddressKind.GENERAL_CALL
    if address == 1:
        return AddressKind.CBUS
    if address in (2, 3):
        return AddressKind.RESERVED
    if address >> 2 == 1:
        return AddressKind.HS_MODE
    if address >> 2 == 0x1E:
        return AddressKind.TEN_BIT
    if address >> 2 == 0x1F:
        return AddressKind.DEVICE_ID
    return AddressKind.SEVEN_BIT


@dataclass(frozen=True)
class I2cTransfer:
    """
    One transfer, from a START or repeated START to the next repeated START or STOP.

    Attributes:
        index: Counts the transfers of a monitor from 0.
        address: The 7-bit or 10-bit address, None when the bus carried no complete address.
        read: The R/W bit is R.
        kind: What the address is.
        address_ack: Every address byte was acknowledged.
        data: The data bytes after the address.
        acks: For every data byte, whether it was acknowledged.
        repeated_start: The transfer started with a repeated START.
        stopped: The transfer ended with a STOP, not a repeated START.
        partial_bits: Bits clocked after the last complete byte and its acknowledge bit.
        start_fs: Time of the START in fs.
        end_fs: Time of the repeated START or STOP that ended it, in fs.
    """

    index: int
    address: int | None
    read: bool
    kind: AddressKind
    address_ack: bool
    data: bytes
    acks: tuple[bool, ...]
    repeated_start: bool
    stopped: bool
    partial_bits: int
    start_fs: int
    end_fs: int

    @property
    def nack_index(self) -> int | None:
        """The index of the first data byte that was not acknowledged, None when all were."""
        return next((index for index, ack in enumerate(self.acks) if not ack), None)

    @property
    def ten_bit(self) -> bool:
        """The address is a 10-bit address."""
        return self.kind is AddressKind.TEN_BIT

    def __str__(self) -> str:
        address = "no address" if self.address is None else f"address 0x{self.address:02X} ({self.kind.value})"
        direction = "read" if self.read else "write"
        data = " ".join(
            f"{value:02X}{'' if ack else '(NACK)'}" for value, ack in zip(self.data, self.acks, strict=True)
        )
        nack = "" if self.address_ack else ", address NACK"
        return f"transfer {self.index}: {direction} {address}{nack}, {len(self.data)} bytes [{data}]"


@dataclass
class _Builder:
    start_fs: int
    repeated_start: bool
    address_bytes: list[int] = field(default_factory=list)
    address_acks: list[bool] = field(default_factory=list)
    data: bytearray = field(default_factory=bytearray)
    acks: list[bool] = field(default_factory=list)


class TransferAssembler:
    """
    Assemble transfers from bus events.

    Args:
        on_transfer: Called with every transfer when it ends.

    Attributes:
        in_transaction: A START was seen and no STOP after it.
        transfer_count: Transfers completed so far.
        transaction_count: Transactions started so far.
    """

    def __init__(self, on_transfer: Callable[[I2cTransfer], None]) -> None:
        self._on_transfer = on_transfer
        self.in_transaction = False
        self.transfer_count = 0
        self.transaction_count = 0
        self._current: _Builder | None = None
        self._bits: list[int] = []
        # The last 10-bit address written in this transaction, for a repeated START with 11110XX R
        self._ten_bit_address: int | None = None

    def reset(self) -> None:
        """Drop a transaction in progress; the next transfer starts at a START."""
        self.in_transaction = False
        self._current = None
        self._bits = []
        self._ten_bit_address = None

    def feed(self, event: BusEvent) -> None:
        """Take one bus event."""
        if event.kind is EventKind.START:
            if self._current is not None:
                self._end(event.time_fs, stopped=False)
            else:
                self._ten_bit_address = None
                self.transaction_count += 1
            self._current = _Builder(event.time_fs, repeated_start=self.in_transaction)
            self.in_transaction = True
            self._bits = []
        elif event.kind is EventKind.STOP:
            if self._current is not None:
                self._end(event.time_fs, stopped=True)
            self.in_transaction = False
            self._ten_bit_address = None
        elif event.kind is EventKind.RISE and self._current is not None:
            self._bits.append(event.sda)
            if len(self._bits) == 9:
                value = int("".join(map(str, self._bits[:8])), 2)
                self._byte(self._current, value, ack=self._bits[8] == 0)
                self._bits = []

    def _byte(self, current: _Builder, value: int, ack: bool) -> None:
        address_bytes = current.address_bytes
        if not address_bytes or (
            len(address_bytes) == 1
            and address_kind(address_bytes[0]) is AddressKind.TEN_BIT
            and not address_bytes[0] & 1
            and not current.data
        ):
            address_bytes.append(value)
            current.address_acks.append(ack)
        else:
            current.data.append(value)
            current.acks.append(ack)

    def _end(self, time_fs: int, stopped: bool) -> None:
        current = self._current
        assert current is not None
        address: int | None = None
        read = False
        kind = AddressKind.SEVEN_BIT
        if current.address_bytes:
            first = current.address_bytes[0]
            kind = address_kind(first)
            read = bool(first & 1)
            if kind is AddressKind.TEN_BIT:
                if len(current.address_bytes) == 2:
                    address = ((first >> 1) & 3) << 8 | current.address_bytes[1]
                    self._ten_bit_address = address
                elif read and self._ten_bit_address is not None and self._ten_bit_address >> 8 == (first >> 1) & 3:
                    address = self._ten_bit_address
            else:
                address = first >> 1
        self._on_transfer(
            I2cTransfer(
                index=self.transfer_count,
                address=address,
                read=read,
                kind=kind,
                address_ack=bool(current.address_acks) and all(current.address_acks),
                data=bytes(current.data),
                acks=tuple(current.acks),
                repeated_start=current.repeated_start,
                stopped=stopped,
                # The last rise of SCL belongs to the repeated START or STOP
                partial_bits=max(len(self._bits) - 1, 0),
                start_fs=current.start_fs,
                end_fs=time_fs,
            )
        )
        self.transfer_count += 1
        self._current = None
