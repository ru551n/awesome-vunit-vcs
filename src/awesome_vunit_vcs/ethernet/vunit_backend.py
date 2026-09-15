"""
Backends of the Ethernet VHDL verification components.

Each VC instance creates one backend object in its own Python session (the
session has the identity of the VC, so instances never share state). VHDL
calls these methods; nothing here touches simulator signals. Everything a
VHDL user needs is reachable through the VHDL API; Python users can reach the
backend object as ``vc`` in the session of the VC.
"""

from __future__ import annotations

import itertools
import os
import traceback
from collections import Counter, deque
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import replace
from typing import Any

import numpy as np
import numpy.typing as npt

from ..common.reports import ReportQueue, Severity, encode_reports
from ..common.vunit_bridge import bytes_from_unsigned, decode_samples, decode_text, decode_time_fs
from . import traffic
from .api import Frame, WireOptions, decode, expected_violations
from .checker import CheckId, Violation
from .frame import FCS_OCTETS, EthernetConfig, EthernetFrame
from .interfaces import Interface
from .metrics import EthernetStatistics
from .monitor import EthernetMonitor
from .pcap import CaptureOptions
from .phy import XgmiiPhy, create_phy
from .source import EthernetSource, build_wire_frame

#: Largest value a VHDL integer holds; statistics saturate at it
VHDL_INTEGER_MAX = 2**31 - 1

#: Order of the values returned by :meth:`MonitorBackend.statistics_values`,
#: mirrored by the ``ethernet_statistics_t`` record in ethernet_pkg.vhd
STATISTICS_FIELDS = (
    "total_frames",
    "good_frames",
    "bad_frames",
    "wire_octets",
    "payload_octets",
    "fcs_errors",
    "phy_error_frames",
    "runts",
    "giants",
    "min_frame_octets",
    "max_frame_octets",
    "min_ifg_octets",
    "max_ifg_octets",
)


def _exception_summary(exc: BaseException) -> str:
    frames = traceback.extract_tb(exc.__traceback__)
    where = f" ({frames[-1].filename}:{frames[-1].lineno})" if frames else ""
    return f"{type(exc).__name__}: {exc}{where}"


def _phy_options(phy_options: dict[str, Any] | None, link_rate_bps: int, **options: Any) -> dict[str, Any]:
    """The options of a PHY: those given, the link rate unless 0, and the other options unless None."""
    result = dict(phy_options or {})
    if link_rate_bps:
        result["link_rate_bps"] = link_rate_bps
    result.update({key: value for key, value in options.items() if value is not None})
    return result


def _interface(name: str, phy_options: dict[str, Any]) -> Interface:
    """The :class:`~.interfaces.Interface` of a backend, from its interface name and PHY options."""
    fields = (
        "link_rate_bps",
        "lanes",
        "allow_lane4_start",
        "deficit_idle",
        "has_fcs",
        "valid_low_percent",
        "ready_low_percent",
        "seed",
        "crs_dv_toggle_octets",
    )
    return replace(traffic.interface_named(name), **{key: phy_options[key] for key in fields if key in phy_options})


def _saturate(value: int | None) -> int:
    """A statistic as a VHDL integer: -1 when there is no value."""
    return -1 if value is None else min(value, VHDL_INTEGER_MAX)


#: The checks a VHDL monitor runs itself; a protocol checker runs the others
_MONITOR_CHECKS = frozenset({CheckId.SCOREBOARD, CheckId.USER})


class MonitorBackend:
    """
    The Python object behind a VHDL monitor, ``vc`` in the session of the monitor.

    The VHDL monitor creates it with the options of its constructor and calls
    its methods with typed arguments; a testbench can call them too. Violations and
    subscriber exceptions are queued as reports that the VHDL monitor logs, so
    no method raises into VHDL.

    Args:
        name: The name of the monitor, used in messages.
        interface: The PHY interface name, see :func:`~.phy.create_phy`.
        link_rate_bps: The link rate, 0 for the default of the interface.
        link_rate_mbps: The link rate in Mbit/s as VHDL gives it, used when
            ``link_rate_bps`` is 0.
        keep_frames: How many recent frames the monitor keeps.
        log_frames: Log every frame at debug level.
        phy_options: Further options of the PHY decoder, such as XGMII lanes.
        lanes: The lanes of an XGMII interface, added to ``phy_options``.
        allow_lane4_start: Accept Start on lane 4 of an 8-lane XGMII interface,
            added to ``phy_options``.
        checks: Run the protocol checks. A VHDL monitor runs without them, its
            protocol checker (:class:`ProtocolCheckerBackend`) runs them; the
            scoreboard check stays enabled either way.

    The other arguments are those of :class:`~.frame.EthernetConfig`.

    Attributes:
        monitor: The :class:`~.monitor.EthernetMonitor`; subscribe to its
            ``frames`` to extend the monitor from Python.
    """

    def __init__(
        self,
        name: str,
        interface: str,
        *,
        min_preamble_octets: int = 7,
        max_preamble_octets: int = 7,
        min_frame_octets: int = 64,
        max_frame_octets: int = 1518,
        min_ifg_octets: int = 12,
        has_fcs: bool = True,
        link_rate_bps: int = 0,
        link_rate_mbps: int = 0,
        keep_frames: int = 256,
        log_frames: bool = False,
        phy_options: dict[str, Any] | None = None,
        lanes: int | None = None,
        allow_lane4_start: bool | None = None,
        checks: bool = True,
    ) -> None:
        self.name = name
        self.reports = ReportQueue()
        self.log_frames = log_frames
        phy_options = _phy_options(
            phy_options, link_rate_bps or link_rate_mbps * 1_000_000, lanes=lanes, allow_lane4_start=allow_lane4_start
        )
        self._interface = interface
        self._phy_options = phy_options
        config = EthernetConfig(
            min_preamble_octets=min_preamble_octets,
            max_preamble_octets=max_preamble_octets,
            min_frame_octets=min_frame_octets,
            max_frame_octets=max_frame_octets,
            min_ifg_octets=min_ifg_octets,
            has_fcs=has_fcs,
            has_preamble=interface.lower() != "axis",
        )
        self.monitor = EthernetMonitor(
            create_phy(interface, **phy_options),
            config,
            name=name,
            keep_frames=keep_frames,
            on_subscriber_error=self._subscriber_error,
        )
        # After the monitor, so an unknown interface reports the error of create_phy
        self._interface_value = _interface(interface, {**phy_options, "has_fcs": has_fcs})
        self._expected_violations: Counter[CheckId] = Counter()
        self.monitor.checker.violations.subscribe(self._violation)
        self.monitor.frames.subscribe(self._frame_logger)
        self.monitor.frames.subscribe(self._compare_with_expected)
        self.monitor.frames.subscribe(self._collect)
        if not checks:
            self.monitor.checker.disable(*(check for check in CheckId if check not in _MONITOR_CHECKS))
        #: Collect received frames for :meth:`take_frames`; VHDL sets it with
        #: :meth:`set_collect_frames` while the monitor has subscribers or pending pops
        self.collect_frames = False
        self._arguments: tuple[tuple[Any, ...], dict[str, Any]] = ((), {})
        self._collected: list[EthernetFrame] = []
        self._expected: deque[tuple[bytes, str]] = deque()
        self._queued_count = 0
        self._compared_count = 0
        self._last_time_fs = 0

    # Events -> reports
    def _violation(self, violation: Violation) -> None:
        self.reports.add(Severity.ERROR, violation.message)

    def _subscriber_error(self, subscriber: Callable[..., None], exc: BaseException) -> None:
        name = getattr(subscriber, "__qualname__", repr(subscriber))
        self.reports.add(Severity.FAILURE, f"Subscriber {name} of {self.name} raised {_exception_summary(exc)}")

    def _frame_logger(self, frame: EthernetFrame) -> None:
        if not self.log_frames:
            return
        mac = frame.mac
        if mac is None:
            text = f"frame {frame.index}: {len(frame.phy.octets)} wire octets without SFD"
        else:
            destination = ":".join(f"{octet:02x}" for octet in (mac.destination or b""))
            text = (
                f"frame {frame.index}: {mac.size_with_fcs} octets, dst={destination}, "
                f"fcs_ok={mac.fcs_ok}, SFD time={frame.timestamp_sfd_fs} fs"
            )
        self.reports.add(Severity.DEBUG, text)

    def _padded(self, data: bytes) -> bytes:
        """data padded with zeros to the minimum frame size, the way a transmitter pads it"""
        config = self.monitor.config
        minimum = config.min_frame_octets - (FCS_OCTETS if config.has_fcs else 0)
        return data + bytes(max(0, minimum - len(data)))

    def _compare_with_expected(self, frame: EthernetFrame) -> None:
        # Octets without an SFD are not a frame to compare; the protocol checker reports them
        if not self._expected or frame.mac is None:
            return
        expected, message = self._expected.popleft()
        self._compared_count += 1
        received = frame.mac_octets
        if received in (expected, self._padded(expected)):
            return
        mismatch = next(
            (offset for offset, (a, b) in enumerate(zip(expected, received, strict=False)) if a != b),
            min(len(expected), len(received)),
        )
        self.monitor.checker.report(
            CheckId.SCOREBOARD,
            f"{message}{': ' if message else ''}frame {frame.index} is not the expected frame",
            [
                f"expected length={len(expected)} octets",
                f"received length={len(received)} octets",
                f"first difference at offset {mismatch}",
                f"SFD time={frame.timestamp_sfd_fs} fs",
            ],
            frame.timestamp_start_fs,
            frame.index,
        )

    # Called by VHDL
    def push(self, samples: Any, base_time: int | Sequence[int], delta_unit: int | Sequence[int] = 1) -> int:
        """
        Process a sample batch. Returns the number of reports waiting to be fetched.

        Args:
            samples: The ``[word, delta]`` pairs, see :mod:`~awesome_vunit_vcs.common.vunit_bridge`.
            base_time: The time of the first sample, see :func:`~.vunit_bridge.decode_time_fs`.
            delta_unit: The unit of the deltas, likewise.
        """
        try:
            words, times = decode_samples(samples, decode_time_fs(base_time), decode_time_fs(delta_unit))
            if times.size:
                self._last_time_fs = int(times[-1])
            self.monitor.feed(words, times)
        except Exception as exc:
            self.reports.add(Severity.FAILURE, f"{self.name} could not process samples: {_exception_summary(exc)}")
        return len(self.reports)

    def take_reports(self) -> str:
        """The waiting reports, encoded for VHDL."""
        return encode_reports(self.reports.take())

    def set_check_enabled(self, check: str, enabled: bool) -> None:
        """Enable or disable a check given by name."""
        if enabled:
            self.monitor.checker.enable(check)
        else:
            self.monitor.checker.disable(check)

    def check_count(self, check: str) -> int:
        """Violations of a check given by name."""
        return self.monitor.checker.count(CheckId.parse(check))

    def frame_count(self) -> int:
        """Frames received, good or bad."""
        return self.monitor.frame_count

    def good_frame_count(self) -> int:
        """Frames received without errors."""
        return self.statistics().good_frames

    def expect_mac_octets(self, data: Sequence[int]) -> None:
        """Queue the frame (destination address up to the FCS) the next received frame must equal."""
        self.check_mac_octets(data)

    def set_collect_frames(self, enabled: bool) -> None:
        """Collect received frames for :meth:`take_frames` or not."""
        self.collect_frames = enabled

    def set_arguments(self, *args: Any, **kwargs: Any) -> None:
        """
        The arguments of the function the next :meth:`check_sequence`,
        :meth:`SourceBackend.function_symbols` or :meth:`SourceBackend.start_sequence`
        calls. VHDL gives them in a call of their own, so they never collide
        with the arguments of the backend method.
        """
        self._arguments = (args, kwargs)

    def _take_arguments(
        self, args: Sequence[Any] | None, kwargs: Mapping[str, Any] | None
    ) -> tuple[tuple[Any, ...], dict[str, Any]]:
        pending, self._arguments = self._arguments, ((), {})
        if args is None and kwargs is None:
            return pending
        return tuple(args or ()), dict(kwargs or {})

    def check_mac_octets(self, data: Sequence[int], message: str | Sequence[int] = "") -> int:
        """
        Like :meth:`expect_mac_octets`, with a message prefixing a difference.

        Returns:
            The number of frames expected so far, this one included, which
            :meth:`compared_count` reaches when this frame is compared.
        """
        self._expected.append((bytes(data), decode_text(message)))
        self._queued_count += 1
        return self._queued_count

    def check_sequence(
        self,
        function: str,
        count: int = 0,
        seed: str | Sequence[int] = "",
        *,
        args: Sequence[Any] | None = None,
        kwargs: Mapping[str, Any] | None = None,
    ) -> int:
        """
        Expect the traffic a generator yields, see :func:`~.traffic.sequence`: ``count`` items, or all when 0.

        Each item is expected as the monitor receives it, with its wire options
        (bad FCS, preamble, SFD, errors, gap) applied; an item without a valid
        SFD is not received as a frame and is not expected. The violations a
        protocol checker must report for the items, by
        :func:`~.api.expected_violations`, are added to
        :meth:`expected_violation_count`. Returns like :meth:`check_mac_octets`.

        The function gets ``args`` and ``kwargs``, or else the arguments given
        to :meth:`set_arguments`.
        """
        call_args, call_kwargs = self._take_arguments(args, kwargs)
        seed = decode_text(seed)
        try:
            previous: WireOptions | None = None
            items = traffic.sequence(function, *call_args, seed=seed or None, **call_kwargs)
            for item in itertools.islice(items, count or None):
                self._expect_item(item, previous)
                previous = item.options
        except Exception as exc:
            self.reports.add(
                Severity.FAILURE, f"{self.name} could not check the sequence {function!r}: {_exception_summary(exc)}"
            )
        return self._queued_count

    def _expect_item(self, item: traffic.TrafficItem, previous: WireOptions | None) -> None:
        interface = self._interface_value
        violations = expected_violations(item.frame, item.options, interface=interface, previous=previous)
        self._expected_violations.update(violations)
        if CheckId.SFD in violations:
            return
        received = decode(interface, interface.encode([item]), checks=False).frames
        if received:
            self.check_mac_octets(received[0].data)

    def expected_violation_count(self, check: str) -> int:
        """
        Violations of a check that a protocol checker with the default limits must report for the
        traffic given to :meth:`check_sequence`, the oracle of a property test.
        """
        return self._expected_violations[CheckId.parse(check)]

    def compared_count(self) -> int:
        """Expected frames compared with a received frame so far."""
        return self._compared_count

    def expected_count(self) -> int:
        """Expected frames not yet received."""
        return len(self._expected)

    def _collect(self, frame: EthernetFrame) -> None:
        if self.collect_frames and frame.mac is not None:
            self._collected.append(frame)

    def take_frames(self) -> npt.NDArray[np.int32]:
        """
        The frames collected since the last call, for VHDL: for each frame its
        octet count, 1 when its FCS is good and 0 otherwise, then its octets from
        the destination address up to the FCS.
        """
        values: list[int] = []
        for frame in self._collected:
            octets = frame.mac_octets
            fcs_ok = frame.mac is not None and frame.mac.fcs_ok is not False
            values.extend((len(octets), int(fcs_ok), *octets))
        self._collected.clear()
        return np.array(values, dtype=np.int32)

    def on_frame(self, subscriber: Callable[[Frame], None]) -> Callable[[Frame], None]:
        """
        Call ``subscriber`` with every frame received from now on; usable as a decorator.

        The subscriber gets a :class:`~awesome_vunit_vcs.ethernet.api.Frame`. An exception it raises is
        logged as a failure on the logger of the monitor; report a finding with
        :meth:`error` instead.
        """

        def deliver(frame: EthernetFrame) -> None:
            subscriber(Frame.from_received(frame))

        deliver.__qualname__ = getattr(subscriber, "__qualname__", repr(subscriber))
        self.monitor.frames.subscribe(deliver)
        return subscriber

    @property
    def frames(self) -> list[Frame]:
        """The most recent frames the monitor keeps (``keep_frames``), oldest first."""
        return [Frame.from_received(frame) for frame in self.monitor.history]

    def error(self, check: str, message: str) -> None:
        """
        Report a violation a Python subscriber found, as a counted check error.

        It is logged as an error on the checker of the monitor, counted by the
        check and dropped while the check is disabled, like the checks the
        monitor runs itself. A VHDL monitor runs ``"ETH_SCOREBOARD"`` and
        ``"ETH_USER"`` and leaves the protocol checks to its protocol checker,
        so a subscriber in the session of a VHDL monitor reports on one of
        those two. In VHDL, ``get_check_count`` and ``set_check_enabled`` on
        the monitor count and switch them.

        Args:
            check: The check name, such as ``"ETH_SCOREBOARD"``.
            message: A summary line, optionally followed by detail lines.

        Raises:
            EthernetValueError: An unknown check.
        """
        header, _, details = message.partition("\n")
        self.monitor.checker.report(check, header, details.splitlines(), self._last_time_fs)

    @property
    def statistics(self) -> EthernetStatistics:
        """
        A snapshot of the statistics.

        Calling the snapshot returns it as well, so ``vc.statistics()`` keeps working.
        """
        return self.monitor.statistics.snapshot()

    def statistics_values(self) -> list[int]:
        """The statistics in :data:`STATISTICS_FIELDS` order, as VHDL integers."""
        stats = self.statistics()
        values: dict[str, int | None] = {
            "total_frames": stats.total_frames,
            "good_frames": stats.good_frames,
            "bad_frames": stats.bad_frames,
            "wire_octets": stats.wire_octets,
            "payload_octets": stats.payload_octets,
            "fcs_errors": stats.fcs_errors,
            "phy_error_frames": stats.phy_error_frames,
            "runts": stats.runts,
            "giants": stats.giants,
            "min_frame_octets": stats.frame_size.minimum,
            "max_frame_octets": stats.frame_size.maximum,
            "min_ifg_octets": stats.ifg_octets.minimum,
            "max_ifg_octets": stats.ifg_octets.maximum,
        }
        return [_saturate(values[name]) for name in STATISTICS_FIELDS]

    def statistics_summary(self) -> str:
        """The human-readable statistics summary."""
        return self.statistics().summary(self.name)

    def last_mac_octets_hex(self) -> str:
        """Destination address up to the FCS of the most recent frame as hex, empty when there is none."""
        return self.monitor.history[-1].mac_octets.hex() if self.monitor.history else ""

    def last_packet(self) -> Any:
        """The most recent frame decoded by Scapy (needs the scapy extra)."""
        from .scapy_adapter import to_scapy

        if not self.monitor.history:
            raise LookupError(f"{self.name} has not received a frame")
        return to_scapy(self.monitor.history[-1])

    def start_capture(
        self,
        path: str | Sequence[int],
        include_fcs: bool = True,
        include_errored: bool = True,
        timestamp_resolution_exponent: int = 9,
    ) -> None:
        """Write the frames received from now on to a PCAPNG file, creating its directory."""
        path = decode_text(path)
        options = CaptureOptions(
            include_fcs=include_fcs,
            include_errored=include_errored,
            timestamp_resolution_exponent=timestamp_resolution_exponent,
            min_ifg_octets=self.monitor.config.min_ifg_octets,
        )
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.monitor.start_capture(path, options)

    def stop_captures(self) -> None:
        """Close every capture."""
        self.monitor.stop_captures()

    def reset(self, clear_statistics: bool = False) -> int:
        """
        Forget a frame in progress, the decoder state, the collected frames and the
        expected frames, for example after the DUT was reset. Statistics and check
        counts are kept unless ``clear_statistics``. Returns the number of waiting reports.
        """
        self.monitor.reset(clear_statistics)
        self.monitor.phy = create_phy(self._interface, **self._phy_options)
        self._expected.clear()
        self._queued_count = 0
        self._compared_count = 0
        self._collected.clear()
        self._expected_violations.clear()
        return len(self.reports)

    def finish(self) -> int:
        """
        End of monitoring: report a frame still in progress and expected frames
        never received, close captures. Returns the number of waiting reports.
        """
        self.monitor.finish(self._last_time_fs)
        if self._expected:
            self.monitor.checker.report(
                CheckId.SCOREBOARD,
                f"{len(self._expected)} expected frame(s) were not received",
                timestamp_fs=self._last_time_fs,
            )
            self._expected.clear()
        self.monitor.stop_captures()
        return len(self.reports)


class ProtocolCheckerBackend:
    """
    The Python object behind a VHDL protocol checker, ``vc`` in its session.

    The monitor engine of :class:`MonitorBackend` with the protocol checks
    enabled and the scoreboard, frame logging and frame collection off. It
    exposes the calls a protocol checker needs.

    Args:
        name: The name of the protocol checker, used in messages.
        interface: The PHY interface name, see :func:`~.phy.create_phy`.
        options: The keyword arguments of :class:`MonitorBackend`.
    """

    def __init__(self, name: str, interface: str, **options: Any) -> None:
        self._backend = MonitorBackend(name, interface, keep_frames=1, **options)
        self._backend.monitor.checker.disable(CheckId.SCOREBOARD)

    @property
    def monitor(self) -> EthernetMonitor:
        """The :class:`~.monitor.EthernetMonitor` running the checks."""
        return self._backend.monitor

    def push(self, samples: Any, base_time: int | Sequence[int], delta_unit: int | Sequence[int] = 1) -> int:
        """See :meth:`MonitorBackend.push`."""
        return self._backend.push(samples, base_time, delta_unit)

    def take_reports(self) -> str:
        """See :meth:`MonitorBackend.take_reports`."""
        return self._backend.take_reports()

    def set_check_enabled(self, check: str, enabled: bool) -> None:
        """See :meth:`MonitorBackend.set_check_enabled`."""
        self._backend.set_check_enabled(check, enabled)

    def check_count(self, check: str) -> int:
        """See :meth:`MonitorBackend.check_count`."""
        return self._backend.check_count(check)

    def finish(self) -> int:
        """See :meth:`MonitorBackend.finish`."""
        return self._backend.finish()

    def reset(self) -> int:
        """Forget a frame in progress and the decoder state, keeping the check counts."""
        return self._backend.reset()


class SourceBackend:
    """
    The Python object behind a VHDL source, ``vc`` in the session of the source.

    Args:
        name: The name of the source, used in messages.
        interface: The PHY interface name, see :func:`~.phy.create_phy`.
        link_rate_bps: The link rate, 0 for the default of the interface.
        link_rate_mbps: The link rate in Mbit/s as VHDL gives it, used when
            ``link_rate_bps`` is 0.
        phy_options: Further options of the PHY encoder, such as XGMII lanes.
        lanes: The lanes of an XGMII interface, added to ``phy_options``.
        deficit_idle: Use the deficit idle count of XGMII, added to ``phy_options``.
        has_fcs: AXI-Stream: whether frames on the bus carry their FCS, added to ``phy_options``.
        valid_low_percent: AXI-Stream: the tvalid stall percentage, added to ``phy_options``.
        seed: AXI-Stream: the seed of the stall pattern, added to ``phy_options``.
        crs_dv_toggle_octets: Toggle valid during the last this many octets of
            every RMII frame, added to ``phy_options``.

    Attributes:
        source: The :class:`~.source.EthernetSource`.
    """

    def __init__(
        self,
        name: str,
        interface: str,
        *,
        link_rate_bps: int = 0,
        link_rate_mbps: int = 0,
        phy_options: dict[str, Any] | None = None,
        lanes: int | None = None,
        deficit_idle: bool | None = None,
        has_fcs: bool | None = None,
        valid_low_percent: int | None = None,
        seed: int | None = None,
        crs_dv_toggle_octets: int | None = None,
    ) -> None:
        self.name = name
        phy_options = _phy_options(
            phy_options,
            link_rate_bps or link_rate_mbps * 1_000_000,
            lanes=lanes,
            deficit_idle=deficit_idle,
            has_fcs=has_fcs,
            valid_low_percent=valid_low_percent,
            seed=seed,
            crs_dv_toggle_octets=crs_dv_toggle_octets,
        )
        self.source = EthernetSource(create_phy(interface, **phy_options), name=name)
        self._sequences: dict[int, Iterator[traffic.TrafficItem]] = {}
        self._arguments: tuple[tuple[Any, ...], dict[str, Any]] = ((), {})

    def set_arguments(self, *args: Any, **kwargs: Any) -> None:
        """See :meth:`MonitorBackend.set_arguments`."""
        self._arguments = (args, kwargs)

    def _take_arguments(
        self, args: Sequence[Any] | None, kwargs: Mapping[str, Any] | None
    ) -> tuple[tuple[Any, ...], dict[str, Any]]:
        pending, self._arguments = self._arguments, ((), {})
        if args is None and kwargs is None:
            return pending
        return tuple(args or ()), dict(kwargs or {})

    def _xgmii(self) -> XgmiiPhy:
        phy = self.source.phy
        if not isinstance(phy, XgmiiPhy):
            raise TypeError(f"{self.name} is a {phy.name} source; only XGMII sources send ordered sets and raw columns")
        return phy

    def ordered_set_symbols(self, value: int, columns: int = 1) -> npt.NDArray[np.int32]:
        """Columns carrying a Sequence ordered set, for example 1 for local fault."""
        return self._xgmii().ordered_set_symbols(value, columns)

    def column_symbols(self, data: Sequence[int], control: Sequence[int]) -> npt.NDArray[np.int32]:
        """Raw XGMII columns, lane 0 first."""
        return self._xgmii().column_symbols(list(data), list(control))

    def queue_bytes(self, data: bytes, **options: Any) -> int:
        """Queue a frame with the options of :func:`~.source.build_wire_frame`; returns its id."""
        return self.source.queue(build_wire_frame(data, **options))

    def queue_unsigned(self, value: int, length: int, **options: Any) -> int:
        """Queue the octets of a VHDL std_ulogic_vector sent as an unsigned integer."""
        return self.queue_bytes(bytes_from_unsigned(value, length), **options)

    def queue_packet(self, packet: Any, **options: Any) -> int:
        """Queue anything ``bytes()`` accepts, for example a Scapy packet."""
        return self.queue_bytes(bytes(packet), **options)

    def take_symbols(self, frame_id: int) -> Any:
        """The sample words of a queued frame, see :meth:`~.source.EthernetSource.take_symbols`."""
        return self.source.take_symbols(frame_id)

    def symbols(self, data: Sequence[int], error_offsets: Sequence[int] = (), **options: Any) -> npt.NDArray[np.int32]:
        """
        The sample words VHDL drives, one per clock cycle, for a frame given as
        octets from the destination address up to the FCS.
        """
        frame_id = self.queue_bytes(bytes(data), error_offsets=tuple(error_offsets), **options)
        return self.take_symbols(frame_id)  # type: ignore[no-any-return]

    def item_symbols(self, item: traffic.TrafficItem) -> npt.NDArray[np.int32]:
        """The sample words VHDL drives for a traffic item, with its wire options applied."""
        return self.take_symbols(self.source.queue(item.to_wire()))  # type: ignore[no-any-return]

    def function_symbols(
        self,
        function: str,
        error_offsets: Sequence[int] = (),
        *,
        args: Sequence[Any] | None = None,
        kwargs: Mapping[str, Any] | None = None,
        **options: Any,
    ) -> npt.NDArray[np.int32]:
        """
        The sample words of the frame a packet function returns, see :func:`~.traffic.call_packet_function`.

        A function that returns wire options with its frame (a
        :class:`~.traffic.TrafficItem` or a ``(packet, WireOptions)`` pair) is
        transmitted with them; any other result with the options VHDL gives.
        The function gets ``args`` and ``kwargs``, or else the arguments given
        to :meth:`set_arguments`.
        """
        call_args, call_kwargs = self._take_arguments(args, kwargs)
        item = traffic.call_packet_function(function, *call_args, **call_kwargs)
        if item.options != WireOptions():
            return self.item_symbols(item)
        return self.symbols(item.frame.data, error_offsets, **options)

    def start_sequence(
        self,
        function: str,
        count: int = 0,
        seed: str | Sequence[int] = "",
        *,
        args: Sequence[Any] | None = None,
        kwargs: Mapping[str, Any] | None = None,
    ) -> int:
        """
        Start transmitting the traffic a generator yields, see :func:`~.traffic.sequence`:
        ``count`` items, or all when 0, each with its own wire options. Returns the id
        :meth:`sequence_symbols` takes. The function gets ``args`` and ``kwargs``,
        or else the arguments given to :meth:`set_arguments`.
        """
        call_args, call_kwargs = self._take_arguments(args, kwargs)
        seed = decode_text(seed)
        items = traffic.sequence(function, *call_args, seed=seed or None, **call_kwargs)
        sequence_id = len(self._sequences)
        self._sequences[sequence_id] = itertools.islice(items, count or None)
        return sequence_id

    def sequence_symbols(self, sequence_id: int, frames: int = 64) -> npt.NDArray[np.int32]:
        """The sample words of the next ``frames`` items of a sequence, empty when it is exhausted."""
        batch = [self.item_symbols(item) for item in itertools.islice(self._sequences[sequence_id], frames)]
        if not batch:
            del self._sequences[sequence_id]
            return np.zeros(0, dtype=np.int32)
        return np.concatenate(batch).astype(np.int32)
