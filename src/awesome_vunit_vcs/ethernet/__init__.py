"""
Ethernet verification components.

The happy path is importable from here::

    from awesome_vunit_vcs import ethernet as eth

    frame = eth.Frame.from_payload(b"hello")
    with eth.Monitor(eth.GMII) as rx:
        rx.feed_frames([frame])
    assert rx.frames == [frame.padded()]

The simulator independent core is usable from plain Python; the VHDL
components under ``vhdl/ethernet`` feed the same pipeline through
:mod:`.vunit_backend`. The building blocks behind it are in :mod:`.lowlevel`,
and :mod:`.traffic` generates seeded traffic and calls packet functions by name.
"""

from __future__ import annotations

from .api import (
    DEFAULT_DESTINATION,
    DEFAULT_ETHERTYPE,
    DEFAULT_SOURCE,
    FcsKind,
    Frame,
    Monitor,
    Result,
    WireOptions,
    decode,
    expected_violations,
    mac_address,
    supported_malformations,
    write_pcapng,
)
from .checker import CheckId, Violation
from .errors import EthernetValueError
from .frame import MonitorConfig
from .interfaces import AXIS, GMII, INTERFACE_NAMES, MII, RGMII, RMII, XGMII, Interface, Samples
from .limits import LIMITS, Limits, Malformation
from .metrics import Statistics
from .units import bps, fs

__all__ = [
    "AXIS",
    "DEFAULT_DESTINATION",
    "DEFAULT_ETHERTYPE",
    "DEFAULT_SOURCE",
    "GMII",
    "INTERFACE_NAMES",
    "LIMITS",
    "MII",
    "RGMII",
    "RMII",
    "XGMII",
    "CheckId",
    "EthernetValueError",
    "FcsKind",
    "Frame",
    "Interface",
    "Limits",
    "Malformation",
    "Monitor",
    "MonitorConfig",
    "Result",
    "Samples",
    "Statistics",
    "Violation",
    "WireOptions",
    "bps",
    "decode",
    "expected_violations",
    "fs",
    "mac_address",
    "supported_malformations",
    "write_pcapng",
]
