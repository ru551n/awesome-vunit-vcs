"""
The low-level Ethernet pipeline behind :class:`~awesome_vunit_vcs.ethernet.api.Monitor`.

These are the building blocks the happy path and the VHDL backends are made
of: the PHY frame and wire frame models, the MAC frame analysis, the
publisher-based monitor, the protocol checker, the statistics accumulator
and the PCAPNG writer. Use them to extend the pipeline; they are stable, but
most tests only need ``awesome_vunit_vcs.ethernet``.
"""

from __future__ import annotations

from ..common.events import Publisher
from .checker import CheckId, ProtocolChecker, Violation
from .frame import EthernetConfig, EthernetFrame, FrameDecoder, MacFrame, MonitorConfig, append_fcs, fcs32
from .metrics import EthernetStatistics, PerformanceMonitor, Statistics, Summary
from .monitor import EthernetMonitor
from .pcap import CaptureOptions, PcapNgWriter
from .phy import (
    FrameAssembler,
    IdleEvent,
    OctetBatch,
    PhyEvent,
    PhyFrame,
    PhyInterface,
    WireFrame,
    create_phy,
)
from .scapy_adapter import packet_bytes, to_scapy
from .source import FcsMode, build_wire_frame

__all__ = [
    "CaptureOptions",
    "CheckId",
    "EthernetConfig",
    "EthernetFrame",
    "EthernetMonitor",
    "EthernetStatistics",
    "FcsMode",
    "FrameAssembler",
    "FrameDecoder",
    "IdleEvent",
    "MacFrame",
    "MonitorConfig",
    "OctetBatch",
    "PcapNgWriter",
    "PerformanceMonitor",
    "PhyEvent",
    "PhyFrame",
    "PhyInterface",
    "ProtocolChecker",
    "Publisher",
    "Statistics",
    "Summary",
    "Violation",
    "WireFrame",
    "append_fcs",
    "build_wire_frame",
    "create_phy",
    "fcs32",
    "packet_bytes",
    "to_scapy",
]
