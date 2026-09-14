"""
Ethernet interfaces as values, and the sample words they carry.

An :class:`Interface` names a PHY interface and its configuration: ``GMII``,
``MII`` and ``XGMII(lanes=8, rate="100G")``. It creates the PHY decoder and
encoder, knows its clock period and turns frames into :class:`Samples`, the
sample words a VHDL monitor records, so decoders can be exercised without a
simulator.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass, replace
from typing import Protocol, runtime_checkable

import numpy as np
import numpy.typing as npt

from .errors import EthernetValueError
from .limits import LIMITS
from .phy.common import Int64Array, PhyInterface, WireFrame
from .phy.gmii import GmiiPhy
from .phy.mii import MiiPhy
from .phy.xgmii import WORD_CONTROL, XGMII_IDLE, XgmiiPhy
from .source import build_wire_frame
from .units import FS_PER_SECOND, bps

#: The names of the interfaces an :class:`Interface` can describe
INTERFACE_NAMES = ("gmii", "mii", "xgmii")


@runtime_checkable
class SupportsToWire(Protocol):
    """Anything with a ``to_wire()`` method, such as :class:`~awesome_vunit_vcs.ethernet.api.Frame`."""

    def to_wire(self) -> WireFrame:
        """What a source puts on the wire for this frame."""
        ...


#: The forms :meth:`Interface.encode` accepts per frame, a wire frame, something
#: with ``to_wire()`` or frame octets without FCS
Encodable = WireFrame | SupportsToWire | bytes


@dataclass(slots=True, frozen=True, eq=False)
class Samples:
    """
    Sample words and the time of each in femtoseconds, as a VHDL monitor records them.

    The word layout is interface specific, see :mod:`.phy.common`. Wide
    interfaces (the XGMII family) record one word per lane, all lanes of a
    clock edge at the same time.

    Raises:
        EthernetValueError: The arrays are not one-dimensional and of equal length.
    """

    words: Int64Array
    times: Int64Array

    def __post_init__(self) -> None:
        if self.words.ndim != 1 or self.times.ndim != 1 or self.words.size != self.times.size:
            raise EthernetValueError(
                f"Samples need one time per word, got {self.words.shape} words and {self.times.shape} times"
            )

    @classmethod
    def from_arrays(cls, words: npt.ArrayLike, times: npt.ArrayLike) -> Samples:
        """
        Samples from anything NumPy converts, copied as 64-bit integers.

        Args:
            words: The sample words.
            times: The time of each word in femtoseconds, not decreasing.
        """
        return cls(np.array(words, dtype=np.int64).reshape(-1), np.array(times, dtype=np.int64).reshape(-1))

    def __len__(self) -> int:
        return int(self.words.size)

    def __add__(self, other: Samples) -> Samples:
        """The samples followed by ``other``."""
        return Samples(np.concatenate([self.words, other.words]), np.concatenate([self.times, other.times]))

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Samples):
            return NotImplemented
        return bool(np.array_equal(self.words, other.words) and np.array_equal(self.times, other.times))

    __hash__ = None  # type: ignore[assignment]


@dataclass(slots=True, frozen=True)
class Interface:
    """
    An Ethernet PHY interface and its configuration.

    Use the predefined :data:`GMII` and :data:`MII`, and :func:`XGMII` for the
    XGMII family; :meth:`with_rate` changes the link rate.

    Args:
        name: One of :data:`INTERFACE_NAMES`.
        link_rate_bps: The link rate in bits per second.
        lanes: 1, or the lane count of the XGMII family (4 or 8).
        allow_lane4_start: XGMII with 8 lanes: accept frames that start on lane 4.
        deficit_idle: XGMII sources: round gaps like a deficit idle count.

    Raises:
        EthernetValueError: The combination is not a valid interface.
    """

    name: str
    link_rate_bps: int
    lanes: int = 1
    allow_lane4_start: bool = False
    deficit_idle: bool = True

    def __post_init__(self) -> None:
        if self.name not in INTERFACE_NAMES:
            raise EthernetValueError(f"Unknown interface {self.name!r}, known: {', '.join(INTERFACE_NAMES)}")
        if self.link_rate_bps <= 0:
            raise EthernetValueError(f"link_rate_bps must be positive, got {self.link_rate_bps}")
        if self.name == "xgmii":
            if self.lanes not in LIMITS.xgmii_lanes:
                raise EthernetValueError(f"An XGMII interface has 4 or 8 lanes, got {self.lanes}")
        elif self.lanes != 1:
            raise EthernetValueError(f"A {self.name.upper()} interface has 1 lane, got {self.lanes}")
        if self.name == "mii" and self.link_rate_bps not in LIMITS.mii_rates_bps:
            raise EthernetValueError(f"MII runs at 10 or 100 Mb/s, got {self.link_rate_bps} bps")
        if self.allow_lane4_start and self.lanes != 8:
            raise EthernetValueError("allow_lane4_start needs 8 lanes")

    def with_rate(self, rate: int | str) -> Interface:
        """
        The same interface at another link rate.

        Args:
            rate: Bits per second, or a string such as ``"2.5G"``.
        """
        return replace(self, link_rate_bps=bps(rate))

    @property
    def words_per_clock(self) -> int:
        """The number of sample words recorded per clock edge, which is the lane count."""
        return self.lanes

    @property
    def clock_period_fs(self) -> int:
        """The time in fs between recorded clock edges, one octet (GMII), nibble (MII) or column (XGMII) apart."""
        bits_per_clock = {"gmii": 8, "mii": 4, "xgmii": 8 * self.lanes}[self.name]
        return bits_per_clock * FS_PER_SECOND // self.link_rate_bps

    @property
    def min_ifg_octets(self) -> int:
        """The smallest inter-frame gap in octets a monitor of this interface accepts, 12 or 5 for the XGMII family."""
        return LIMITS.min_xgmii_ifg_octets if self.name == "xgmii" else LIMITS.min_ifg_octets

    def phy(self) -> PhyInterface:
        """A new PHY decoder and encoder for this interface; each keeps its own decoding state."""
        if self.name == "gmii":
            return GmiiPhy(self.link_rate_bps)
        if self.name == "mii":
            return MiiPhy(self.link_rate_bps)
        return XgmiiPhy(
            self.link_rate_bps,
            self.lanes,
            allow_lane4_start=self.allow_lane4_start,
            deficit_idle=self.deficit_idle,
        )

    def idle(self, clocks: int, *, start_fs: int = 0) -> Samples:
        """
        Idle samples: no frame on the line.

        Args:
            clocks: Clock edges to record.
            start_fs: The time of the first edge.
        """
        if clocks < 0:
            raise EthernetValueError(f"clocks must not be negative, got {clocks}")
        return self._times(self._idle_words(clocks), start_fs)

    def encode(self, frames: Iterable[Encodable], *, idle_clocks: int = 12, start_fs: int = 0) -> Samples:
        """
        The samples of frames on the line, as a VHDL monitor records them.

        Args:
            frames: Wire frames, objects with ``to_wire()`` such as
                :class:`~awesome_vunit_vcs.ethernet.api.Frame`, or frame octets
                without FCS (sent with the default wire options).
            idle_clocks: Idle clock edges before the first frame. A frame that
                starts at the first sample is reported as already in progress.
            start_fs: The time of the first sample.

        Returns:
            The idle samples, then every frame followed by its inter-frame gap.
        """
        return self.encode_with(self.phy(), frames, idle_clocks=idle_clocks, start_fs=start_fs)

    def encode_with(
        self, phy: PhyInterface, frames: Iterable[Encodable], *, idle_clocks: int = 0, start_fs: int = 0
    ) -> Samples:
        """Like :meth:`encode`, with an encoder whose state (the XGMII deficit idle count) carries over."""
        if idle_clocks < 0:
            raise EthernetValueError(f"idle_clocks must not be negative, got {idle_clocks}")
        parts = [self._idle_words(idle_clocks)]
        for item in frames:
            parts.append(phy.encode(to_wire_frame(item)).astype(np.int64))
        return self._times(np.concatenate(parts), start_fs)

    def _idle_words(self, clocks: int) -> Int64Array:
        idle = XGMII_IDLE | WORD_CONTROL if self.name == "xgmii" else 0
        return np.full(clocks * self.words_per_clock, idle, dtype=np.int64)

    def _times(self, words: Int64Array, start_fs: int) -> Samples:
        clocks = np.arange(words.size, dtype=np.int64) // self.words_per_clock
        return Samples(words, start_fs + clocks * self.clock_period_fs)


def to_wire_frame(item: Encodable) -> WireFrame:
    """
    What a source puts on the wire for a frame given in any form :meth:`Interface.encode` accepts.

    Raises:
        EthernetValueError: The item is none of those forms.
    """
    if isinstance(item, WireFrame):
        return item
    if isinstance(item, bytes | bytearray | memoryview):
        return build_wire_frame(bytes(item))
    if isinstance(item, SupportsToWire):
        return item.to_wire()
    raise EthernetValueError(f"Cannot put {type(item).__name__} on the wire; expected a Frame, a WireFrame or bytes")


#: GMII at 1 Gb/s
GMII = Interface("gmii", 1_000_000_000)

#: MII at 100 Mb/s; ``MII.with_rate("10M")`` for 10 Mb/s
MII = Interface("mii", 100_000_000)


def XGMII(
    lanes: int = 4, rate: int | str = "10G", *, allow_lane4_start: bool = False, deficit_idle: bool = True
) -> Interface:
    """
    An interface of the XGMII family.

    Args:
        lanes: 4 (XGMII, 2.5GMII, 5GMII) or 8 (the 64-bit variants, 25GMII, XLGMII, CGMII,
            200GMII, 400GMII).
        rate: The link rate, for example ``"10G"``, ``"100G"`` or ``"400G"``.
        allow_lane4_start: Accept frames that start on lane 4 of an 8-lane interface.
        deficit_idle: Sources round gaps to whole columns like a deficit idle count.

    Raises:
        EthernetValueError: An invalid lane count or rate.
    """
    return Interface("xgmii", bps(rate), lanes, allow_lane4_start, deficit_idle)
