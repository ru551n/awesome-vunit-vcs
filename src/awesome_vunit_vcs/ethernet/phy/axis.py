"""
AXI-Stream MAC client: frames as AXI-Stream packets, without preamble and SFD.

The VHDL monitor records one sample word per octet lane of every clock edge
where ``tvalid`` is high or the bus changed, lane 0 first. Each lane word::

    bit  0-7   tdata of the lane
    bit  8     tkeep of the lane
    bit  9     tuser(0), the error bit
    bit 10     metavalue on the data of the lane
    bit 11     metavalue on tvalid, tready, tlast, tkeep or tuser
    bit 13     tvalid
    bit 14     tready
    bit 15     tlast

The decoder turns every handshake (``tvalid`` and ``tready`` high) into octet
words for the kept lanes and ends a frame at ``tlast``; ``tuser(0)`` with
``tlast`` marks the frame errored. It also reports the AXI-Stream rules a MAC
client relies on as :class:`~.common.PhyEvent`: ``tkeep`` contiguous and only
partial on the last beat (``ETH_KEEP``), the bus stable while ``tvalid`` waits
for ``tready`` (``ETH_STABLE``) and ``tvalid`` not deasserted before the
handshake (``ETH_VALID``).
"""

from __future__ import annotations

import random

import numpy as np

from ..errors import EthernetValueError
from .common import (
    WORD_ERROR,
    WORD_META_DATA,
    WORD_VALID,
    Int32Array,
    Int64Array,
    OctetBatch,
    PhyEvent,
    WireFrame,
)

AXIS_DATA_MASK = 0xFF
AXIS_KEEP = 1 << 8
AXIS_USER = 1 << 9
AXIS_META_DATA = 1 << 10
AXIS_META_CTRL = 1 << 11
AXIS_VALID = 1 << 13
AXIS_READY = 1 << 14
AXIS_LAST = 1 << 15

FCS_OCTETS = 4


class AxisPhy:
    """
    The AXI-Stream MAC client frontend.

    Args:
        link_rate_bps: The rate for utilization statistics and sample times; 10G by default.
        lanes: Bytes per beat, the width of ``tkeep``.
        has_fcs: Whether frames on the bus carry the FCS. Sources without FCS drop it.
        valid_low_percent: Sources: the chance in percent of a clock with ``tvalid``
            low before each beat after the first of a frame.
        ready_low_percent: :meth:`encode` only: the chance in percent of a clock with
            ``tready`` low before a handshake, as a sink applying backpressure
            records it. VHDL sources ignore ``tready`` in the words they are given.
        seed: The seed of the stall patterns.

    Raises:
        EthernetValueError: An invalid lane count or percentage.
    """

    name = "axis"
    #: Frames on an AXI-Stream MAC client interface have no preamble or SFD
    has_preamble = False

    def __init__(
        self,
        link_rate_bps: int = 10_000_000_000,
        lanes: int = 8,
        *,
        has_fcs: bool = True,
        valid_low_percent: int = 0,
        ready_low_percent: int = 0,
        seed: int = 0,
    ) -> None:
        if lanes < 1:
            raise EthernetValueError(f"An AXI-Stream interface has at least 1 octet per beat, got {lanes}")
        for label, value in (("valid_low_percent", valid_low_percent), ("ready_low_percent", ready_low_percent)):
            if not 0 <= value < 100:
                raise EthernetValueError(f"{label} must be 0 to 99, got {value}")
        self.link_rate_bps = link_rate_bps
        self.lanes = lanes
        self.has_fcs = has_fcs
        self.valid_low_percent = valid_low_percent
        self.ready_low_percent = ready_low_percent
        self._rng = random.Random(seed)
        self._previous: list[int] | None = None
        self._remainder = np.zeros(0, dtype=np.int64)
        self._remainder_times = np.zeros(0, dtype=np.int64)
        self._started = False

    # Decoding
    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch:
        """Turn recorded lane words into octet words, one per kept octet of every handshake."""
        lanes = self.lanes
        if self._remainder.size:
            words = np.concatenate([self._remainder, words])
            times = np.concatenate([self._remainder_times, times])
        complete = words.size // lanes * lanes
        self._remainder = words[complete:].copy()
        self._remainder_times = times[complete:].copy()

        out_words: list[int] = []
        out_times: list[int] = []
        events: list[PhyEvent] = []
        for start in range(0, complete, lanes):
            column = [int(word) for word in words[start : start + lanes]]
            time = int(times[start])
            if not self._started:
                # A leading idle word, so the first frame is not taken as already in progress
                out_words.append(0)
                out_times.append(time)
                self._started = True
            self._decode_column(column, time, out_words, out_times, events)
        return OctetBatch(np.array(out_words, dtype=np.int64), np.array(out_times, dtype=np.int64), tuple(events))

    def _decode_column(
        self, column: list[int], time: int, out_words: list[int], out_times: list[int], events: list[PhyEvent]
    ) -> None:
        control = column[0]
        valid = bool(control & AXIS_VALID)
        ready = bool(control & AXIS_READY)
        if control & AXIS_META_CTRL:
            events.append(PhyEvent(time, "ETH_METAVALUE", "metavalue on tvalid, tready, tlast, tkeep or tuser"))

        previous = self._previous
        if previous is not None and previous[0] & AXIS_VALID and not previous[0] & AXIS_READY:
            if not valid:
                events.append(PhyEvent(time, "ETH_VALID", "tvalid was deasserted before tready accepted the beat"))
            elif [word & ~AXIS_READY for word in column] != [word & ~AXIS_READY for word in previous]:
                events.append(
                    PhyEvent(time, "ETH_STABLE", "tdata, tkeep, tlast or tuser changed while tvalid waited for tready")
                )
        self._previous = column

        if not (valid and ready):
            return
        keep = [bool(word & AXIS_KEEP) for word in column]
        kept = sum(keep)
        last = bool(control & AXIS_LAST)
        contiguous = all(keep[:kept]) and not any(keep[kept:])
        if not contiguous or (not last and kept != self.lanes) or (last and kept == 0):
            pattern = "".join("1" if bit else "0" for bit in reversed(keep))
            where = "the last beat of a frame" if last else "a beat before the last"
            events.append(
                PhyEvent(
                    time,
                    "ETH_KEEP",
                    f"tkeep {pattern} on {where}",
                    ("only the last beat may be partial, with the low-order octets kept",),
                )
            )
        for lane, word in enumerate(column):
            if keep[lane]:
                meta = WORD_META_DATA if word & AXIS_META_DATA else 0
                out_words.append((word & AXIS_DATA_MASK) | WORD_VALID | meta)
                out_times.append(time)
        if last:
            if control & AXIS_USER and out_words and out_words[-1] & WORD_VALID:
                out_words[-1] |= WORD_ERROR
            out_words.append(0)
            out_times.append(time)

    # Encoding
    def encode(self, wire: WireFrame) -> Int32Array:
        """
        The beats of a frame, ``lanes`` words per clock, then ``wire.ifg_octets`` idle clocks.

        The preamble and SFD of the wire frame are not sent, nor the FCS when the
        interface has none. An error offset inside the frame sets ``tuser(0)`` on
        the last beat.
        """
        start = wire.mac_offset
        frame = wire.octets[start:]
        if not self.has_fcs:
            frame = frame[:-FCS_OCTETS] if len(frame) >= FCS_OCTETS else b""
        errored = any(offset >= start for offset in wire.wire_error_offsets)
        lanes = self.lanes
        beats = max(1, -(-len(frame) // lanes))
        columns: list[list[int]] = []
        for beat in range(beats):
            chunk = frame[beat * lanes : (beat + 1) * lanes]
            last = beat == beats - 1
            if beat > 0 and self._rng.randrange(100) < self.valid_low_percent:
                columns.append([AXIS_READY] * lanes)
            flags = AXIS_VALID | AXIS_READY | (AXIS_LAST if last else 0) | (AXIS_USER if last and errored else 0)
            column = [flags | ((chunk[lane] | AXIS_KEEP) if lane < len(chunk) else 0) for lane in range(lanes)]
            while self._rng.randrange(100) < self.ready_low_percent:
                columns.append([word & ~AXIS_READY for word in column])
            columns.append(column)
        columns.extend([[AXIS_READY] * lanes] * wire.ifg_octets)
        return np.array(columns, dtype=np.int32).reshape(-1)
