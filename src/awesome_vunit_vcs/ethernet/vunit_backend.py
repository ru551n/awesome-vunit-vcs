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
from collections.abc import Callable
from typing import Any

from ..common.reports import ReportQueue, Severity, encode_reports
from ..common.vunit_bridge import bytes_from_unsigned, decode_samples, join_time
from .checker import CheckId, Violation
from .frame import EthernetConfig, EthernetFrame
from .metrics import EthernetStatistics
from .monitor import EthernetMonitor
from .pcap import CaptureOptions
from .phy import create_phy
from .source import EthernetSource, build_wire_frame


def _exception_summary(exc: BaseException) -> str:
    frames = traceback.extract_tb(exc.__traceback__)
    where = f" ({frames[-1].filename}:{frames[-1].lineno})" if frames else ""
    return f"{type(exc).__name__}: {exc}{where}"


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
    ) -> None:
        self.name = name
        self.reports = ReportQueue()
        self.log_frames = log_frames
        phy_options = {"link_rate_bps": link_rate_bps} if link_rate_bps else {}
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

    # Called by VHDL
    def push(self, samples: Any, base_hi: int, base_lo: int) -> int:
        """Process a sample batch. Returns the number of reports waiting to be fetched."""
        try:
            words, times = decode_samples(samples, join_time(base_hi, base_lo))
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

    def statistics(self) -> EthernetStatistics:
        return self.monitor.statistics.snapshot()

    def statistics_summary(self) -> str:
        return self.statistics().summary(self.name)

    def last_payload_hex(self) -> str:
        """Payload of the most recent frame as hex, empty when there is none."""
        return self.monitor.history[-1].payload.hex() if self.monitor.history else ""

    def start_capture(self, path: str, include_fcs: bool = True, include_errored: bool = True,
                      timestamp_resolution_exponent: int = 9) -> None:
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
        """Report a frame still in progress; returns the number of waiting reports."""
        self.monitor.finish(self._last_time_fs)
        return len(self.reports)


class SourceBackend:
    def __init__(self, name: str, interface: str, *, link_rate_bps: int = 0) -> None:
        self.name = name
        phy_options = {"link_rate_bps": link_rate_bps} if link_rate_bps else {}
        self.source = EthernetSource(create_phy(interface, **phy_options), name=name)

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
