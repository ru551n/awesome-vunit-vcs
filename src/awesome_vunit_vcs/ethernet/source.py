"""
Active source: Python decides what goes on the wire, VHDL decides when.

A frame request becomes a :class:`~.phy.common.WireFrame` (preamble, SFD,
frame, FCS, error injection, inter-frame gap), which the PHY encoder turns
into one sample word per clock cycle for the VHDL transmitter.
"""

from __future__ import annotations

import enum
from collections.abc import Iterable

from ..common.events import Publisher
from .frame import FCS_OCTETS, MIN_FRAME_OCTETS, MIN_IFG_OCTETS, PREAMBLE_OCTET, PREAMBLE_OCTETS, SFD_OCTET, fcs32
from .phy.common import Int32Array, PhyInterface, WireFrame


class FcsMode(str, enum.Enum):
    #: Pad (if enabled) and append the correct FCS
    APPEND = "append"
    #: Pad (if enabled) and append the inverted FCS
    BAD = "bad"
    #: Send the data as it is, it already ends with an FCS or deliberately has none
    NONE = "none"


def build_wire_frame(
    data: bytes,
    *,
    fcs: FcsMode | str = FcsMode.APPEND,
    pad: bool = True,
    min_frame_octets: int = MIN_FRAME_OCTETS,
    preamble_octets: int = PREAMBLE_OCTETS,
    sfd: int = SFD_OCTET,
    ifg_octets: int = MIN_IFG_OCTETS,
    error_offsets: Iterable[int] = (),
) -> WireFrame:
    """
    Build what is transmitted for ``data``, the frame from destination address
    up to, not including, the FCS.

    ``error_offsets`` count like ``data``: 0 is the first octet after the SFD,
    the same offsets ETH_PHY_ERROR reports. Negative offsets reach back into
    the SFD (-1) and the preamble. Malformed traffic is intentional: every
    argument may describe a frame the standard forbids (short preamble, wrong
    SFD, runt, bad FCS, short IFG).
    """
    mode = FcsMode(fcs)
    if preamble_octets < 0:
        raise ValueError(f"preamble_octets must not be negative, got {preamble_octets}")
    if not 0 <= sfd <= 0xFF:
        raise ValueError(f"sfd must be an octet, got {sfd}")
    body = bytes(data)
    if mode is not FcsMode.NONE:
        if pad:
            body += bytes(max(0, min_frame_octets - FCS_OCTETS - len(body)))
        value = fcs32(body)
        if mode is FcsMode.BAD:
            value ^= 0xFFFFFFFF
        body += value.to_bytes(FCS_OCTETS, "little")
    octets = bytes([PREAMBLE_OCTET] * preamble_octets + [sfd]) + body
    # WireFrame indexes wire octets, 0 being the first preamble octet
    return WireFrame(octets, tuple(offset + preamble_octets + 1 for offset in error_offsets), ifg_octets)


class EthernetSource:
    """Queue of wire frames waiting for the VHDL transmitter."""

    def __init__(self, phy: PhyInterface, *, name: str = "ethernet_source") -> None:
        self.name = name
        self.phy = phy
        #: Frames handed to VHDL for transmission, in order
        self.transmitted: Publisher[WireFrame] = Publisher()
        self._pending: dict[int, WireFrame] = {}
        self._next_id = 0

    def queue(self, wire: WireFrame) -> int:
        frame_id = self._next_id
        self._next_id += 1
        self._pending[frame_id] = wire
        return frame_id

    def take_symbols(self, frame_id: int) -> Int32Array:
        """The sample words of a queued frame, one per clock cycle, including the trailing gap."""
        try:
            wire = self._pending.pop(frame_id)
        except KeyError:
            raise KeyError(f"{self.name}: no queued frame with id {frame_id}") from None
        symbols = self.phy.encode(wire)
        self.transmitted.publish(wire)
        return symbols

    @property
    def pending(self) -> int:
        return len(self._pending)
