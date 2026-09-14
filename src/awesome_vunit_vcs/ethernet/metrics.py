"""
Performance monitor: traffic statistics, a subscriber independent of the checker.

Definitions
-----------
* wire octets: preamble, SFD, frame and FCS (everything observed while valid)
* frame octets: destination address to FCS inclusive
* payload octets: after the 14-octet header, excluding the FCS (padding included)
* observation window: first frame start to last frame end
* link utilization: wire bits / (link rate * window)
* payload utilization: payload bits / (link rate * window)
* effective bit rate: frame bits / window

Latency needs two correlated streams and is left to a future scoreboard;
:class:`PerformanceMonitor` keeps the per-frame timestamps such a component needs.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .frame import FCS_OCTETS, HEADER_OCTETS, EthernetFrame
from .phy.common import IdleEvent

FS_PER_SECOND = 10**15

#: RFC 2819 frame size buckets (frame octets including FCS)
SIZE_BUCKETS: tuple[tuple[str, int, int | None], ...] = (
    ("<64", 0, 63),
    ("64", 64, 64),
    ("65-127", 65, 127),
    ("128-255", 128, 255),
    ("256-511", 256, 511),
    ("512-1023", 512, 1023),
    ("1024-1518", 1024, 1518),
    (">1518", 1519, None),
)


@dataclass(slots=True, frozen=True)
class Summary:
    """Count, minimum, maximum and mean of a series; None while the count is 0."""

    count: int = 0
    minimum: int | None = None
    maximum: int | None = None
    mean: float | None = None


class _Accumulator:
    __slots__ = ("count", "maximum", "minimum", "total")

    def __init__(self) -> None:
        self.count = 0
        self.total = 0
        self.minimum: int | None = None
        self.maximum: int | None = None

    def add(self, value: int) -> None:
        self.count += 1
        self.total += value
        self.minimum = value if self.minimum is None else min(self.minimum, value)
        self.maximum = value if self.maximum is None else max(self.maximum, value)

    def summary(self) -> Summary:
        mean = self.total / self.count if self.count else None
        return Summary(self.count, self.minimum, self.maximum, mean)


@dataclass(slots=True, frozen=True)
class EthernetStatistics:
    """
    A snapshot of the traffic a monitor observed, see the module definitions.

    Counts are frames, sizes octets, times fs and rates bps. ``frame_size``
    summarizes frame sizes including the FCS, ``ifg_octets`` and ``ifg_fs`` the
    gaps between frames, and ``size_histogram`` counts frames per RFC 2819
    size bucket. The rates and utilizations are None when the observation
    window is empty, and the utilizations also when the link rate is unknown.
    """

    total_frames: int = 0
    good_frames: int = 0
    bad_frames: int = 0
    wire_octets: int = 0
    frame_octets: int = 0
    payload_octets: int = 0
    fcs_errors: int = 0
    phy_error_frames: int = 0
    phy_error_symbols: int = 0
    idle_errors: int = 0
    runts: int = 0
    giants: int = 0
    preamble_errors: int = 0
    sfd_errors: int = 0
    alignment_errors: int = 0
    first_timestamp_fs: int | None = None
    last_timestamp_fs: int | None = None
    link_rate_bps: int = 0
    frame_size: Summary = field(default_factory=Summary)
    ifg_octets: Summary = field(default_factory=Summary)
    ifg_fs: Summary = field(default_factory=Summary)
    size_histogram: tuple[tuple[str, int], ...] = ()

    @property
    def duration_fs(self) -> int:
        """The observation window in fs: first frame start to last frame end."""
        if self.first_timestamp_fs is None or self.last_timestamp_fs is None:
            return 0
        return self.last_timestamp_fs - self.first_timestamp_fs

    def _per_second(self, value: float) -> float | None:
        return value * FS_PER_SECOND / self.duration_fs if self.duration_fs > 0 else None

    @property
    def frames_per_second(self) -> float | None:
        """Frames per second of simulation time."""
        return self._per_second(self.total_frames)

    @property
    def bit_rate_bps(self) -> float | None:
        """Effective bit rate: frame bits (destination address to FCS) per second."""
        return self._per_second(8 * self.frame_octets)

    @property
    def link_utilization(self) -> float | None:
        """Wire bits per second as a fraction of the link rate."""
        rate = self._per_second(8 * self.wire_octets)
        return None if rate is None or not self.link_rate_bps else rate / self.link_rate_bps

    @property
    def payload_utilization(self) -> float | None:
        """Payload bits per second as a fraction of the link rate."""
        rate = self._per_second(8 * self.payload_octets)
        return None if rate is None or not self.link_rate_bps else rate / self.link_rate_bps

    def summary(self, name: str = "Ethernet") -> str:
        """Human-readable multi-line summary for a simulation log."""

        def number(value: float | None, fmt: str) -> str:
            return "n/a" if value is None else format(value, fmt)

        def describe(summary: Summary, unit: str) -> str:
            if summary.count == 0:
                return "n/a"
            return f"min={summary.minimum} max={summary.maximum} mean={number(summary.mean, '.1f')} {unit}"

        utilization = self.link_utilization
        payload_utilization = self.payload_utilization
        bit_rate = self.bit_rate_bps
        histogram = " ".join(f"{label}={count}" for label, count in self.size_histogram)
        return "\n".join(
            [
                f"{name} statistics",
                f"frames: total={self.total_frames} good={self.good_frames} bad={self.bad_frames}",
                f"octets: wire={self.wire_octets} frame={self.frame_octets} payload={self.payload_octets}",
                f"errors: fcs={self.fcs_errors} phy_frames={self.phy_error_frames} "
                f"phy_symbols={self.phy_error_symbols} idle={self.idle_errors} runt={self.runts} "
                f"giant={self.giants} preamble={self.preamble_errors} sfd={self.sfd_errors} "
                f"alignment={self.alignment_errors}",
                f"frame size: {describe(self.frame_size, 'octets')}",
                f"inter-frame gap: {describe(self.ifg_octets, 'octets')}",
                f"window: {self.duration_fs} fs, {number(self.frames_per_second, '.1f')} frames/s, "
                f"bit rate {number(None if bit_rate is None else bit_rate / 1e6, '.3f')} Mbit/s",
                f"utilization: link {number(None if utilization is None else 100 * utilization, '.2f')} %, "
                f"payload {number(None if payload_utilization is None else 100 * payload_utilization, '.2f')} %",
                f"size histogram: {histogram}",
            ]
        )


class PerformanceMonitor:
    """
    Accumulate traffic statistics from monitor events.

    A subscriber independent of the checker: :class:`~.monitor.EthernetMonitor`
    subscribes :meth:`on_frame` and :meth:`on_idle_event`.

    Args:
        link_rate_bps: The link rate utilization is computed against, 0 when unknown.
    """

    def __init__(self, link_rate_bps: int) -> None:
        self.link_rate_bps = link_rate_bps
        self.reset()

    def reset(self) -> None:
        """Forget everything observed so far."""
        self._total = self._good = 0
        self._wire = self._frame = self._payload = 0
        self._fcs = self._phy_frames = self._phy_symbols = self._idle = 0
        self._runts = self._giants = self._preamble = self._sfd = self._alignment = 0
        self._first: int | None = None
        self._last: int | None = None
        self._size = _Accumulator()
        self._ifg_octets = _Accumulator()
        self._ifg_fs = _Accumulator()
        self._histogram = [0] * len(SIZE_BUCKETS)

    def on_frame(self, frame: EthernetFrame) -> None:
        """Count a received frame."""
        self._total += 1
        self._good += frame.is_good
        if self._first is None:
            self._first = frame.timestamp_start_fs
        self._last = frame.timestamp_end_fs
        self._wire += len(frame.phy.octets)
        self._phy_symbols += len(frame.phy.error_offsets)
        self._phy_frames += bool(frame.phy.error_offsets)
        self._preamble += not frame.preamble_ok
        self._alignment += frame.phy.alignment_error
        if frame.ifg_octets is not None and frame.ifg_fs is not None:
            self._ifg_octets.add(frame.ifg_octets)
            self._ifg_fs.add(frame.ifg_fs)

        mac = frame.mac
        if mac is None:
            self._sfd += 1
            return
        size = mac.size_with_fcs
        self._frame += size
        self._payload += max(0, size - HEADER_OCTETS - FCS_OCTETS)
        self._fcs += mac.fcs_ok is False
        self._runts += frame.is_runt
        self._giants += frame.is_giant
        self._size.add(size)
        for bucket, (_, low, high) in enumerate(SIZE_BUCKETS):
            if size >= low and (high is None or size <= high):
                self._histogram[bucket] += 1
                break

    def on_idle_event(self, event: IdleEvent) -> None:
        """Count an error signal asserted between frames."""
        self._idle += event.error

    def snapshot(self) -> EthernetStatistics:
        """The statistics so far; later frames do not change the returned object."""
        return EthernetStatistics(
            total_frames=self._total,
            good_frames=self._good,
            bad_frames=self._total - self._good,
            wire_octets=self._wire,
            frame_octets=self._frame,
            payload_octets=self._payload,
            fcs_errors=self._fcs,
            phy_error_frames=self._phy_frames,
            phy_error_symbols=self._phy_symbols,
            idle_errors=self._idle,
            runts=self._runts,
            giants=self._giants,
            preamble_errors=self._preamble,
            sfd_errors=self._sfd,
            alignment_errors=self._alignment,
            first_timestamp_fs=self._first,
            last_timestamp_fs=self._last,
            link_rate_bps=self.link_rate_bps,
            frame_size=self._size.summary(),
            ifg_octets=self._ifg_octets.summary(),
            ifg_fs=self._ifg_fs.summary(),
            size_histogram=tuple(
                (label, count) for (label, _, _), count in zip(SIZE_BUCKETS, self._histogram, strict=True)
            ),
        )
