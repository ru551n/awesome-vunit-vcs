"""
RGMII: the octet of a clock cycle split over both clock edges.

At 1 Gb/s RGMII carries the lower four bits of an octet on the rising edge of
the clock and the upper four bits on the falling edge; ``CTL`` carries the
valid signal on the rising edge and valid xor error on the falling edge. At 100
and 10 Mb/s it carries one nibble per clock cycle, like MII.

The VHDL frontend combines both edges of every clock cycle before recording
it, so the sample words are those of GMII at 1 Gb/s and those of MII at 10 and
100 Mb/s (see :mod:`.gmii` and :mod:`.mii`), and so is the decoding.
"""

from __future__ import annotations

from ..errors import EthernetValueError
from .common import Int32Array, Int64Array, OctetBatch, WireFrame
from .gmii import GmiiPhy
from .mii import MiiPhy

#: The link rate from which RGMII carries a whole octet per clock cycle
GIGABIT_BPS = 1_000_000_000


class RgmiiPhy:
    """
    Decoder and encoder of an RGMII interface.

    Args:
        link_rate_bps: The rate of the link, 10 Mb/s, 100 Mb/s or 1 Gb/s.

    Raises:
        EthernetValueError: If ``link_rate_bps`` is not positive.
    """

    name = "rgmii"

    def __init__(self, link_rate_bps: int = GIGABIT_BPS) -> None:
        if link_rate_bps <= 0:
            raise EthernetValueError(f"link_rate_bps must be positive, got {link_rate_bps}")
        self.link_rate_bps = link_rate_bps
        self._phy: GmiiPhy | MiiPhy = GmiiPhy(link_rate_bps) if link_rate_bps >= GIGABIT_BPS else MiiPhy(link_rate_bps)

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        """
        Turn RGMII sample words into octet words.

        Args:
            words: Sample words as recorded by ``rgmii_monitor``.
            times: The time of each sample in femtoseconds.

        Returns:
            The octet words completed by this batch, and the idle words.
        """
        return self._phy.decode(words, times)

    def encode(self, wire: WireFrame) -> Int32Array:
        """
        Turn a wire frame into one sample word per clock cycle.

        Args:
            wire: The octets to transmit, their error offsets and the IFG.

        Returns:
            One octet word per clock cycle at 1 Gb/s, two nibble words per octet
            at 10 and 100 Mb/s, followed by the idle words of the IFG.
        """
        return self._phy.encode(wire)
