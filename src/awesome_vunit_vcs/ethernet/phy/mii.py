"""
MII: one 4-bit symbol, a nibble, per clock cycle.

The Media Independent Interface of IEEE 802.3 Clause 22 carries 10 Mb/s and
100 Mb/s Ethernet. ``TX_CLK`` and ``RX_CLK`` run at a quarter of the bit rate,
2.5 MHz and 25 MHz, and every octet is transferred least significant nibble
first with ``TXD<0>``/``RXD<0>`` its least significant bit.

The VHDL frontend samples ``data``/``dv``/``er`` on the rising edge and records
one sample word per clock cycle while ``dv`` is asserted, and a word whenever
the sampled values change otherwise::

    bit  0-3   nibble (TXD/RXD)
    bit  8     valid   (TX_EN/RX_DV)
    bit  9     error   (TX_ER/RX_ER)
    bit 10     metavalue on the nibble while valid
    bit 11     metavalue on valid or error

Decoding pairs the nibbles of a frame into the octet words of :mod:`.common`,
each with the time of its first nibble and the error and metavalue flags of
both nibbles. The pairing is aligned on the start frame delimiter: any number
of ``0x5`` nibbles may precede its nibbles ``0x5`` ``0xD``, and a leading
nibble that has no partner before the delimiter is dropped rather than
misaligning the frame. A frame without a delimiter is paired from its first
nibble. A frame that ends with an unpaired nibble ends with an octet word
flagged ``WORD_ALIGNMENT`` (see :mod:`.common`), which the checker reports as a
termination violation (ETH_TERMINATION), an alignment error in the terms of
IEEE 802.3 4.2.4.2.1.
"""

from __future__ import annotations

import numpy as np

from ..errors import EthernetValueError
from .common import (
    WORD_ALIGNMENT,
    WORD_ERROR,
    WORD_META,
    WORD_VALID,
    Int32Array,
    Int64Array,
    OctetBatch,
    WireFrame,
)

#: The nibble of a sample word
NIBBLE_MASK = 0xF

#: The nibble of every preamble octet and the low nibble of the SFD
PREAMBLE_NIBBLE = 0x5

#: The high nibble of the SFD (octet 0xD5)
SFD_HIGH_NIBBLE = 0xD

#: Nibbles buffered while looking for the SFD before the frame is paired from its start
MAX_PREAMBLE_NIBBLES = 64

_FLAGS = WORD_ERROR | WORD_META


class MiiPhy:
    """
    Decoder and encoder of an MII interface.

    Args:
        link_rate_bps: The rate of the link, 10 Mb/s or 100 Mb/s. It is used
            for utilization statistics; inter-frame gaps are measured from the
            octet times, two clock cycles per octet.

    Raises:
        ValueError: If ``link_rate_bps`` is not positive.
    """

    name = "mii"

    def __init__(self, link_rate_bps: int = 100_000_000) -> None:
        if link_rate_bps <= 0:
            raise EthernetValueError(f"link_rate_bps must be positive, got {link_rate_bps}")
        self.link_rate_bps = link_rate_bps
        self._in_frame = False
        self._aligned = False
        self._nibbles: list[tuple[int, int]] = []

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        """
        Turn MII sample words into octet words.

        The decoder keeps the nibbles of an octet, or of a preamble it is still
        aligning, from one batch to the next, so a frame may span batches.

        Args:
            words: Sample words as recorded by ``mii_monitor``.
            times: The time of each sample in femtoseconds.

        Returns:
            The octet words completed by this batch, and the idle words.
        """
        out_words: list[int] = []
        out_times: list[int] = []
        for word, time in zip(words.tolist(), times.tolist(), strict=True):
            if word & WORD_VALID:
                if not self._in_frame:
                    self._in_frame = True
                    self._aligned = False
                    self._nibbles = []
                self._nibbles.append((word, time))
                if self._aligned:
                    if len(self._nibbles) == 2:
                        self._emit_pairs(out_words, out_times)
                else:
                    self._align(out_words, out_times)
            else:
                if self._in_frame:
                    self._end_frame(out_words, out_times)
                out_words.append(word & (NIBBLE_MASK | _FLAGS))
                out_times.append(time)
        return OctetBatch(np.array(out_words, dtype=np.int64), np.array(out_times, dtype=np.int64))

    def encode(self, wire: WireFrame) -> Int32Array:
        """
        Turn a wire frame into one sample word per clock cycle.

        Args:
            wire: The octets to transmit, their error offsets and the IFG.

        Returns:
            Two nibble words per octet, least significant nibble first, then
            two idle words per IFG octet. Both nibbles of an octet at an error
            offset have the error bit set.
        """
        count = len(wire.octets)
        symbols = np.zeros(2 * (count + wire.ifg_octets), dtype=np.int32)
        octets = np.frombuffer(wire.octets, dtype=np.uint8).astype(np.int32)
        symbols[0 : 2 * count : 2] = (octets & NIBBLE_MASK) | WORD_VALID
        symbols[1 : 2 * count : 2] = (octets >> 4) | WORD_VALID
        for offset in wire.wire_error_offsets:
            symbols[2 * offset : 2 * offset + 2] |= WORD_ERROR
        return symbols

    def _align(self, out_words: list[int], out_times: list[int]) -> None:
        """Fix the nibble pairing of the frame once the SFD, or its absence, is known."""
        nibbles = [word & NIBBLE_MASK for word, _ in self._nibbles]
        last = nibbles[-1]
        if last == PREAMBLE_NIBBLE and len(nibbles) < MAX_PREAMBLE_NIBBLES:
            return
        if last == SFD_HIGH_NIBBLE and len(nibbles) >= 2 and all(n == PREAMBLE_NIBBLE for n in nibbles[:-1]):
            # An unpaired first nibble would pair the SFD across two octets
            del self._nibbles[: (len(nibbles) - 2) % 2]
        self._aligned = True
        self._emit_pairs(out_words, out_times)

    def _emit_pairs(self, out_words: list[int], out_times: list[int]) -> None:
        """Emit the complete nibble pairs, keeping an unpaired last nibble."""
        pairs = len(self._nibbles) // 2
        for index in range(pairs):
            (low, time), (high, _) = self._nibbles[2 * index], self._nibbles[2 * index + 1]
            octet = (low & NIBBLE_MASK) | (high & NIBBLE_MASK) << 4
            out_words.append(octet | WORD_VALID | ((low | high) & _FLAGS))
            out_times.append(time)
        del self._nibbles[: 2 * pairs]

    def _end_frame(self, out_words: list[int], out_times: list[int]) -> None:
        """Close the frame when valid is deasserted."""
        self._aligned = True
        self._emit_pairs(out_words, out_times)
        if self._nibbles:
            word, time = self._nibbles.pop()
            out_words.append((word & (NIBBLE_MASK | _FLAGS)) | WORD_VALID | WORD_ALIGNMENT)
            out_times.append(time)
        self._in_frame = False
