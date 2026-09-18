# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
From SCL and SDA samples to bus events.

A passive I2C VC records a sample word whenever SCL or SDA changes:

====  =============================================
Bit   Meaning
====  =============================================
0     SCL is high (``'1'`` or ``'H'``)
1     SDA is high
2     SCL has a metavalue (``U``, ``X``, ``Z``, ``W``, ``-``)
3     SDA has a metavalue
====  =============================================

:class:`BusDecoder` turns the words into :class:`BusEvent` objects: START and
STOP conditions (SDA changing while SCL is high), SCL edges with the SDA level
at the rising edge, SDA changes while SCL is low, and metavalues. A line with
a metavalue keeps its last known level. When SCL and SDA change in the same
sample, the SDA change belongs to the low phase of SCL: after a falling SCL
edge, before a rising one, so it is never taken for a START or STOP.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

__all__ = ["SCL_BIT", "SCL_METAVALUE_BIT", "SDA_BIT", "SDA_METAVALUE_BIT", "BusDecoder", "BusEvent", "EventKind"]

#: SCL is high
SCL_BIT = 1
#: SDA is high
SDA_BIT = 2
#: SCL has a metavalue
SCL_METAVALUE_BIT = 4
#: SDA has a metavalue
SDA_METAVALUE_BIT = 8


class EventKind(enum.Enum):
    """What happened on the bus."""

    #: SDA fell while SCL was high: a START or a repeated START
    START = "start"
    #: SDA rose while SCL was high
    STOP = "stop"
    #: SCL rose; ``sda`` is the bit it clocks
    RISE = "rise"
    #: SCL fell
    FALL = "fall"
    #: SDA changed while SCL was low
    DATA = "data"
    #: A line has a metavalue; ``sda`` is 0 for SCL, 1 for SDA
    METAVALUE = "metavalue"


@dataclass(frozen=True, slots=True)
class BusEvent:
    """One event on the bus."""

    kind: EventKind
    #: Simulation time in fs
    time_fs: int
    #: The SDA level after the event, or the line of a metavalue (0 SCL, 1 SDA)
    sda: int


class BusDecoder:
    """
    Decode sample words into bus events. The bus starts idle, both lines high.

    Attributes:
        scl: The level of SCL after the last sample, 0 or 1.
        sda: The level of SDA after the last sample, 0 or 1.
    """

    def __init__(self) -> None:
        self.scl = 1
        self.sda = 1

    def reset(self) -> None:
        """Forget the levels; the bus is idle again."""
        self.scl = 1
        self.sda = 1

    def decode(self, word: int, time_fs: int) -> list[BusEvent]:
        """The events of one sample."""
        events = []
        scl = self.scl
        sda = self.sda
        if word & SCL_METAVALUE_BIT:
            events.append(BusEvent(EventKind.METAVALUE, time_fs, 0))
        else:
            scl = 1 if word & SCL_BIT else 0
        if word & SDA_METAVALUE_BIT:
            events.append(BusEvent(EventKind.METAVALUE, time_fs, 1))
        else:
            sda = 1 if word & SDA_BIT else 0

        sda_changed = sda != self.sda
        if scl != self.scl and scl == 0:
            events.append(BusEvent(EventKind.FALL, time_fs, self.sda))
            if sda_changed:
                events.append(BusEvent(EventKind.DATA, time_fs, sda))
        elif scl != self.scl:
            if sda_changed:
                events.append(BusEvent(EventKind.DATA, time_fs, sda))
            events.append(BusEvent(EventKind.RISE, time_fs, sda))
        elif sda_changed:
            if scl:
                events.append(BusEvent(EventKind.STOP if sda else EventKind.START, time_fs, sda))
            else:
                events.append(BusEvent(EventKind.DATA, time_fs, sda))
        self.scl = scl
        self.sda = sda
        return events
