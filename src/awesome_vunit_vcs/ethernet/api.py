"""
The Ethernet happy path: one frame type, a monitor, decoding and capture.

Everything a test needs is importable from :mod:`awesome_vunit_vcs.ethernet`::

    from awesome_vunit_vcs import ethernet as eth

    frame = eth.Frame.from_payload(b"hello")
    result = eth.decode(eth.GMII, eth.GMII.encode([frame]))
    assert result.frames == (frame.padded(),)

The value types (:class:`Frame`, :class:`WireOptions`, :class:`Result`) are
immutable and hashable, construction is fully typed with keyword arguments,
invalid arguments raise :class:`~.errors.EthernetValueError`, and the
round-trips are pure functions, so property-based tests can generate the
arguments and assert the round-trips directly. The low-level pipeline behind
it is in :mod:`awesome_vunit_vcs.ethernet.lowlevel`.
"""

from __future__ import annotations

import os
from collections import deque
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field, replace
from typing import Any, Literal, SupportsBytes, get_args

from ..common.events import Publisher
from .checker import CheckId, Violation
from .errors import EthernetValueError
from .frame import SFD_OCTET, EthernetFrame, MacFrame, MonitorConfig, append_fcs
from .interfaces import GMII, Encodable, Interface, Samples
from .limits import LIMITS, Limits, Malformation
from .metrics import Statistics
from .monitor import EthernetMonitor
from .pcap import CaptureOptions, PcapNgWriter
from .phy.common import WireFrame
from .phy.xgmii import XGMII_ERROR
from .source import FcsMode, build_wire_frame

#: The destination address :meth:`Frame.from_payload` uses by default (locally administered)
DEFAULT_DESTINATION = "02:00:00:00:00:01"
#: The source address :meth:`Frame.from_payload` uses by default (locally administered)
DEFAULT_SOURCE = "02:00:00:00:00:02"
#: The EtherType :meth:`Frame.from_payload` uses by default: local experimental EtherType 1
DEFAULT_ETHERTYPE = 0x88B5

#: How :class:`WireOptions` ends a frame, see :attr:`WireOptions.fcs`
FcsKind = Literal["auto", "append", "bad", "none"]


def mac_address(value: str | bytes) -> bytes:
    """
    The six octets of a MAC address.

    Args:
        value: ``"02:00:00:00:00:01"`` (``:`` or ``-`` separated hex) or six octets.

    Raises:
        EthernetValueError: The value is not a MAC address.
    """
    if isinstance(value, bytes | bytearray):
        if len(value) != LIMITS.mac_address_octets:
            raise EthernetValueError(f"A MAC address is 6 octets, got {len(value)}")
        return bytes(value)
    parts = value.replace("-", ":").split(":")
    try:
        octets = bytes(int(part, 16) for part in parts if len(part) == 2)
    except ValueError:
        octets = b""
    if len(parts) != LIMITS.mac_address_octets or len(octets) != LIMITS.mac_address_octets:
        raise EthernetValueError(f"{value!r} is not a MAC address such as '02:00:00:00:00:01'")
    return octets


def _format_mac(octets: bytes | None) -> str | None:
    return None if octets is None else ":".join(f"{octet:02x}" for octet in octets)


@dataclass(slots=True, frozen=True)
class WireOptions:
    """
    How a source puts a frame on the wire, including deliberate errors.

    Malformed traffic is described by these values, so a test can generate it
    and compute the violations a monitor must report with
    :func:`expected_violations`. :meth:`malformed` builds the options of
    :class:`~.limits.Malformation` kinds.

    Raises:
        EthernetValueError: A value is out of range.
    """

    #: ``"auto"`` appends the correct FCS, or sends a frame whose FCS is
    #: already wrong as it is; ``"append"`` always appends the correct FCS,
    #: ``"bad"`` an inverted one, and ``"none"`` sends the frame without FCS
    fcs: FcsKind = "auto"
    #: Pad frames shorter than :attr:`min_frame_octets` with zeros before the FCS
    pad: bool = True
    #: Preamble octets (0x55) before the SFD
    preamble_octets: int = 7
    #: The octet sent as the SFD
    sfd: int = SFD_OCTET
    #: Idle octets after the frame
    ifg_octets: int = 12
    #: Octets sent with the error signal, counted from the first octet after
    #: the SFD; negative offsets reach into the SFD (-1) and the preamble
    errors: tuple[int, ...] = ()
    #: The minimum frame size, including the FCS, that padding makes up
    min_frame_octets: int = 64

    def __post_init__(self) -> None:
        if self.fcs not in get_args(FcsKind):
            raise EthernetValueError(f"fcs must be one of {get_args(FcsKind)}, got {self.fcs!r}")
        if self.preamble_octets < 0:
            raise EthernetValueError(f"preamble_octets must not be negative, got {self.preamble_octets}")
        if not 0 <= self.sfd <= 0xFF:
            raise EthernetValueError(f"sfd must be an octet, got {self.sfd}")
        if self.ifg_octets < 0:
            raise EthernetValueError(f"ifg_octets must not be negative, got {self.ifg_octets}")
        if self.min_frame_octets < 0:
            raise EthernetValueError(f"min_frame_octets must not be negative, got {self.min_frame_octets}")
        object.__setattr__(self, "errors", tuple(int(offset) for offset in self.errors))

    @classmethod
    def malformed(cls, *kinds: Malformation, limits: Limits = LIMITS) -> WireOptions:
        """
        The options that produce malformations on the wire.

        :attr:`~.limits.Malformation.RUNT` sends without padding, which makes a
        frame shorter than the minimum a runt. :attr:`~.limits.Malformation.GIANT`
        is a property of the frame, not of the wire: build a frame longer than
        ``limits.max_frame_octets`` instead.

        Args:
            kinds: The malformations to combine.
            limits: The limits the malformations violate.

        Raises:
            EthernetValueError: A kind that options cannot produce (GIANT).
        """
        options = cls(min_frame_octets=limits.min_frame_octets)
        for kind in kinds:
            if kind is Malformation.BAD_FCS:
                options = replace(options, fcs="bad")
            elif kind is Malformation.SHORT_PREAMBLE:
                options = replace(options, preamble_octets=limits.preamble_octets - 2)
            elif kind is Malformation.LONG_PREAMBLE:
                options = replace(options, preamble_octets=limits.preamble_octets + 2)
            elif kind is Malformation.BAD_SFD:
                options = replace(options, sfd=limits.sfd ^ 0x01)
            elif kind is Malformation.RUNT:
                options = replace(options, pad=False)
            elif kind is Malformation.PHY_ERROR:
                options = replace(options, errors=(0,))
            elif kind is Malformation.SHORT_IFG:
                options = replace(options, ifg_octets=limits.min_xgmii_ifg_octets - 1)
            else:
                raise EthernetValueError(f"{kind.value} is a property of the frame, not of the wire options")
        return options


@dataclass(slots=True, frozen=True)
class Frame:
    """
    An Ethernet frame: the octets from the destination address up to and including the FCS.

    The only frame type a test builds or receives. Build one with
    :meth:`from_payload`, :meth:`from_bytes` or :meth:`from_packet`; monitors
    return received frames, which also carry the time, the error offsets and
    the violations found on them. Equality and hashing consider the frame
    content only (``octets``, ``has_fcs``, ``error_offsets``), so a received
    frame equals the frame that was sent.

    Raises:
        EthernetValueError: The octets are not bytes.
    """

    #: Destination address up to and including the FCS (without FCS when ``has_fcs`` is false)
    octets: bytes
    #: Whether :attr:`octets` ends with an FCS
    has_fcs: bool = True
    #: Octets received with the error signal, counted from the first octet after the SFD
    error_offsets: tuple[int, ...] = ()
    #: The violations a monitor found on this frame
    violations: tuple[Violation, ...] = field(default=(), compare=False)
    #: Time of the SFD in fs (of the first octet without SFD), None for a frame that was not received
    timestamp_fs: int | None = field(default=None, compare=False)
    #: Position in the order the monitor received frames, from 0
    index: int | None = field(default=None, compare=False)
    #: The full analysis of a received frame, see :class:`~awesome_vunit_vcs.ethernet.lowlevel.EthernetFrame`
    received: EthernetFrame | None = field(default=None, compare=False, repr=False)

    def __post_init__(self) -> None:
        if isinstance(self.octets, bytearray | memoryview):
            object.__setattr__(self, "octets", bytes(self.octets))
        if not isinstance(self.octets, bytes):
            raise EthernetValueError(f"Frame octets are bytes, got {type(self.octets).__name__}")
        object.__setattr__(self, "error_offsets", tuple(int(offset) for offset in self.error_offsets))

    @classmethod
    def from_payload(
        cls,
        payload: bytes,
        *,
        dst: str | bytes = DEFAULT_DESTINATION,
        src: str | bytes = DEFAULT_SOURCE,
        ethertype: int = DEFAULT_ETHERTYPE,
    ) -> Frame:
        """
        A frame with a header, a payload and the correct FCS. It is not padded; :meth:`to_wire` pads it.

        Args:
            payload: The octets after the header.
            dst: The destination address.
            src: The source address.
            ethertype: The EtherType, or the payload length for values up to 1500.

        Raises:
            EthernetValueError: An invalid address or EtherType.
        """
        if not 0 <= ethertype <= LIMITS.max_ethertype:
            raise EthernetValueError(f"ethertype must be 0..0xFFFF, got {ethertype}")
        data = mac_address(dst) + mac_address(src) + ethertype.to_bytes(2, "big") + bytes(payload)
        return cls(append_fcs(data))

    @classmethod
    def from_bytes(cls, octets: bytes, *, has_fcs: bool = True) -> Frame:
        """
        A frame from its octets.

        Args:
            octets: Destination address up to the FCS.
            has_fcs: Whether ``octets`` end with an FCS. Without, the correct FCS is appended.
        """
        return cls(bytes(octets)) if has_fcs else cls(append_fcs(bytes(octets)))

    @classmethod
    def from_packet(cls, packet: SupportsBytes) -> Frame:
        """A frame from a Scapy packet, or anything ``bytes()`` accepts, without FCS; the FCS is appended."""
        return cls.from_bytes(bytes(packet), has_fcs=False)

    @classmethod
    def from_received(cls, frame: EthernetFrame, violations: Iterable[Violation] = ()) -> Frame:
        """
        The frame of a low-level :class:`~awesome_vunit_vcs.ethernet.lowlevel.EthernetFrame` analysis.

        Args:
            frame: A frame a low-level monitor published.
            violations: The violations found on it.
        """
        mac = frame.mac
        sfd = frame.timestamp_sfd_fs
        return cls(
            octets=b"" if mac is None else mac.data,
            has_fcs=True if mac is None else mac.has_fcs,
            error_offsets=frame.error_offsets,
            violations=tuple(violations),
            timestamp_fs=frame.timestamp_start_fs if sfd is None else sfd,
            index=frame.index,
            received=frame,
        )

    @property
    def _mac(self) -> MacFrame:
        return MacFrame(self.octets, self.has_fcs)

    @property
    def data(self) -> bytes:
        """Destination address up to, not including, the FCS: what a MAC client sends and a scoreboard compares."""
        return self._mac.mac_octets

    @property
    def payload(self) -> bytes:
        """The octets after the 14-octet header, without FCS, with padding removed when the type field is a length."""
        return self._mac.client_data

    @property
    def fcs(self) -> int | None:
        """The FCS field, None without FCS."""
        return self._mac.fcs_received

    @property
    def fcs_ok(self) -> bool | None:
        """Whether the FCS is correct, None without FCS."""
        return self._mac.fcs_ok

    @property
    def dst(self) -> str | None:
        """The destination address as ``"02:00:00:00:00:01"``, None for a frame shorter than it."""
        return _format_mac(self._mac.destination)

    @property
    def src(self) -> str | None:
        """The source address, None for a frame shorter than it."""
        return _format_mac(self._mac.source)

    @property
    def ethertype(self) -> int | None:
        """The EtherType or length field, None for a frame shorter than the header."""
        return self._mac.ethertype

    @property
    def size(self) -> int:
        """Frame size in octets including the FCS, as IEEE 802.3 counts it."""
        return self._mac.size_with_fcs

    @property
    def ok(self) -> bool:
        """Whether nothing is wrong with the frame: a correct FCS, and for a received frame no violation."""
        received_ok = self.received is None or self.received.is_good
        return self.fcs_ok is not False and not self.violations and received_ok

    def to_wire(self, options: WireOptions | None = None) -> WireFrame:
        """
        What a source puts on the wire for the frame.

        Args:
            options: Padding, FCS, preamble, SFD, errors and gap; the default is a valid frame.

        Raises:
            EthernetValueError: An error offset is outside the frame.
        """
        options = options or WireOptions()
        if options.fcs == "auto":
            keep = self.has_fcs and self.fcs_ok is False
            mode, data = (FcsMode.NONE, self.octets) if keep else (FcsMode.APPEND, self.data)
        elif options.fcs == "none":
            mode, data = FcsMode.NONE, self.data
        else:
            mode, data = FcsMode(options.fcs), self.data
        return build_wire_frame(
            data,
            fcs=mode,
            pad=options.pad,
            min_frame_octets=options.min_frame_octets,
            preamble_octets=options.preamble_octets,
            sfd=options.sfd,
            ifg_octets=options.ifg_octets,
            error_offsets=options.errors,
        )

    def padded(self, min_frame_octets: int = LIMITS.min_frame_octets) -> Frame:
        """
        The frame a monitor receives when it is sent with default :class:`WireOptions`: padded, with its FCS.

        This is the round-trip a property test asserts:
        ``decode(i, i.encode([frame])).frames == (frame.padded(),)``.
        """
        wire = self.to_wire(WireOptions(min_frame_octets=min_frame_octets))
        return Frame(wire.octets[wire.mac_offset :])

    def __bytes__(self) -> bytes:
        """The frame without FCS, :attr:`data`, so ``bytes(frame)`` works wherever packets are accepted."""
        return self.data

    def to_scapy(self) -> Any:
        """The frame without FCS as a Scapy ``Ether`` packet (needs the scapy extra)."""
        from .scapy_adapter import to_scapy

        return to_scapy(self.data)


@dataclass(slots=True, frozen=True)
class Result:
    """What :func:`decode` found."""

    #: The frames received, in order
    frames: tuple[Frame, ...]
    #: Every violation, in order
    violations: tuple[Violation, ...]
    #: The traffic statistics
    statistics: Statistics

    @property
    def ok(self) -> bool:
        """Whether no check found a violation."""
        return not self.violations

    @property
    def checks(self) -> frozenset[CheckId]:
        """The checks that found violations."""
        return frozenset(violation.check for violation in self.violations)


def _default_config(interface: Interface) -> MonitorConfig:
    return MonitorConfig(min_ifg_octets=interface.min_ifg_octets)


class Monitor:
    """
    Reconstruct and check the frames of an interface, without a simulator.

    The pipeline of a VHDL monitor. Feed it :class:`~.interfaces.Samples` or
    frames; it returns :class:`Frame` objects, collects violations and keeps
    statistics. Use it as a context manager, so the frame still in progress is
    reported and captures are closed at the end.

    Args:
        interface: The interface, for example ``GMII`` or ``XGMII(lanes=8, rate="100G")``.
        config: What a well-formed frame is; the default is IEEE 802.3 with the
            minimum inter-frame gap of the interface.
        checks: True enables every check, False none, or the names of the
            checks to enable, such as ``["ETH_FCS"]``.
        name: Used in messages and as the capture interface name.
        keep_frames: Keep only the most recent frames; None keeps every frame.
    """

    def __init__(
        self,
        interface: Interface,
        config: MonitorConfig | None = None,
        *,
        checks: bool | Iterable[str | CheckId] = True,
        name: str = "rx",
        keep_frames: int | None = None,
    ) -> None:
        self.interface = interface
        self.config = config or _default_config(interface)
        self.name = name
        #: The low-level :class:`~awesome_vunit_vcs.ethernet.lowlevel.EthernetMonitor`
        self.engine = EthernetMonitor(interface.phy(), self.config, name=name, keep_frames=1)
        self._frames: list[Frame] | deque[Frame] = [] if keep_frames is None else deque(maxlen=keep_frames)
        self._violations: list[Violation] = []
        self._pending: list[Violation] = []
        self._frame_events: Publisher[Frame] = Publisher()
        self._encoder = interface.phy()
        self._next_fs = 0
        self._fed = False
        self._finished = False
        if checks is not True:
            self.engine.checker.disable(*CheckId)
            if checks is not False:
                self.engine.checker.enable(*checks)
        self.engine.checker.violations.subscribe(self._on_violation)
        self.engine.frames.subscribe(self._on_frame)

    def _on_violation(self, violation: Violation) -> None:
        self._violations.append(violation)
        self._pending.append(violation)

    def _on_frame(self, received: EthernetFrame) -> None:
        own = [violation for violation in self._pending if violation.frame_index == received.index]
        self._pending.clear()
        frame = Frame.from_received(received, own)
        self._frames.append(frame)
        self._frame_events.publish(frame)

    @property
    def frames(self) -> Sequence[Frame]:
        """The frames received, oldest first."""
        return self._frames

    @property
    def violations(self) -> Sequence[Violation]:
        """Every violation, in order."""
        return self._violations

    @property
    def statistics(self) -> Statistics:
        """A snapshot of the statistics so far."""
        return self.engine.statistics.snapshot()

    def feed(self, samples: Samples) -> list[Frame]:
        """
        Process samples.

        Args:
            samples: Sample words and times, continuing the samples fed before.

        Returns:
            The frames completed by these samples. A frame still in progress
            continues in the next call.
        """
        before = self.engine.frame_count
        self.engine.feed(samples.words, samples.times)
        if len(samples):
            self._fed = True
            self._next_fs = int(samples.times[-1]) + self.interface.clock_period_fs
        completed = self.engine.frame_count - before
        return list(self._frames)[-completed:] if completed else []

    def feed_frames(self, frames: Iterable[Encodable], *, idle_clocks: int | None = None) -> list[Frame]:
        """
        Encode frames for the interface and process them, continuing the time of the samples fed before.

        Args:
            frames: :class:`Frame` objects, wire frames, or frame octets without FCS.
            idle_clocks: Idle clock edges before the frames; by default 12 before
                the first samples of the monitor and none after.

        Returns:
            The frames completed.
        """
        clocks = (0 if self._fed else 12) if idle_clocks is None else idle_clocks
        samples = self.interface.encode_with(self._encoder, frames, idle_clocks=clocks, start_fs=self._next_fs)
        return self.feed(samples)

    def enable(self, *checks: str | CheckId) -> None:
        """Enable checks by name, such as ``"ETH_IFG"``."""
        self.engine.checker.enable(*checks)

    def disable(self, *checks: str | CheckId) -> None:
        """Disable checks by name; a disabled check neither reports nor counts."""
        self.engine.checker.disable(*checks)

    def count(self, check: str | CheckId) -> int:
        """Violations a check found while it was enabled."""
        return self.engine.checker.count(check)

    def on_frame(self, subscriber: Callable[[Frame], None]) -> Callable[[Frame], None]:
        """Call ``subscriber`` with every frame received from now on; usable as a decorator."""
        self._frame_events.subscribe(subscriber)
        return subscriber

    def on_violation(self, subscriber: Callable[[Violation], None]) -> Callable[[Violation], None]:
        """Call ``subscriber`` with every violation from now on; usable as a decorator."""
        self.engine.checker.violations.subscribe(subscriber)
        return subscriber

    def capture(
        self,
        path: str | os.PathLike[str],
        *,
        fcs: bool = True,
        errored: bool = True,
        timestamp_resolution_exponent: int = 9,
    ) -> PcapNgWriter:
        """
        Write the frames received from now on to a PCAPNG file, closed by :meth:`finish`.

        Args:
            path: The file to create.
            fcs: Write the FCS of every frame.
            errored: Write frames that failed a check, flagged with their errors.
            timestamp_resolution_exponent: Timestamps in 10**-exponent seconds, 9 for ns, up to 15 for fs.
        """
        options = CaptureOptions(
            include_fcs=fcs,
            include_errored=errored,
            timestamp_resolution_exponent=timestamp_resolution_exponent,
            min_ifg_octets=self.config.min_ifg_octets,
        )
        return self.engine.start_capture(path, options)

    def finish(self) -> None:
        """Report a frame still in progress and close captures; later calls do nothing."""
        if self._finished:
            return
        self._finished = True
        self.engine.finish(self._next_fs)
        self.engine.stop_captures()

    def __enter__(self) -> Monitor:
        return self

    def __exit__(self, *_: object) -> None:
        self.finish()


def decode(
    interface: Interface,
    samples: Samples,
    config: MonitorConfig | None = None,
    *,
    checks: bool | Iterable[str | CheckId] = True,
) -> Result:
    """
    Decode and check recorded samples in one call.

    Args:
        interface: The interface the samples were recorded on.
        samples: The samples, such as ``interface.encode(frames)``.
        config: What a well-formed frame is, see :class:`Monitor`.
        checks: The checks to run, see :class:`Monitor`.

    Returns:
        The frames, the violations and the statistics; a frame still in
        progress at the end is reported as a violation.
    """
    with Monitor(interface, config, checks=checks) as monitor:
        monitor.feed(samples)
    return Result(tuple(monitor.frames), tuple(monitor.violations), monitor.statistics)


def write_pcapng(
    path: str | os.PathLike[str],
    frames: Iterable[Frame | bytes],
    *,
    interface: Interface = GMII,
    fcs: bool = True,
    errored: bool = True,
) -> int:
    """
    Write frames to a PCAPNG file Wireshark reads.

    Received frames keep their timestamps and error flags. Frames that were not
    received (built frames, or octets without FCS) are timed as if sent back to
    back on ``interface``.

    Args:
        path: The file to create.
        frames: Frames, or frame octets without FCS.
        interface: The interface built frames are timed on.
        fcs: Write the FCS of every frame.
        errored: Write frames with errors.

    Returns:
        The number of frames written.
    """
    items = list(frames)
    received = [item.received for item in items if isinstance(item, Frame) and item.received is not None]
    if received and len(received) == len(items):
        options = CaptureOptions(include_fcs=fcs, include_errored=errored)
        with PcapNgWriter(path, options, link_rate_bps=interface.link_rate_bps) as writer:
            for analysis in received:
                writer.on_frame(analysis)
        return writer.frames_written
    with Monitor(interface, checks=False) as monitor:
        writer = monitor.capture(path, fcs=fcs, errored=errored)
        monitor.feed_frames(items)
    return writer.frames_written


def supported_malformations(interface: Interface) -> frozenset[Malformation]:
    """
    The malformations whose violations :func:`expected_violations` predicts exactly on an interface.

    MII realigns nibbles on the SFD, so a wrong SFD may be found elsewhere; the
    XGMII family rounds gaps to whole columns, so a short gap is not exact.
    """
    unsupported = {"mii": {Malformation.BAD_SFD}, "xgmii": {Malformation.SHORT_IFG}}.get(interface.name, set())
    return frozenset(Malformation) - unsupported


def expected_violations(
    frame: Frame,
    options: WireOptions | None = None,
    config: MonitorConfig | None = None,
    *,
    interface: Interface = GMII,
    previous: WireOptions | None = None,
) -> frozenset[CheckId]:
    """
    The checks a monitor reports for a frame sent with options: the oracle of a property test.

    Args:
        frame: The frame sent.
        options: How it was sent, see :class:`WireOptions`.
        config: The monitor configuration; the default of :class:`Monitor`.
        interface: The interface it was sent on.
        previous: The options of the frame sent before it, whose gap precedes this frame.

    Returns:
        The checks that report the frame (the gap before it included).

    Raises:
        EthernetValueError: The options make the outcome depend on decoder
            details that are not predicted (see :func:`supported_malformations`).
    """
    options = options or WireOptions()
    config = config or _default_config(interface)
    wire = frame.to_wire(options)
    octets = wire.octets
    if interface.name == "xgmii" and wire.wire_error_offsets:
        # The Error control character replaces the octet on the lane: it is received as 0xFE
        received = bytearray(octets)
        for offset in wire.wire_error_offsets:
            received[offset] = XGMII_ERROR
        octets = bytes(received)
    if options.ifg_octets == 0 or (previous is not None and previous.ifg_octets == 0):
        raise EthernetValueError("Without a gap two frames are received as one; its violations are not predicted")
    if options.sfd == 0x55:
        raise EthernetValueError("An SFD of 0x55 extends the preamble; its violations are not predicted")
    if interface.name == "mii" and options.sfd != SFD_OCTET:
        raise EthernetValueError("MII realigns nibbles on the SFD; a wrong SFD is not predicted")
    if interface.name == "xgmii" and (options.preamble_octets == 0 or 0 in wire.wire_error_offsets):
        raise EthernetValueError("On XGMII Start replaces the first preamble octet, which must be an ordinary one")
    if interface.name == "mii" and options.preamble_octets > LIMITS.max_preamble_octets:
        raise EthernetValueError(f"MII preambles longer than {LIMITS.max_preamble_octets} octets are not predicted")

    found: set[CheckId] = set()
    if previous is not None:
        if interface.name == "xgmii" and previous.ifg_octets < config.min_ifg_octets + interface.lanes - 1:
            raise EthernetValueError("The XGMII family rounds gaps to columns; this gap is not predicted")
        if previous.ifg_octets < config.min_ifg_octets:
            found.add(CheckId.IFG)
    preamble = len(octets) - len(octets.lstrip(b"\x55"))
    if not config.min_preamble_octets <= preamble <= config.max_preamble_octets:
        found.add(CheckId.PREAMBLE)
    if preamble >= len(octets) or octets[preamble] != SFD_OCTET:
        found.add(CheckId.SFD)
        return frozenset(found)
    mac = MacFrame(octets[preamble + 1 :], config.has_fcs)
    if mac.fcs_ok is False:
        found.add(CheckId.FCS)
    if mac.size_with_fcs < config.min_frame_octets:
        found.add(CheckId.RUNT)
    if mac.size_with_fcs > config.max_frame_octets:
        found.add(CheckId.GIANT)
    if wire.wire_error_offsets:
        found.add(CheckId.PHY_ERROR)
    return frozenset(found)
