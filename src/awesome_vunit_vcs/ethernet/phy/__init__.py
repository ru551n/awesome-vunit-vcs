"""PHY frontends: the thin, interface specific part of the Python backend."""

from __future__ import annotations

from typing import Any

from ..errors import EthernetValueError
from .axis import AxisPhy
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
from .mii import MiiPhy
from .rgmii import RgmiiPhy
from .rmii import RmiiPhy
from .xgmii import XgmiiPhy

_INTERFACES: dict[str, type[Any]] = {
    "axis": AxisPhy,
    "gmii": GmiiPhy,
    "mii": MiiPhy,
    "rgmii": RgmiiPhy,
    "rmii": RmiiPhy,
    "xgmii": XgmiiPhy,
}


def create_phy(interface: str, **options: Any) -> PhyInterface:
    """Create the PHY frontend of an interface by name."""
    try:
        cls = _INTERFACES[interface.lower()]
    except KeyError:
        known = ", ".join(sorted(_INTERFACES))
        raise EthernetValueError(f"Unknown Ethernet interface {interface!r}, known: {known}") from None
    phy: PhyInterface = cls(**options)
    return phy


__all__ = [
    "AxisPhy",
    "FrameAssembler",
    "GmiiPhy",
    "IdleEvent",
    "MiiPhy",
    "OctetBatch",
    "PhyEvent",
    "PhyFrame",
    "PhyInterface",
    "RgmiiPhy",
    "RmiiPhy",
    "WireFrame",
    "XgmiiPhy",
    "create_phy",
]
