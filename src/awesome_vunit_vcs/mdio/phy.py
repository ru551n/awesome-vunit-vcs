# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The protocol engine of the MDIO PHY: Clause 22 frames, their checks and the accesses they make.

A Clause 22 frame is, in the order of its bits on MDIO::

    PRE (32 ones)  ST (01)  OP (10 read, 01 write)  PHYAD (5)  REGAD (5)  TA (2)  DATA (16)

The VHDL PHY samples MDIO on rising MDC edges. It calls :meth:`MdioPhy.header` once the 14 bits
from ST to REGAD are in, and :meth:`MdioPhy.write_end` or :meth:`MdioPhy.read_end` when the frame
is over. A frame with ST 00 is a Clause 45 frame, which a Clause 22 PHY ignores.
"""

from __future__ import annotations

import enum
from collections.abc import Callable
from dataclasses import dataclass

from .devices import MdioDevice, check_register_address, check_value
from .errors import MdioValueError

__all__ = ["Action", "MdioAccess", "MdioCheckId", "MdioOperation", "MdioPhy", "MdioViolation", "Response"]


class MdioCheckId(str, enum.Enum):
    """
    The stable identifiers of the checks of the MDIO PHY.

    The value is the name used in messages, accepted by VHDL (``mdio_ta``) and Python (``"MDIO_TA"``,
    ``"TA"``) alike.
    """

    #: Fewer preamble ones before ST than the PHY needs
    PREAMBLE = "MDIO_PREAMBLE"
    #: An OP of 00 or 11 in a Clause 22 frame to the PHY
    OP = "MDIO_OP"
    #: A write whose TA is not 10, or a read whose first TA bit the master drove
    TA = "MDIO_TA"
    #: MDIO differed from the value the PHY drove, in the second TA bit or the data of a read
    CONTENTION = "MDIO_CONTENTION"
    #: A metavalue on MDIO in a frame header, or in a frame to the PHY
    METAVALUE = "MDIO_METAVALUE"
    #: A register differs from the value expected with ``check_mdio_phy_register``
    REGISTER = "MDIO_REGISTER"

    @classmethod
    def parse(cls, check: MdioCheckId | str) -> MdioCheckId:
        """
        Look up a check by member, value or name, case insensitively.

        Raises:
            MdioValueError: ``check`` names no check.
        """
        if isinstance(check, MdioCheckId):
            return check
        name = check.strip().upper()
        for member in cls:
            if name in (member.value, member.name):
                return member
        known = ", ".join(member.value for member in cls)
        raise MdioValueError(f"Unknown MDIO check {check!r}, known checks: {known}")


class MdioOperation(enum.IntEnum):
    """The operation of a Clause 22 frame; the value is its OP field."""

    WRITE = 0b01
    READ = 0b10


class Action(enum.IntEnum):
    """What the VHDL PHY does with the rest of a frame."""

    #: Let the rest of the frame pass, for a frame to another PHY, a Clause 45 frame or a bad header
    IGNORE = 0
    #: Sample the TA and data bits of a write
    WRITE = 1
    #: Leave the first TA bit to the pull-up, then drive 0 and the data
    READ = 2


@dataclass(frozen=True)
class Response:
    """
    The answer to a frame header.

    Attributes:
        action: What to do with the rest of the frame.
        data: The 16 bits to send when ``action`` is READ.
    """

    action: Action
    data: int = 0


@dataclass(frozen=True)
class MdioAccess:
    """
    A read or write frame the PHY answered.

    Attributes:
        operation: Read or write.
        phy_address: The PHYAD field.
        register_address: The REGAD field.
        data: The data read or written.
        time_fs: When the last bit of the frame was sampled.
    """

    operation: MdioOperation
    phy_address: int
    register_address: int
    data: int
    time_fs: int


@dataclass(frozen=True)
class MdioViolation:
    """
    A protocol violation found by the PHY.

    Attributes:
        check: The check that failed.
        message: What happened, starting with the check ID and ending with the time in fs.
        time_fs: When it was found.
    """

    check: MdioCheckId
    message: str
    time_fs: int


_IGNORE = Response(Action.IGNORE)


class MdioPhy:
    """
    A Clause 22 PHY at one address, answering frames with a device model.

    Args:
        device: The device model.
        phy_address: The address the PHY answers, 0 to 31.
        preamble_bits: The preamble ones the PHY needs before ST, 0 to accept a suppressed preamble.
        on_violation: Called with every violation, which is also appended to :attr:`violations`.

    Attributes:
        accesses: The frames the PHY answered, oldest first.
        violations: The violations found, oldest first.

    Raises:
        MdioValueError: An argument is out of range.
    """

    def __init__(
        self,
        device: MdioDevice,
        phy_address: int,
        preamble_bits: int = 32,
        on_violation: Callable[[MdioViolation], None] | None = None,
    ) -> None:
        if not 0 <= phy_address < 32:
            raise MdioValueError(f"PHY address {phy_address} is not 0 to 31")
        if preamble_bits < 0:
            raise MdioValueError(f"preamble_bits={preamble_bits} is negative")
        self.device = device
        self.phy_address = phy_address
        self.preamble_bits = preamble_bits
        self.accesses: list[MdioAccess] = []
        self.violations: list[MdioViolation] = []
        self._on_violation = on_violation
        self._register_address = 0

    def _violation(self, check: MdioCheckId, message: str, now_fs: int, prefix: str = "") -> None:
        text = f"{prefix}{': ' if prefix else ''}{check.value}: {message} at {now_fs} fs"
        violation = MdioViolation(check, text, now_fs)
        self.violations.append(violation)
        if self._on_violation is not None:
            self._on_violation(violation)

    def header(self, preamble_ones: int, header: int, metavalues: int, now_fs: int) -> Response:
        """
        The 14 bits from ST to REGAD were sampled.

        Args:
            preamble_ones: The ones sampled before the first ST bit.
            header: The bits from ST to REGAD, ST in bits 13 and 12; a metavalue counts as 0.
            metavalues: The number of metavalues among those bits.
            now_fs: When the last bit was sampled.

        Returns:
            What to do with the rest of the frame.
        """
        start = (header >> 12) & 0b11
        op = (header >> 10) & 0b11
        phy_address = (header >> 5) & 0x1F
        self._register_address = header & 0x1F
        if metavalues:
            self._violation(MdioCheckId.METAVALUE, f"{metavalues} metavalues from ST to REGAD", now_fs)
            return _IGNORE
        if start != 0b01 or phy_address != self.phy_address:
            return _IGNORE
        if preamble_ones < self.preamble_bits:
            self._violation(
                MdioCheckId.PREAMBLE, f"{preamble_ones} preamble ones, the PHY needs {self.preamble_bits}", now_fs
            )
            return _IGNORE
        if op == MdioOperation.READ:
            return Response(Action.READ, check_value(self.device.read(self._register_address, now_fs)))
        if op == MdioOperation.WRITE:
            return Response(Action.WRITE)
        self._violation(MdioCheckId.OP, f"OP {op:02b} is neither read (10) nor write (01)", now_fs)
        return _IGNORE

    def write_end(self, ta: int, data: int, metavalues: int, now_fs: int) -> None:
        """
        The TA and data bits of a write to the PHY were sampled. A write with a bad TA is not made.

        Args:
            ta: The two TA bits, the first in bit 1.
            data: The 16 data bits.
            metavalues: The number of metavalues among the TA and data bits.
            now_fs: When the last bit was sampled.
        """
        if metavalues:
            self._violation(MdioCheckId.METAVALUE, f"{metavalues} metavalues in the TA and data of a write", now_fs)
        elif ta != 0b10:
            self._violation(MdioCheckId.TA, f"the TA of a write is {ta:02b}, expected 10", now_fs)
        else:
            self.device.write(self._register_address, data, now_fs)
            self._record(MdioOperation.WRITE, data, now_fs)

    def read_end(self, ta_driven: bool, contention_bits: int, data: int, now_fs: int) -> None:
        """
        The PHY sent the data of a read.

        Args:
            ta_driven: MDIO was '0' or '1' in the first TA bit, where the master releases it.
            contention_bits: The bits, from the second TA bit on, in which MDIO differed from the PHY's value.
            data: The data the PHY sent.
            now_fs: When the last bit was sampled.
        """
        if ta_driven:
            self._violation(MdioCheckId.TA, "the master drove MDIO in the first TA bit of a read", now_fs)
        if contention_bits:
            self._violation(
                MdioCheckId.CONTENTION,
                f"MDIO differed from the PHY's value in {contention_bits} bits of a read",
                now_fs,
            )
        self._record(MdioOperation.READ, data, now_fs)

    def _record(self, operation: MdioOperation, data: int, now_fs: int) -> None:
        self.accesses.append(MdioAccess(operation, self.phy_address, self._register_address, data, now_fs))

    def check_register(self, register_address: int, expected: int, now_fs: int = 0, message: str = "") -> bool:
        """
        Compare a register with ``expected``, without the bus; a difference is an ``MDIO_REGISTER`` violation.

        Args:
            register_address: The register, 0 to 31.
            expected: The value it should have.
            now_fs: The time of the check.
            message: A prefix of the violation message.

        Returns:
            Whether the register has the expected value.
        """
        have = self.device.get_register(register_address)
        if have == expected:
            return True
        self._violation(
            MdioCheckId.REGISTER,
            f"register {register_address} is 0x{have:04X}, expected 0x{expected:04X}",
            now_fs,
            message,
        )
        return False

    def check_count(self, check: MdioCheckId | str) -> int:
        """The number of violations of one check."""
        wanted = MdioCheckId.parse(check)
        return sum(1 for violation in self.violations if violation.check == wanted)

    def access_count(self, operation: MdioOperation | None = None, register_address: int | None = None) -> int:
        """
        The number of frames the PHY answered, of one operation or to one register when they are given.

        Raises:
            MdioValueError: ``register_address`` is not 0 to 31.
        """
        if register_address is not None:
            check_register_address(register_address)
        return sum(
            1
            for access in self.accesses
            if (operation is None or access.operation == operation)
            and (register_address is None or access.register_address == register_address)
        )
