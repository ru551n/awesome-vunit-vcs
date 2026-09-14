"""
Ethernet frame model: PHY frame -> MAC frame, simulator independent.

Three levels are kept apart:

* :class:`~.phy.common.PhyFrame`: raw octets seen while valid was asserted
* :class:`MacFrame`: the octets after the SFD, with FCS handling
* decoded packets: left to Scapy (:mod:`.scapy_adapter`)

:class:`EthernetFrame` is the event the monitor publishes. It holds both
levels plus the analysis every consumer needs (preamble, SFD, FCS, size,
inter-frame gap), so that checker, statistics and capture agree.
"""

from __future__ import annotations

import zlib
from dataclasses import dataclass

from .phy.common import PhyFrame

PREAMBLE_OCTET = 0x55
SFD_OCTET = 0xD5
FCS_OCTETS = 4
HEADER_OCTETS = 14
MIN_FRAME_OCTETS = 64
MAX_FRAME_OCTETS = 1518
MIN_IFG_OCTETS = 12
PREAMBLE_OCTETS = 7
MAX_LENGTH_FIELD = 1500


def fcs32(data: bytes) -> int:
    """The Ethernet FCS (CRC-32) of data, as an integer."""
    return zlib.crc32(data) & 0xFFFFFFFF


def append_fcs(data: bytes) -> bytes:
    """Data followed by its FCS in transmission order (least significant octet first)."""
    return bytes(data) + fcs32(data).to_bytes(FCS_OCTETS, "little")


@dataclass(slots=True, frozen=True)
class EthernetConfig:
    """
    What a monitor considers a well-formed frame.

    Frame sizes count the octets from the destination address up to and
    including the FCS, like IEEE 802.3 does. ``has_fcs=False`` describes an
    interface where frames are observed without FCS; sizes still refer to
    the frame with FCS.
    """

    min_preamble_octets: int = PREAMBLE_OCTETS
    max_preamble_octets: int = PREAMBLE_OCTETS
    min_frame_octets: int = MIN_FRAME_OCTETS
    max_frame_octets: int = MAX_FRAME_OCTETS
    min_ifg_octets: int = MIN_IFG_OCTETS
    has_fcs: bool = True

    def __post_init__(self) -> None:
        if not 0 <= self.min_preamble_octets <= self.max_preamble_octets:
            raise ValueError("Require 0 <= min_preamble_octets <= max_preamble_octets")
        if not 0 <= self.min_frame_octets <= self.max_frame_octets:
            raise ValueError("Require 0 <= min_frame_octets <= max_frame_octets")
        if self.min_ifg_octets < 0:
            raise ValueError("min_ifg_octets must not be negative")


@dataclass(slots=True, frozen=True)
class MacFrame:
    """The octets following the SFD."""

    data: bytes
    has_fcs: bool = True

    @property
    def mac_octets(self) -> bytes:
        """Destination address up to, not including, the FCS: what a MAC client sends."""
        if self.has_fcs:
            return self.data[:-FCS_OCTETS] if len(self.data) >= FCS_OCTETS else b""
        return self.data

    @property
    def payload(self) -> bytes:
        """The octets after the 14-octet header, excluding the FCS, padding included."""
        return self.mac_octets[HEADER_OCTETS:]

    @property
    def fcs_received(self) -> int | None:
        """The FCS at the end of the frame, None without FCS or when the frame is shorter than one."""
        if not self.has_fcs or len(self.data) < FCS_OCTETS:
            return None
        return int.from_bytes(self.data[-FCS_OCTETS:], "little")

    @property
    def fcs_expected(self) -> int | None:
        """The FCS computed over :attr:`mac_octets`, None when there is no FCS to compare with."""
        if not self.has_fcs or len(self.data) < FCS_OCTETS:
            return None
        return fcs32(self.mac_octets)

    @property
    def fcs_ok(self) -> bool | None:
        """None when there is no FCS to check."""
        received = self.fcs_received
        return None if received is None else received == self.fcs_expected

    @property
    def size_with_fcs(self) -> int:
        """Frame size in octets from the destination address up to and including the FCS."""
        return len(self.data) if self.has_fcs else len(self.data) + FCS_OCTETS

    @property
    def destination(self) -> bytes | None:
        """The destination address, None for a frame shorter than 6 octets."""
        return self.mac_octets[0:6] if len(self.mac_octets) >= 6 else None

    @property
    def source(self) -> bytes | None:
        """The source address, None for a frame shorter than 12 octets."""
        return self.mac_octets[6:12] if len(self.mac_octets) >= 12 else None

    @property
    def ethertype(self) -> int | None:
        """The EtherType/length field, None for a frame shorter than the header."""
        if len(self.mac_octets) < HEADER_OCTETS:
            return None
        return int.from_bytes(self.mac_octets[12:14], "big")

    @property
    def client_data(self) -> bytes:
        """The payload with padding removed when the type field is a length."""
        body = self.payload
        ethertype = self.ethertype
        if ethertype is not None and ethertype <= MAX_LENGTH_FIELD:
            return body[:ethertype]
        return body


@dataclass(slots=True, frozen=True)
class EthernetFrame:
    """A frame observed by a monitor, analyzed against an :class:`EthernetConfig`."""

    phy: PhyFrame
    #: Number of preamble octets (0x55) before the first other octet
    preamble_octets: int
    preamble_ok: bool
    #: Wire offset of the SFD, None when the preamble was not followed by one
    sfd_offset: int | None
    mac: MacFrame | None
    #: Idle octets since the previous frame, None for the first frame
    ifg_octets: int | None
    ifg_fs: int | None
    is_runt: bool
    is_giant: bool

    @property
    def index(self) -> int:
        """Position of the frame in the order the monitor received frames, from 0."""
        return self.phy.index

    @property
    def timestamp_start_fs(self) -> int:
        """Time of the first octet in fs, normally the first preamble octet."""
        return self.phy.timestamp_start_fs

    @property
    def timestamp_end_fs(self) -> int:
        """Time in fs of the first sample after the frame, where valid was deasserted."""
        return self.phy.timestamp_end_fs

    @property
    def timestamp_sfd_fs(self) -> int | None:
        """Time of the SFD in fs, None without SFD."""
        return None if self.sfd_offset is None else self.phy.octet_times_fs[self.sfd_offset]

    @property
    def timestamp_mac_fs(self) -> int:
        """Time of the first octet after the SFD, or of the first octet when there is no SFD."""
        if self.sfd_offset is not None and self.sfd_offset + 1 < len(self.phy.octets):
            return self.phy.octet_times_fs[self.sfd_offset + 1]
        return self.phy.timestamp_start_fs

    @property
    def mac_octets(self) -> bytes:
        """Destination address up to, not including, the FCS. Empty without SFD."""
        return b"" if self.mac is None else self.mac.mac_octets

    @property
    def payload(self) -> bytes:
        """The octets after the 14-octet header, excluding the FCS. Empty without SFD."""
        return b"" if self.mac is None else self.mac.payload

    @property
    def fcs_ok(self) -> bool | None:
        """Whether the FCS is correct, None without SFD or FCS."""
        return None if self.mac is None else self.mac.fcs_ok

    @property
    def has_phy_error(self) -> bool:
        """Whether the error signal was asserted during the frame."""
        return bool(self.phy.wire_error_offsets)

    @property
    def error_offsets(self) -> tuple[int, ...]:
        """Octets received with the error signal, counted from the first octet after the SFD.

        Offsets inside the preamble and the SFD are negative.
        """
        base = 0 if self.sfd_offset is None else self.sfd_offset + 1
        return tuple(offset - base for offset in self.phy.wire_error_offsets)

    @property
    def mac_error_offsets(self) -> tuple[int, ...]:
        """The same as :attr:`error_offsets`, the name used before it."""
        return self.error_offsets

    @property
    def is_good(self) -> bool:
        """Whether no check found anything wrong with the frame itself (the gap before it is not considered)."""
        return (
            self.mac is not None
            and self.preamble_ok
            and self.fcs_ok is not False
            and not self.is_runt
            and not self.is_giant
            and not self.phy.wire_error_offsets
            and not self.phy.metavalue_offsets
            and not self.phy.alignment_error
        )


class FrameDecoder:
    """Analyze :class:`PhyFrame` objects into :class:`EthernetFrame` objects."""

    def __init__(self, config: EthernetConfig | None = None) -> None:
        self.config = config or EthernetConfig()
        self._last_period_fs: int | None = None

    def decode(self, phy: PhyFrame) -> EthernetFrame:
        """
        Analyze one PHY frame.

        The inter-frame gap is measured from the last octet of the previous
        frame, in octet periods of the frame itself (or of the last frame that
        had more than one octet).
        """
        config = self.config
        octets = phy.octets

        preamble = 0
        while preamble < len(octets) and octets[preamble] == PREAMBLE_OCTET:
            preamble += 1
        sfd_offset = preamble if preamble < len(octets) and octets[preamble] == SFD_OCTET else None
        mac = None if sfd_offset is None else MacFrame(octets[sfd_offset + 1 :], config.has_fcs)

        period = phy.octet_period_fs or self._last_period_fs
        if phy.octet_period_fs:
            self._last_period_fs = phy.octet_period_fs
        ifg_octets = ifg_fs = None
        if phy.previous_last_octet_fs is not None and period:
            gap = phy.timestamp_start_fs - phy.previous_last_octet_fs
            ifg_fs = gap - period
            ifg_octets = round(gap / period) - 1

        size = 0 if mac is None else mac.size_with_fcs
        return EthernetFrame(
            phy=phy,
            preamble_octets=preamble,
            preamble_ok=config.min_preamble_octets <= preamble <= config.max_preamble_octets,
            sfd_offset=sfd_offset,
            mac=mac,
            ifg_octets=ifg_octets,
            ifg_fs=ifg_fs,
            is_runt=mac is not None and size < config.min_frame_octets,
            is_giant=mac is not None and size > config.max_frame_octets,
        )
