# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The stable identifiers of the AXI4 checks, and a failed check."""

from __future__ import annotations

import enum
from dataclasses import dataclass

from .errors import Axi4ValueError

__all__ = ["PROTOCOL_CHECKS", "Axi4CheckId", "Axi4Violation"]


class Axi4CheckId(str, enum.Enum):
    """
    The stable identifiers of the AXI4 checks.

    The value is the name used in messages, accepted by VHDL (``axi4_stable``) and Python (``"AXI4_STABLE"``,
    ``"STABLE"``) alike.
    """

    #: A metavalue on VALID, READY or ARESETn, on the payload of a channel while VALID is 1, or on a data
    #: byte lane that carries data (a strobed write lane, an active read lane)
    METAVALUE = "AXI4_METAVALUE"
    #: VALID is 1 while ARESETn is 0, or at the first rising edge of ACLK after ARESETn rose
    RESET_VALID = "AXI4_RESET_VALID"
    #: The payload of a channel changed while VALID was 1 and READY 0
    STABLE = "AXI4_STABLE"
    #: VALID fell before READY accepted the payload
    VALID_DROP = "AXI4_VALID_DROP"
    #: AxBURST is the reserved value 0b11
    BURST_TYPE = "AXI4_BURST_TYPE"
    #: An INCR burst crosses a 4 KB boundary
    BURST_4K = "AXI4_BURST_4K"
    #: A WRAP burst is not 2, 4, 8 or 16 beats long
    WRAP_LEN = "AXI4_WRAP_LEN"
    #: The start address of a WRAP burst is not aligned to the size of a beat
    WRAP_ALIGN = "AXI4_WRAP_ALIGN"
    #: A FIXED burst is longer than 16 beats
    LEN_FIXED = "AXI4_LEN_FIXED"
    #: A beat is wider than the data bus
    SIZE = "AXI4_SIZE"
    #: AxCACHE has allocate bits set on a non-modifiable transaction
    CACHE = "AXI4_CACHE"
    #: An exclusive access breaks the exclusive access rules, or an EXOKAY response to a normal access
    EXCL = "AXI4_EXCL"
    #: WLAST is 1 on a beat that is not the last of its burst, or 0 on the last
    WLAST = "AXI4_WLAST"
    #: RLAST is 1 on a beat that is not the last of its burst, or 0 on the last
    RLAST = "AXI4_RLAST"
    #: WSTRB is 1 for a byte lane outside the lanes of the beat
    WSTRB = "AXI4_WSTRB"
    #: A write response or read data with an ID that has no outstanding transaction waiting for it
    UNEXPECTED_RESP = "AXI4_UNEXPECTED_RESP"
    #: A transaction without its response, write data without its address, or VALID without READY, for
    #: longer than the timeout
    TIMEOUT = "AXI4_TIMEOUT"
    #: A transaction differs from the expected one, an expected transaction never came, or a read returned
    #: data the shadow memory does not allow (monitor)
    SCOREBOARD = "AXI4_SCOREBOARD"

    @classmethod
    def parse(cls, check: Axi4CheckId | str) -> Axi4CheckId:
        """
        Look up a check by member, value or name, case insensitively.

        Raises:
            Axi4ValueError: ``check`` names no check.
        """
        if isinstance(check, Axi4CheckId):
            return check
        name = check.strip().upper()
        for member in cls:
            if name in (member.value, member.name):
                return member
        known = ", ".join(member.value for member in cls)
        raise Axi4ValueError(f"Unknown AXI4 check {check!r}, known checks: {known}")


#: The checks :class:`~awesome_vunit_vcs.axi4.checker.Axi4ProtocolChecker` runs; the monitor runs the others
PROTOCOL_CHECKS = frozenset(Axi4CheckId) - {Axi4CheckId.SCOREBOARD}


@dataclass(frozen=True, slots=True)
class Axi4Violation:
    """A failed check."""

    check: Axi4CheckId
    #: Starts with the check ID
    message: str
    #: Simulation time of the violation in fs
    time_fs: int
