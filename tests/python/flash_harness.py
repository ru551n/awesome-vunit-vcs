# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A software stand-in for the VHDL verification component.

Every protocol test drives the model through this, and it deliberately
*follows the directives* instead of assuming the phase structure of the
command it is issuing. If the model says "receive, 2 lanes, 8 dummy
cycles", the harness receives one byte and records the lane and dummy
counts; it never decides for itself that a 0x3B has an address phase. A
harness that assumed the phases would still pass when the model returned
nonsense directives, which is the only thing the VC actually consumes.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from awesome_vunit_vcs.flash.device import FlashDevice
from awesome_vunit_vcs.flash.directive import Action, Directive, unpack


@dataclass
class Result:
    """What one CS-low-to-CS-high transaction produced."""

    directives: list[Directive] = field(default_factory=list)
    out: list[int] = field(default_factory=list)
    #: Busy time in femtoseconds, 0 when the device did not go busy
    busy: int = 0
    sent: int = 0

    @property
    def ignored(self) -> bool:
        """True when the device refused the command outright."""
        return any(d.action is Action.IGNORE_REST for d in self.directives[:2])

    def data_directives(self) -> list[Directive]:
        return [d for d in self.directives if d.action is not Action.IGNORE_REST]


def frame(
    opcode: int | None = None,
    addr: int | None = None,
    addr_bytes: int = 3,
    mode_byte: int | None = None,
    data: bytes | list[int] = (),
) -> list[int]:
    """Assemble the bytes a host clocks in, most significant address byte
    first. `opcode=None` is a continuous-read (XIP) transaction, which
    starts at the address phase."""
    out: list[int] = []
    if opcode is not None:
        out.append(opcode)
    if addr is not None:
        out += [(addr >> (8 * (addr_bytes - 1 - i))) & 0xFF for i in range(addr_bytes)]
    if mode_byte is not None:
        out.append(mode_byte)
    out += list(data)
    return out


class Host:
    """Holds the simulation time in femtoseconds, so a test reads like a waveform."""

    def __init__(self, device: FlashDevice, now: int = 0) -> None:
        self.dev = device
        self.now = now

    def advance(self, duration_fs: int) -> Host:
        self.now += duration_fs
        return self

    def at(self, time_fs: int) -> Host:
        self.now = time_fs
        return self

    def xact(self, send: list[int] | None = None, read: int = 0, trailing_bits: int = 0) -> Result:
        """One transaction. Sends `send`, then clocks out `read` bytes,
        then raises CS with `trailing_bits` clocks past the last byte."""
        send = list(send or [])
        result = Result()
        directive = unpack(self.dev.cs_assert(self.now))
        result.directives.append(directive)
        index = 0
        while True:
            if directive.action is Action.IGNORE_REST:
                break
            if directive.action is Action.RECEIVE:
                if index >= len(send):
                    break
                byte = send[index]
                index += 1
                nxt = self.dev.xfer(byte, self.now if directive.volatile else None)
            else:
                if len(result.out) >= read:
                    break
                result.out.append(directive.byte_out)
                nxt = self.dev.xfer(-1, self.now if directive.volatile else None)
            directive = unpack(nxt)
            result.directives.append(directive)
        result.sent = index
        result.busy = self.dev.cs_deassert(trailing_bits, self.now)
        return result

    # -- shorthands used all over the protocol tests ------------------------

    def command(self, opcode: int, **kwargs) -> Result:
        read = kwargs.pop("read", 0)
        trailing_bits = kwargs.pop("trailing_bits", 0)
        if kwargs.get("addr") is not None and "addr_bytes" not in kwargs:
            # Follow the device's current addressing mode, like a driver
            # would. Tests that want to send the wrong number of address
            # bytes say so explicitly.
            kwargs["addr_bytes"] = self.dev.mode.addr_bytes
        return self.xact(frame(opcode, **kwargs), read=read, trailing_bits=trailing_bits)

    def first_transmit(self, result: Result):
        """The directive that opened the data phase of a read -- where the
        lane width and the dummy-cycle prefix live."""
        for directive in result.directives:
            if directive.action is Action.TRANSMIT:
                return directive
        raise AssertionError("no transmit directive in this transaction")

    def wren(self) -> Result:
        return self.command(0x06)

    def read_array(self, addr: int, count: int, opcode: int = 0x03, **kwargs) -> list[int]:
        addr_bytes = kwargs.pop("addr_bytes", self.dev.mode.addr_bytes)
        return self.command(opcode, addr=addr, addr_bytes=addr_bytes, read=count, **kwargs).out

    def status(self, index: int = 0, count: int = 1) -> list[int]:
        return self.command({0: 0x05, 1: 0x35, 2: 0x15}[index], read=count).out
