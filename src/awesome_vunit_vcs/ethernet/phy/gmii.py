"""
GMII: one 8-bit symbol per clock cycle.

The VHDL frontend samples ``D``/``DV``/``ER`` on the rising edge and records
each sample as an 8-bit sample word, which already is an octet word.
"""

from __future__ import annotations

import numpy as np

from .common import WORD_ERROR, WORD_VALID, Int32Array, Int64Array, OctetBatch, WireFrame


class GmiiPhy:
    """
    The GMII frontend: every sample word already is an octet word.

    Args:
        link_rate_bps: The link rate for utilization statistics; 2.5G for overclocked GMII.
    """

    name = "gmii"

    def __init__(self, link_rate_bps: int = 1_000_000_000) -> None:
        self.link_rate_bps = link_rate_bps

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        """Return the samples unchanged as octet words."""
        return OctetBatch(words, times)

    def encode(self, wire: WireFrame) -> Int32Array:
        """One word per octet with valid set, error set at the error offsets, then idle words for the gap."""
        symbols = np.zeros(len(wire.octets) + wire.ifg_octets, dtype=np.int32)
        symbols[: len(wire.octets)] = np.frombuffer(wire.octets, dtype=np.uint8)
        symbols[: len(wire.octets)] |= WORD_VALID
        if wire.error_offsets:
            symbols[list(wire.error_offsets)] |= WORD_ERROR
        return symbols
