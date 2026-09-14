"""
Ethernet verification components.

The simulator independent core (frames, checker, statistics, capture, source
frame building) is usable from plain Python; the VHDL components under
``vhdl/ethernet`` feed it through :mod:`.vunit_backend`.
"""

from .checker import CheckId, ProtocolChecker, Violation
from .frame import EthernetConfig, EthernetFrame, FrameDecoder, MacFrame, append_fcs, fcs32
from .metrics import EthernetStatistics, PerformanceMonitor
from .monitor import EthernetMonitor
from .pcap import CaptureOptions, PcapNgWriter
from .phy import PhyFrame, WireFrame, create_phy
from .source import EthernetSource, FcsMode, build_wire_frame

__all__ = [
    "CaptureOptions",
    "CheckId",
    "EthernetConfig",
    "EthernetFrame",
    "EthernetMonitor",
    "EthernetSource",
    "EthernetStatistics",
    "FcsMode",
    "FrameDecoder",
    "MacFrame",
    "PcapNgWriter",
    "PerformanceMonitor",
    "PhyFrame",
    "ProtocolChecker",
    "Violation",
    "WireFrame",
    "append_fcs",
    "build_wire_frame",
    "create_phy",
    "fcs32",
]
