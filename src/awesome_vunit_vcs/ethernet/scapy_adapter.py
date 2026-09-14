"""
Optional Scapy integration for packet-level construction and inspection.

Scapy is not needed to monitor, check or capture frames. Install it with
``pip install awesome-vunit-vcs[scapy]``.
"""

from __future__ import annotations

from typing import Any

from .frame import EthernetFrame, MacFrame


def _ether() -> Any:
    try:
        from scapy.layers.l2 import Ether
    except ImportError as exc:
        raise ImportError("Scapy integration needs the scapy package: pip install awesome-vunit-vcs[scapy]") from exc
    return Ether


def to_scapy(frame: EthernetFrame | MacFrame | bytes) -> Any:
    """Decode a frame (without FCS) into a Scapy ``Ether`` packet."""
    data = frame.mac_octets if isinstance(frame, EthernetFrame | MacFrame) else bytes(frame)
    return _ether()(data)


def packet_bytes(packet: Any) -> bytes:
    """The octets of a Scapy packet (or anything convertible with ``bytes``), without FCS."""
    return bytes(packet)
