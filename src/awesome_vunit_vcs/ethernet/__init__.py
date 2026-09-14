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

import importlib
import warnings
from typing import Any

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

#: Names importable from here before the happy path, with the module and name they moved to
_DEPRECATED: dict[str, tuple[str, str]] = {
    "CaptureOptions": ("lowlevel", "CaptureOptions"),
    "EthernetConfig": ("lowlevel", "EthernetConfig"),
    "EthernetFrame": ("lowlevel", "EthernetFrame"),
    "EthernetMonitor": ("lowlevel", "EthernetMonitor"),
    "EthernetSource": ("source", "EthernetSource"),
    "EthernetStatistics": ("lowlevel", "EthernetStatistics"),
    "FcsMode": ("lowlevel", "FcsMode"),
    "FrameDecoder": ("lowlevel", "FrameDecoder"),
    "MacFrame": ("lowlevel", "MacFrame"),
    "PcapNgWriter": ("lowlevel", "PcapNgWriter"),
    "PerformanceMonitor": ("lowlevel", "PerformanceMonitor"),
    "PhyFrame": ("lowlevel", "PhyFrame"),
    "ProtocolChecker": ("lowlevel", "ProtocolChecker"),
    "WireFrame": ("lowlevel", "WireFrame"),
    "append_fcs": ("lowlevel", "append_fcs"),
    "build_wire_frame": ("lowlevel", "build_wire_frame"),
    "create_phy": ("lowlevel", "create_phy"),
    "fcs32": ("lowlevel", "fcs32"),
}


def __getattr__(name: str) -> Any:
    try:
        module, attribute = _DEPRECATED[name]
    except KeyError:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}") from None
    warnings.warn(
        f"awesome_vunit_vcs.ethernet.{name} is deprecated and will be removed in the next release; "
        f"import it from awesome_vunit_vcs.ethernet.{module}, or use Frame, Monitor and decode",
        DeprecationWarning,
        stacklevel=2,
    )
    return getattr(importlib.import_module(f"{__name__}.{module}"), attribute)
