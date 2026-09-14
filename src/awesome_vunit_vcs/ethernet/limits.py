"""
The parameter space of Ethernet traffic, as public data.

:class:`Limits` bounds every value a test generates: address and header
sizes, frame and payload sizes, preamble and gap lengths, lane counts and
rates. :class:`Malformation` names the deliberate errors a source can put on
the wire. Both are plain data, so a property-based test builds bounded
strategies from them, and :mod:`.traffic` builds its seeded generators from
the same values::

    from hypothesis import strategies as st
    from awesome_vunit_vcs.ethernet import LIMITS

    payloads = st.binary(min_size=LIMITS.min_payload_octets, max_size=LIMITS.max_payload_octets)
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, replace

from .errors import EthernetValueError


class Malformation(str, enum.Enum):
    """
    A deliberate error a source puts on the wire.

    :meth:`~awesome_vunit_vcs.ethernet.api.WireOptions.malformed` turns kinds into
    :class:`~awesome_vunit_vcs.ethernet.api.WireOptions`, and
    :func:`~awesome_vunit_vcs.ethernet.api.expected_violations` names the checks
    that report them.
    """

    #: An inverted FCS
    BAD_FCS = "bad_fcs"
    #: Fewer preamble octets than a monitor accepts
    SHORT_PREAMBLE = "short_preamble"
    #: More preamble octets than a monitor accepts
    LONG_PREAMBLE = "long_preamble"
    #: An octet other than 0xD5 after the preamble
    BAD_SFD = "bad_sfd"
    #: A frame shorter than the minimum, sent without padding
    RUNT = "runt"
    #: A frame longer than the maximum
    GIANT = "giant"
    #: The error signal asserted on octets of the frame
    PHY_ERROR = "phy_error"
    #: Fewer idle octets after the frame than a monitor requires
    SHORT_IFG = "short_ifg"


@dataclass(slots=True, frozen=True)
class Limits:
    """
    Bounds of Ethernet traffic: the IEEE 802.3 values and the generation bounds of malformed traffic.

    Sizes are octets, rates bits per second. A frame counts from the
    destination address up to and including the FCS. The defaults describe
    untagged IEEE 802.3 frames; :meth:`for_frames` derives the bounds for other
    frame sizes, for example 1522 octets for VLAN tagged traffic.

    Raises:
        EthernetValueError: A bound is negative or a minimum exceeds its maximum.
    """

    #: Octets of a MAC address
    mac_address_octets: int = 6
    #: Octets of the destination address, source address and EtherType
    header_octets: int = 14
    #: Octets of the FCS
    fcs_octets: int = 4
    #: The minimum frame size; shorter frames are padded, or are runts
    min_frame_octets: int = 64
    #: The maximum frame size; longer frames are giants
    max_frame_octets: int = 1518
    #: The smallest EtherType; smaller values of the field are lengths
    min_ethertype: int = 0x0600
    #: The largest EtherType
    max_ethertype: int = 0xFFFF
    #: The standard preamble length
    preamble_octets: int = 7
    #: The longest preamble generated for malformed traffic
    max_preamble_octets: int = 24
    #: The start frame delimiter
    sfd: int = 0xD5
    #: The standard minimum inter-frame gap of GMII and MII
    min_ifg_octets: int = 12
    #: The minimum inter-frame gap a monitor of the XGMII family accepts
    min_xgmii_ifg_octets: int = 5
    #: The longest inter-frame gap generated
    max_ifg_octets: int = 256
    #: The lane counts of the XGMII family
    xgmii_lanes: tuple[int, ...] = (4, 8)
    #: The rates of GMII, 1G and 2.5G for overclocked GMII
    gmii_rates_bps: tuple[int, ...] = (1_000_000_000, 2_500_000_000)
    #: The rates of MII
    mii_rates_bps: tuple[int, ...] = (10_000_000, 100_000_000)
    #: The rates of the XGMII family, from 2.5GMII and 5GMII over XGMII and 25GMII to XLGMII and CGMII
    xgmii_rates_bps: tuple[int, ...] = (
        2_500_000_000,
        5_000_000_000,
        10_000_000_000,
        25_000_000_000,
        40_000_000_000,
        100_000_000_000,
    )

    def __post_init__(self) -> None:
        for name in (
            "mac_address_octets",
            "header_octets",
            "fcs_octets",
            "min_frame_octets",
            "preamble_octets",
            "min_ifg_octets",
            "min_xgmii_ifg_octets",
        ):
            if getattr(self, name) < 0:
                raise EthernetValueError(f"{name} must not be negative, got {getattr(self, name)}")
        pairs = (
            ("min_frame_octets", "max_frame_octets"),
            ("min_ethertype", "max_ethertype"),
            ("preamble_octets", "max_preamble_octets"),
            ("min_ifg_octets", "max_ifg_octets"),
        )
        for low, high in pairs:
            if getattr(self, low) > getattr(self, high):
                raise EthernetValueError(f"{low} must not exceed {high}")
        if self.min_frame_octets < self.header_octets + self.fcs_octets:
            raise EthernetValueError("min_frame_octets must hold the header and the FCS")

    @property
    def min_payload_octets(self) -> int:
        """The smallest payload of a frame in octets, 0, since padding makes up the minimum frame size."""
        return 0

    @property
    def max_payload_octets(self) -> int:
        """The largest payload in octets of a frame within :attr:`max_frame_octets`, 1500 by default."""
        return self.max_frame_octets - self.header_octets - self.fcs_octets

    @property
    def min_padded_payload_octets(self) -> int:
        """The payload size in octets a frame is padded to, 46 by default."""
        return self.min_frame_octets - self.header_octets - self.fcs_octets

    def for_frames(self, *, min_frame_octets: int = 64, max_frame_octets: int = 1518) -> Limits:
        """
        The limits for other frame sizes.

        Args:
            min_frame_octets: The minimum frame size including the FCS.
            max_frame_octets: The maximum frame size including the FCS, 1522 for VLAN tagged frames.

        Returns:
            A copy with the frame sizes replaced.
        """
        return replace(self, min_frame_octets=min_frame_octets, max_frame_octets=max_frame_octets)


#: The IEEE 802.3 limits
LIMITS = Limits()
