"""
The common octet-stream model every PHY frontend is normalized to.

A PHY decoder turns the interface specific sample words VHDL recorded (8-bit
GMII octets, 4-bit MII nibbles, 2-bit RMII dibits, ...) into *octet words*:
one word per received octet with the time of its first symbol. The
:class:`FrameAssembler` then cuts that octet stream into :class:`PhyFrame`
objects, which is where the PHY specific part ends.

Word layout, shared by sample words and octet words::

    bit  0-7   data (sample words use the low bits of their symbol width)
    bit  8     valid   (GMII RX_DV/TX_EN, MII RX_DV, RMII CRS_DV, RGMII CTL)
    bit  9     error   (RX_ER/TX_ER)
    bit 10     metavalue on the data bits while valid
    bit 11     metavalue on valid or error
    bit 12     octet words only: incomplete final octet (alignment error)
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np
import numpy.typing as npt

WORD_DATA_MASK = 0xFF
WORD_VALID = 1 << 8
WORD_ERROR = 1 << 9
WORD_META_DATA = 1 << 10
WORD_META_CTRL = 1 << 11
WORD_ALIGNMENT = 1 << 12
WORD_META = WORD_META_DATA | WORD_META_CTRL

Int64Array = npt.NDArray[np.int64]
Int32Array = npt.NDArray[np.int32]


@dataclass(slots=True, frozen=True)
class OctetBatch:
    """Octet words and the time of each octet in fs."""

    words: Int64Array
    times: Int64Array


@dataclass(slots=True, frozen=True)
class WireFrame:
    """
    What a source puts on the wire for one frame.

    ``octets`` is everything transmitted while valid: preamble, SFD, frame
    and FCS. ``error_offsets`` are wire octet indexes (0 is the first
    preamble octet) transmitted with the error signal asserted.
    ``ifg_octets`` idle octets follow the frame.
    """

    octets: bytes
    error_offsets: tuple[int, ...] = ()
    ifg_octets: int = 12

    def __post_init__(self) -> None:
        if self.ifg_octets < 0:
            raise ValueError(f"ifg_octets must not be negative, got {self.ifg_octets}")
        for offset in self.error_offsets:
            if not 0 <= offset < len(self.octets):
                raise ValueError(f"Error offset {offset} is outside the {len(self.octets)} wire octets")


@dataclass(slots=True, frozen=True)
class PhyFrame:
    """
    Raw octets observed during one assertion of valid.

    Offsets are wire octet indexes, 0 being the first octet observed (normally
    the first preamble octet).
    """

    index: int
    octets: bytes
    octet_times_fs: tuple[int, ...]
    #: Time of the first sample where valid was observed deasserted
    timestamp_end_fs: int
    error_offsets: tuple[int, ...] = ()
    metavalue_offsets: tuple[int, ...] = ()
    #: The frame ended with an incomplete octet (MII/RMII)
    alignment_error: bool = False
    #: Valid was already asserted at the first sample the monitor recorded
    started_in_progress: bool = False
    #: Time of the last octet of the previous frame, None for the first frame
    previous_last_octet_fs: int | None = None

    @property
    def timestamp_start_fs(self) -> int:
        return self.octet_times_fs[0]

    @property
    def octet_period_fs(self) -> int | None:
        if len(self.octet_times_fs) < 2:
            return None
        return self.octet_times_fs[1] - self.octet_times_fs[0]


@dataclass(slots=True, frozen=True)
class IdleEvent:
    """A sample outside a frame with the error signal asserted or a metavalue."""

    timestamp_fs: int
    word: int

    @property
    def value(self) -> int:
        return self.word & WORD_DATA_MASK

    @property
    def error(self) -> bool:
        return bool(self.word & WORD_ERROR)

    @property
    def metavalue(self) -> bool:
        return bool(self.word & WORD_META)


class PhyInterface(Protocol):
    """A PHY frontend: sample words to octets, and wire frames to sample words."""

    name: str
    link_rate_bps: int

    def decode(self, words: Int64Array, times: Int64Array) -> OctetBatch: ...

    def encode(self, wire: WireFrame) -> Int32Array: ...


class FrameAssembler:
    """Cut an octet stream into :class:`PhyFrame` and :class:`IdleEvent` objects."""

    def __init__(self) -> None:
        self._index = 0
        self._seen_idle = False
        self._in_frame = False
        self._started_in_progress = False
        self._octets = bytearray()
        self._times: list[int] = []
        self._errors: list[int] = []
        self._meta: list[int] = []
        self._alignment = False
        self._previous_last_octet_fs: int | None = None

    @property
    def in_frame(self) -> bool:
        return self._in_frame

    def feed(self, batch: OctetBatch) -> list[PhyFrame | IdleEvent]:
        words, times = batch.words, batch.times
        count = int(words.size)
        out: list[PhyFrame | IdleEvent] = []
        if count == 0:
            return out

        valid = (words & WORD_VALID) != 0
        boundaries = (np.flatnonzero(valid[1:] != valid[:-1]) + 1).tolist()
        for start, end in zip([0, *boundaries], [*boundaries, count], strict=True):
            segment = words[start:end]
            if valid[start]:
                self._extend(segment, times[start:end])
            else:
                if self._in_frame:
                    out.append(self._close(int(times[start])))
                self._seen_idle = True
                for offset in np.flatnonzero(segment & (WORD_ERROR | WORD_META)).tolist():
                    out.append(IdleEvent(int(times[start + offset]), int(segment[offset])))
        return out

    def finish(self, end_fs: int) -> PhyFrame | None:
        """Close a frame still in progress, for example at the end of a simulation."""
        return self._close(end_fs) if self._in_frame else None

    def _extend(self, segment: Int64Array, times: Int64Array) -> None:
        if not self._in_frame:
            self._in_frame = True
            self._started_in_progress = not self._seen_idle
            self._octets = bytearray()
            self._times = []
            self._errors = []
            self._meta = []
            self._alignment = False
        offset = len(self._octets)
        self._octets += (segment & WORD_DATA_MASK).astype(np.uint8).tobytes()
        self._times.extend(times.tolist())
        self._errors.extend((np.flatnonzero(segment & WORD_ERROR) + offset).tolist())
        self._meta.extend((np.flatnonzero(segment & WORD_META) + offset).tolist())
        if bool((segment & WORD_ALIGNMENT).any()):
            self._alignment = True

    def _close(self, end_fs: int) -> PhyFrame:
        frame = PhyFrame(
            index=self._index,
            octets=bytes(self._octets),
            octet_times_fs=tuple(self._times),
            timestamp_end_fs=end_fs,
            error_offsets=tuple(self._errors),
            metavalue_offsets=tuple(self._meta),
            alignment_error=self._alignment,
            started_in_progress=self._started_in_progress,
            previous_last_octet_fs=self._previous_last_octet_fs,
        )
        self._index += 1
        self._in_frame = False
        self._previous_last_octet_fs = self._times[-1]
        return frame
