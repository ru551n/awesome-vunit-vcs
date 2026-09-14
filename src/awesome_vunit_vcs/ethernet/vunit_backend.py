"""
Backends of the Ethernet VHDL verification components.

Each VC instance creates one backend object in its own Python session (the
session has the identity of the VC, so instances never share state). VHDL
calls these methods; nothing here touches simulator signals. Everything a
VHDL user needs is reachable through the VHDL API; Python users can reach the
backend object as ``vc`` in the session of the VC.
"""

from __future__ import annotations

import os
import traceback
from collections import deque
from collections.abc import Callable, Sequence
from typing import Any

import numpy as np
import numpy.typing as npt

from ..common.reports import ReportQueue, Severity, encode_reports
from ..common.vunit_bridge import bytes_from_unsigned, decode_samples, join_time
from .checker import CheckId, Violation
from .frame import FCS_OCTETS, EthernetConfig, EthernetFrame
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


def _saturate(value: int | None) -> int:
    """A statistic as a VHDL integer: -1 when there is no value."""
    return -1 if value is None else min(value, VHDL_INTEGER_MAX)


class MonitorBackend:
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
        keep_frames: int = 256,
        log_frames: bool = False,
        phy_options: dict[str, Any] | None = None,
    ) -> None:
        self.name = name
        self.reports = ReportQueue()
        self.log_frames = log_frames
        phy_options = {**(phy_options or {}), **({"link_rate_bps": link_rate_bps} if link_rate_bps else {})}
        config = EthernetConfig(
            min_preamble_octets=min_preamble_octets,
            max_preamble_octets=max_preamble_octets,
            min_frame_octets=min_frame_octets,
            max_frame_octets=max_frame_octets,
            min_ifg_octets=min_ifg_octets,
            has_fcs=has_fcs,
        )
        self.monitor = EthernetMonitor(
            create_phy(interface, **phy_options),
            config,
            name=name,
            keep_frames=keep_frames,
            on_subscriber_error=self._subscriber_error,
        )
        self.monitor.checker.violations.subscribe(self._violation)
        self.monitor.frames.subscribe(self._frame_logger)
        self.monitor.frames.subscribe(self._compare_with_expected)
        self._expected: deque[bytes] = deque()
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
                f"frame {frame.index}: {mac.size_with_fcs} bytes, dst={destination}, "
                f"fcs_ok={mac.fcs_ok}, SFD time={frame.timestamp_sfd_fs} fs"
            )
        self.reports.add(Severity.DEBUG, text)

    def _padded(self, data: bytes) -> bytes:
        """data padded with zeros to the minimum frame size, the way a transmitter pads it"""
        config = self.monitor.config
        minimum = config.min_frame_octets - (FCS_OCTETS if config.has_fcs else 0)
        return data + bytes(max(0, minimum - len(data)))

    def _compare_with_expected(self, frame: EthernetFrame) -> None:
        if not self._expected:
            return
        expected = self._expected.popleft()
        received = frame.mac_octets
        if received in (expected, self._padded(expected)):
            return
        mismatch = next(
            (offset for offset, (a, b) in enumerate(zip(expected, received, strict=False)) if a != b),
            min(len(expected), len(received)),
        )
        self.monitor.checker.report(
            CheckId.SCOREBOARD,
            f"frame {frame.index} is not the expected frame",
            [
                f"expected length={len(expected)} bytes",
                f"received length={len(received)} bytes",
                f"first difference at offset {mismatch}",
                f"SFD time={frame.timestamp_sfd_fs} fs",
            ],
            frame.timestamp_start_fs,
            frame.index,
        )

    # Called by VHDL
    def push(self, samples: Any, base_hi: int, base_lo: int, delta_unit_fs: int = 1) -> int:
        """Process a sample batch. Returns the number of reports waiting to be fetched."""
        try:
            words, times = decode_samples(samples, join_time(base_hi, base_lo), delta_unit_fs)
            if times.size:
                self._last_time_fs = int(times[-1])
            self.monitor.feed(words, times)
        except Exception as exc:
            self.reports.add(Severity.FAILURE, f"{self.name} could not process samples: {_exception_summary(exc)}")
        return len(self.reports)

    def take_reports(self) -> str:
        return encode_reports(self.reports.take())

    def set_check_enabled(self, check: str, enabled: bool) -> None:
        if enabled:
            self.monitor.checker.enable(check)
        else:
            self.monitor.checker.disable(check)

    def check_count(self, check: str) -> int:
        return self.monitor.checker.count(CheckId.parse(check))

    def frame_count(self) -> int:
        return self.monitor.frame_count

    def good_frame_count(self) -> int:
        return self.statistics().good_frames

    def expect_mac_octets(self, data: Sequence[int]) -> None:
        """Queue the frame (destination address up to the FCS) the next received frame must equal."""
        self._expected.append(bytes(data))

    def expected_count(self) -> int:
        """Expected frames not yet received."""
        return len(self._expected)

    def statistics(self) -> EthernetStatistics:
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
        path: str,
        include_fcs: bool = True,
        include_errored: bool = True,
        timestamp_resolution_exponent: int = 9,
    ) -> None:
        options = CaptureOptions(
            include_fcs=include_fcs,
            include_errored=include_errored,
            timestamp_resolution_exponent=timestamp_resolution_exponent,
            min_ifg_octets=self.monitor.config.min_ifg_octets,
        )
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.monitor.start_capture(path, options)

    def stop_captures(self) -> None:
        self.monitor.stop_captures()

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


class SourceBackend:
    def __init__(
        self, name: str, interface: str, *, link_rate_bps: int = 0, phy_options: dict[str, Any] | None = None
    ) -> None:
        self.name = name
        phy_options = {**(phy_options or {}), **({"link_rate_bps": link_rate_bps} if link_rate_bps else {})}
        self.source = EthernetSource(create_phy(interface, **phy_options), name=name)

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
        return self.source.queue(build_wire_frame(data, **options))

    def queue_unsigned(self, value: int, length: int, **options: Any) -> int:
        """Queue the octets of a VHDL std_ulogic_vector sent as an unsigned integer."""
        return self.queue_bytes(bytes_from_unsigned(value, length), **options)

    def queue_packet(self, packet: Any, **options: Any) -> int:
        """Queue anything ``bytes()`` accepts, for example a Scapy packet."""
        return self.queue_bytes(bytes(packet), **options)

    def take_symbols(self, frame_id: int) -> Any:
        return self.source.take_symbols(frame_id)

    def symbols(self, data: Sequence[int], error_offsets: Sequence[int] = (), **options: Any) -> npt.NDArray[np.int32]:
        """
        The sample words VHDL drives, one per clock cycle, for a frame given as
        octets from the destination address up to the FCS.
        """
        frame_id = self.queue_bytes(bytes(data), error_offsets=tuple(error_offsets), **options)
        return self.take_symbols(frame_id)  # type: ignore[no-any-return]

    def packet_symbols(self, expression: str, error_offsets: Sequence[int] = (), **options: Any) -> Any:
        """Like :meth:`symbols` for a Scapy expression such as ``"Ether()/IP()/UDP()"``."""
        # The expression is testbench code, as trusted as the VHDL that passes
        # it; evaluating it is the point, like python_pkg's own exec and eval
        namespace: dict[str, Any] = {}
        exec("from scapy.all import *", namespace)
        packet = eval(expression, namespace)
        return self.symbols(bytes(packet), error_offsets, **options)
