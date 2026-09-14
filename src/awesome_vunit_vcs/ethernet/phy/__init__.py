"""PHY frontends: the thin, interface specific part of the Python backend."""

from __future__ import annotations

from typing import Any

from .common import (
    FrameAssembler,
    IdleEvent,
    OctetBatch,
    PhyEvent,
    PhyFrame,
    PhyInterface,
    WireFrame,
)
from .gmii import GmiiPhy

_INTERFACES: dict[str, type[Any]] = {
    "gmii": GmiiPhy,
}


def create_phy(interface: str, **options: Any) -> PhyInterface:
    """Create the PHY frontend of an interface by name."""
    try:
        cls = _INTERFACES[interface.lower()]
    except KeyError:
        known = ", ".join(sorted(_INTERFACES))
        raise ValueError(f"Unknown Ethernet interface {interface!r}, known: {known}") from None
    phy: PhyInterface = cls(**options)
    return phy


__all__ = [
    "FrameAssembler",
    "GmiiPhy",
    "IdleEvent",
    "OctetBatch",
    "PhyEvent",
    "PhyFrame",
    "PhyInterface",
    "WireFrame",
    "create_phy",
]
