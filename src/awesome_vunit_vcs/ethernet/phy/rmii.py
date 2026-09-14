"""
RMII: two bits, a dibit, per symbol, least significant bits of an octet first.

The Reduced Media Independent Interface carries 10 Mb/s and 100 Mb/s Ethernet
on a 50 MHz reference clock: a dibit per clock cycle at 100 Mb/s and the same
dibit for 10 clock cycles at 10 Mb/s. On receive ``CRS_DV`` combines carrier
sense and data valid. When the carrier ends while the PHY still has data to
deliver, ``CRS_DV`` toggles: low on the first and high on the second dibit of
every nibble until the data is delivered.

The VHDL frontend records one sample word per dibit (every 10th clock cycle at
10 Mb/s) while ``CRS_DV`` or ``TX_EN`` is asserted, both samples after it
deasserts in a frame, and a word whenever the sampled values change otherwise::

    bit  0-1   dibit (TXD/RXD)
    bit  8     valid   (TX_EN/CRS_DV)
    bit  9     error   (RX_ER)
    bit 10     metavalue on the dibit while valid
    bit 11     metavalue on valid or error

Decoding pairs the dibits of a frame into the octet words of :mod:`.common`,
each with the time of its first dibit and the error and metavalue flags of all
four dibits. A sample without valid in a frame that is followed by a sample
with valid is a toggling ``CRS_DV`` and carries data; two samples in a row
without valid end the frame. The ``00`` dibits a PHY presents after asserting
``CRS_DV`` and before the preamble are dropped. The grouping of dibits is
aligned on the start frame delimiter, whose last dibit is ``11`` after
preamble dibits ``01``; a frame without a delimiter is grouped from its first
dibit. A frame that ends with an incomplete octet ends with an octet word
flagged ``WORD_ALIGNMENT`` (see :mod:`.common`), which the checker reports as a
termination violation (ETH_TERMINATION).
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

#: The dibit of a sample word
DIBIT_MASK = 0x3

#: The dibit of the preamble, ``01``
PREAMBLE_DIBIT = 0x1

#: The last dibit of the SFD (octet 0xD5), ``11``
SFD_LAST_DIBIT = 0x3

#: Dibits buffered while looking for the SFD before the frame is grouped from its start
MAX_PREAMBLE_DIBITS = 128

_FLAGS = WORD_ERROR | WORD_META


class RmiiPhy:
    """
    Decoder and encoder of an RMII interface.

    Args:
        link_rate_bps: The rate of the link, 10 Mb/s or 100 Mb/s, used for
            utilization statistics; inter-frame gaps are measured from the octet
            times, four dibits per octet.
        crs_dv_toggle_octets: Encoding only: toggle valid, low on the first and
            high on the second dibit of every nibble, during the last this many
            octets of every frame, like a PHY whose carrier ends before its data.

    Raises:
        EthernetValueError: If ``link_rate_bps`` is not positive or
            ``crs_dv_toggle_octets`` is negative.
    """

    name = "rmii"

    def __init__(self, link_rate_bps: int = 100_000_000, crs_dv_toggle_octets: int = 0) -> None:
        if link_rate_bps <= 0:
            raise EthernetValueError(f"link_rate_bps must be positive, got {link_rate_bps}")
        if crs_dv_toggle_octets < 0:
            raise EthernetValueError(f"crs_dv_toggle_octets must not be negative, got {crs_dv_toggle_octets}")
        self.link_rate_bps = link_rate_bps
        self.crs_dv_toggle_octets = crs_dv_toggle_octets
        self._in_frame = False
        self._aligned = False
        self._leading = True
        self._dibits: list[tuple[int, int]] = []
        self._pending_idle: tuple[int, int] | None = None

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        """
        Turn RMII sample words into octet words.

        The decoder keeps the dibits of an incomplete octet, a preamble it is
        still aligning and a sample without valid it cannot yet classify from
        one batch to the next, so a frame may span batches.

        Args:
            words: Sample words as recorded by ``rmii_monitor``.
            times: The time of each sample in femtoseconds.

        Returns:
            The octet words completed by this batch, and the idle words.
        """
        out_words: list[int] = []
        out_times: list[int] = []
        for word, time in zip(words.tolist(), times.tolist(), strict=True):
            if word & WORD_VALID:
                if self._pending_idle is not None:
                    # A toggling CRS_DV: the sample without valid carries data
                    pending_word, pending_time = self._pending_idle
                    self._pending_idle = None
                    self._add_dibit(pending_word | WORD_VALID, pending_time, out_words, out_times)
                if not self._in_frame:
                    self._in_frame = True
                    self._aligned = False
                    self._leading = True
                    self._dibits = []
                self._add_dibit(word, time, out_words, out_times)
            elif self._in_frame and self._pending_idle is None:
                self._pending_idle = (word, time)
            else:
                if self._pending_idle is not None:
                    pending_word, pending_time = self._pending_idle
                    self._pending_idle = None
                    self._end_frame(out_words, out_times)
                    out_words.append(pending_word & (DIBIT_MASK | _FLAGS))
                    out_times.append(pending_time)
                out_words.append(word & (DIBIT_MASK | _FLAGS))
                out_times.append(time)
        return OctetBatch(np.array(out_words, dtype=np.int64), np.array(out_times, dtype=np.int64))

    def encode(self, wire: WireFrame) -> Int32Array:
        """
        Turn a wire frame into one sample word per dibit.

        Args:
            wire: The octets to transmit, their error offsets and the IFG.

        Returns:
            Four dibit words per octet, least significant bits first, then four
            idle words per IFG octet. All dibits of an octet at an error offset
            have the error bit set.
        """
        count = len(wire.octets)
        symbols = np.zeros(4 * (count + wire.ifg_octets), dtype=np.int32)
        octets = np.frombuffer(wire.octets, dtype=np.uint8).astype(np.int32)
        for index in range(4):
            symbols[index : 4 * count : 4] = ((octets >> (2 * index)) & DIBIT_MASK) | WORD_VALID
        for offset in wire.wire_error_offsets:
            symbols[4 * offset : 4 * offset + 4] |= WORD_ERROR
        for offset in range(max(0, count - self.crs_dv_toggle_octets), count):
            symbols[4 * offset] &= ~WORD_VALID
            symbols[4 * offset + 2] &= ~WORD_VALID
        return symbols

    def _add_dibit(self, word: int, time: int, out_words: list[int], out_times: list[int]) -> None:
        """Add a dibit of a frame, dropping the ``00`` dibits before its preamble."""
        if self._leading and not word & (DIBIT_MASK | _FLAGS):
            return
        self._leading = False
        self._dibits.append((word, time))
        if self._aligned:
            if len(self._dibits) == 4:
                self._emit_octets(out_words, out_times)
        else:
            self._align(out_words, out_times)

    def _align(self, out_words: list[int], out_times: list[int]) -> None:
        """Fix the grouping of the frame once the SFD, or its absence, is known."""
        dibits = [word & DIBIT_MASK for word, _ in self._dibits]
        last = dibits[-1]
        if last == PREAMBLE_DIBIT and len(dibits) < MAX_PREAMBLE_DIBITS:
            return
        if last == SFD_LAST_DIBIT and len(dibits) >= 4 and all(d == PREAMBLE_DIBIT for d in dibits[:-1]):
            # The SFD must be the last dibit of a group
            del self._dibits[: len(dibits) % 4]
        self._aligned = True
        self._emit_octets(out_words, out_times)

    def _emit_octets(self, out_words: list[int], out_times: list[int]) -> None:
        """Emit the complete groups of four dibits, keeping an incomplete last group."""
        octets = len(self._dibits) // 4
        for index in range(octets):
            group = self._dibits[4 * index : 4 * index + 4]
            out_words.append(self._octet_word(group))
            out_times.append(group[0][1])
        del self._dibits[: 4 * octets]

    @staticmethod
    def _octet_word(group: list[tuple[int, int]]) -> int:
        octet = 0
        flags = 0
        for index, (word, _) in enumerate(group):
            octet |= (word & DIBIT_MASK) << (2 * index)
            flags |= word & _FLAGS
        return octet | WORD_VALID | flags

    def _end_frame(self, out_words: list[int], out_times: list[int]) -> None:
        """Close the frame when valid is deasserted for two samples."""
        self._aligned = True
        self._emit_octets(out_words, out_times)
        if self._dibits:
            out_words.append(self._octet_word(self._dibits) | WORD_ALIGNMENT)
            out_times.append(self._dibits[0][1])
            self._dibits = []
        self._in_frame = False
