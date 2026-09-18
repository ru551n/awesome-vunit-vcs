# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The AXI4 family: a passive monitor, a protocol checker and performance statistics of AXI4 and AXI4-Lite.

The VHDL components (``vhdl/axi4``) record what happens on the five channels at every rising edge of
ACLK and nothing else. Everything those records mean lives here and works without a simulator:

* :mod:`~awesome_vunit_vcs.axi4.bus`: the widths of an interface, the sample words and their decoding
* :mod:`~awesome_vunit_vcs.axi4.burst`: beat addresses and byte lanes of FIXED, INCR and WRAP bursts
* :mod:`~awesome_vunit_vcs.axi4.transaction`: handshakes to transactions, per ID
* :mod:`~awesome_vunit_vcs.axi4.monitor`: transactions, statistics and the shadow memory
* :mod:`~awesome_vunit_vcs.axi4.checker`: the protocol checks, each with an
  :class:`~awesome_vunit_vcs.axi4.checks.Axi4CheckId`
* :mod:`~awesome_vunit_vcs.axi4.performance`: bandwidth, utilization, backpressure, latencies
* :mod:`~awesome_vunit_vcs.axi4.memory`: the shadow memory scoreboard
* :mod:`~awesome_vunit_vcs.axi4.vunit_backend`: the objects the VHDL components create

Times are integers in femtoseconds (fs), latencies in clock cycles, sizes in bytes.
"""

from __future__ import annotations

from .burst import BurstType, beat_addresses, beat_lanes, crosses_4k
from .bus import Axi4Config, Axi4Sample, Channel, SampleDecoder
from .checker import Axi4ProtocolChecker
from .checks import Axi4CheckId, Axi4Violation
from .errors import Axi4Error, Axi4ValueError
from .memory import ShadowMemory
from .monitor import Axi4Monitor
from .performance import Axi4PerformanceMonitor, Axi4Statistics, ChannelStatistics, DirectionStatistics, Distribution
from .transaction import Axi4Beat, Axi4Transaction, Direction, Response

__all__ = [
    "Axi4Beat",
    "Axi4CheckId",
    "Axi4Config",
    "Axi4Error",
    "Axi4Monitor",
    "Axi4PerformanceMonitor",
    "Axi4ProtocolChecker",
    "Axi4Sample",
    "Axi4Statistics",
    "Axi4Transaction",
    "Axi4ValueError",
    "Axi4Violation",
    "BurstType",
    "Channel",
    "ChannelStatistics",
    "Direction",
    "DirectionStatistics",
    "Distribution",
    "Response",
    "SampleDecoder",
    "ShadowMemory",
    "beat_addresses",
    "beat_lanes",
    "crosses_4k",
]
