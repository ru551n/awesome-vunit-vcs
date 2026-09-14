"""
Protocol checker: a subscriber of monitor events, not part of the sampler.

Every check has a stable identifier (:class:`CheckId`) and can be enabled or
disabled on its own. Violations are published; the VUnit backend turns them
into failures on the checker of the verification component.
"""

from __future__ import annotations

import enum
from collections.abc import Iterable
from dataclasses import dataclass

from ..common.events import Publisher
from .frame import SFD_OCTET, EthernetConfig, EthernetFrame
from .phy.common import IdleEvent, PhyEvent


class CheckId(str, enum.Enum):
    """
    The stable identifiers of the protocol checks.

    The value is the name used in messages and accepted by VHDL
    (``eth_fcs``) and Python (``"ETH_FCS"``, ``"FCS"``) alike.
    """

    PREAMBLE = "ETH_PREAMBLE"
    SFD = "ETH_SFD"
    FCS = "ETH_FCS"
    RUNT = "ETH_RUNT"
    GIANT = "ETH_GIANT"
    PHY_ERROR = "ETH_PHY_ERROR"
    CARRIER = "ETH_CARRIER"
    IFG = "ETH_IFG"
    TERMINATION = "ETH_TERMINATION"
    METAVALUE = "ETH_METAVALUE"
    FRAME_STATE = "ETH_FRAME_STATE"
    #: A misplaced or unknown control character (control character PHYs such as XGMII)
    CONTROL = "ETH_CONTROL"
    #: A local or remote fault signaled by the PHY
    LINK_FAULT = "ETH_LINK_FAULT"
    #: A received frame differs from the expected one, or an expected frame never arrived
    SCOREBOARD = "ETH_SCOREBOARD"

    @classmethod
    def parse(cls, check: CheckId | str) -> CheckId:
        """
        Look up a check by member, value or name, case insensitively.

        Raises:
            ValueError: ``check`` names no check.
        """
        if isinstance(check, CheckId):
            return check
        name = check.strip().upper()
        for member in cls:
            if name in (member.value, member.name, f"ETH_{member.name}"):
                return member
        known = ", ".join(member.value for member in cls)
        raise ValueError(f"Unknown Ethernet check {check!r}, known checks: {known}")


@dataclass(slots=True, frozen=True)
class Violation:
    """A failed check, as published by :attr:`ProtocolChecker.violations`."""

    check: CheckId
    #: The check name and a summary on the first line, details on the following lines
    message: str
    #: Simulation time of the violation in fs
    timestamp_fs: int
    #: Index of the frame the violation concerns, None outside a frame
    frame_index: int | None = None


def _hex(value: int | None, digits: int = 8) -> str:
    return "none" if value is None else f"0x{value:0{digits}X}"


def _frame_context(frame: EthernetFrame) -> list[str]:
    lines = []
    sfd = frame.timestamp_sfd_fs
    if sfd is not None:
        lines.append(f"SFD time={sfd} fs")
    else:
        lines.append(f"start time={frame.timestamp_start_fs} fs")
    if frame.mac is not None:
        lines.append(f"length={frame.mac.size_with_fcs} bytes")
    else:
        lines.append(f"wire length={len(frame.phy.octets)} octets")
    return lines


class ProtocolChecker:
    """
    Check frames and idle events against an :class:`EthernetConfig`.

    A subscriber of monitor events: :class:`~.monitor.EthernetMonitor`
    subscribes :meth:`on_frame`, :meth:`on_idle_event` and :meth:`on_phy_event`.
    Violations of enabled checks are counted and published on
    :attr:`violations`; all checks are enabled initially.

    Args:
        config: What a well-formed frame is. The default is IEEE 802.3.
    """

    def __init__(self, config: EthernetConfig | None = None) -> None:
        self.config = config or EthernetConfig()
        self.violations: Publisher[Violation] = Publisher()
        self._enabled = set(CheckId)
        self._counts = dict.fromkeys(CheckId, 0)

    def enable(self, *checks: CheckId | str) -> None:
        """Enable checks, given as :class:`CheckId` or names."""
        self._enabled.update(CheckId.parse(check) for check in checks)

    def disable(self, *checks: CheckId | str) -> None:
        """Disable checks; a disabled check neither reports nor counts."""
        self._enabled.difference_update(CheckId.parse(check) for check in checks)

    def is_enabled(self, check: CheckId | str) -> bool:
        """Whether a check is enabled."""
        return CheckId.parse(check) in self._enabled

    def count(self, check: CheckId | str) -> int:
        """Violations found by a check while it was enabled."""
        return self._counts[CheckId.parse(check)]

    @property
    def counts(self) -> dict[CheckId, int]:
        """Violations of every check, including checks that found none."""
        return dict(self._counts)

    @property
    def total(self) -> int:
        """Violations of all checks."""
        return sum(self._counts.values())

    def report(
        self,
        check: CheckId | str,
        header: str,
        details: Iterable[str] = (),
        timestamp_fs: int = 0,
        index: int | None = None,
    ) -> None:
        """
        Report a violation found by a component other than the checker, for
        example a scoreboard. It is counted, enabled and disabled like the
        violations the checker finds itself.
        """
        self._report(CheckId.parse(check), header, details, timestamp_fs, index)

    def _report(
        self, check: CheckId, header: str, details: Iterable[str], timestamp_fs: int, index: int | None
    ) -> None:
        if check not in self._enabled:
            return
        self._counts[check] += 1
        message = "\n".join([f"{check.value}: {header}", *details])
        self.violations.publish(Violation(check, message, timestamp_fs, index))

    def on_frame(self, frame: EthernetFrame) -> None:
        """Check a received frame: preamble, SFD, FCS, size, PHY errors, metavalues and the gap before it."""
        config = self.config
        phy = frame.phy
        index = frame.index
        context = _frame_context(frame)
        time = frame.timestamp_sfd_fs if frame.timestamp_sfd_fs is not None else frame.timestamp_start_fs

        if phy.started_in_progress:
            self._report(
                CheckId.FRAME_STATE,
                f"frame {index} was already in progress when monitoring started",
                context,
                time,
                index,
            )

        if phy.metavalue_offsets:
            offsets = ", ".join(str(offset) for offset in phy.metavalue_offsets[:16])
            more = " ..." if len(phy.metavalue_offsets) > 16 else ""
            self._report(
                CheckId.METAVALUE,
                f"metavalue on the data of frame {index}",
                [f"wire offsets={offsets}{more}", *context],
                time,
                index,
            )

        if not frame.preamble_ok:
            first = f"0x{phy.octets[0]:02X}" if phy.octets else "none"
            self._report(
                CheckId.PREAMBLE,
                f"malformed preamble on frame {index}",
                [
                    f"preamble octets={frame.preamble_octets}",
                    f"expected={config.min_preamble_octets}"
                    + (
                        ""
                        if config.min_preamble_octets == config.max_preamble_octets
                        else f"..{config.max_preamble_octets}"
                    ),
                    f"first octet={first}",
                    *context,
                ],
                time,
                index,
            )

        if frame.sfd_offset is None:
            offset = frame.preamble_octets
            received = f"0x{phy.octets[offset]:02X}" if offset < len(phy.octets) else "end of frame"
            self._report(
                CheckId.SFD,
                f"missing SFD on frame {index}",
                [f"expected=0x{SFD_OCTET:02X} at wire offset {offset}", f"received={received}", *context],
                time,
                index,
            )
            return

        mac = frame.mac
        assert mac is not None

        if mac.fcs_ok is False:
            self._report(
                CheckId.FCS,
                f"bad FCS on frame {index}",
                [f"expected={_hex(mac.fcs_expected)}", f"received={_hex(mac.fcs_received)}", *context],
                time,
                index,
            )

        if frame.is_runt:
            self._report(
                CheckId.RUNT,
                f"runt frame {index}",
                [f"minimum={config.min_frame_octets} bytes", *context],
                time,
                index,
            )

        if frame.is_giant:
            self._report(
                CheckId.GIANT,
                f"oversized frame {index}",
                [f"maximum={config.max_frame_octets} bytes", *context],
                time,
                index,
            )

        if phy.wire_error_offsets:
            offsets = ", ".join(str(offset) for offset in frame.error_offsets[:16])
            more = " ..." if len(phy.wire_error_offsets) > 16 else ""
            self._report(
                CheckId.PHY_ERROR,
                f"PHY error asserted during frame {index}",
                [f"frame offsets={offsets}{more} (0 is the first octet after the SFD)", *context],
                time,
                index,
            )

        if phy.alignment_error:
            self._report(
                CheckId.TERMINATION,
                f"frame {index} ended with an incomplete octet",
                context,
                time,
                index,
            )

        if frame.ifg_octets is not None and frame.ifg_octets < config.min_ifg_octets:
            self._report(
                CheckId.IFG,
                f"inter-frame gap before frame {index} is {frame.ifg_octets} octets",
                [f"minimum={config.min_ifg_octets} octets", f"gap={frame.ifg_fs} fs", *context],
                time,
                index,
            )

    def on_idle_event(self, event: IdleEvent) -> None:
        """Check a sample between frames with the error signal asserted or a metavalue."""
        if event.metavalue:
            self._report(
                CheckId.METAVALUE,
                "metavalue on the valid or error signal outside a frame",
                [f"time={event.timestamp_fs} fs"],
                event.timestamp_fs,
                None,
            )
        elif event.error:
            self._report(
                CheckId.CARRIER,
                "error signal asserted outside a frame",
                [f"data=0x{event.value:02X}", f"time={event.timestamp_fs} fs"],
                event.timestamp_fs,
                None,
            )

    def on_phy_event(self, event: PhyEvent) -> None:
        """Report a violation a PHY decoder found, such as a misplaced XGMII control character."""
        self._report(
            CheckId.parse(event.check),
            event.message,
            [*event.details, f"time={event.timestamp_fs} fs"],
            event.timestamp_fs,
            None,
        )

    def on_unfinished_frame(self, frame: EthernetFrame) -> None:
        """Report a frame that was still being received when monitoring ended."""
        self._report(
            CheckId.FRAME_STATE,
            f"frame {frame.index} was still in progress when monitoring ended",
            _frame_context(frame),
            frame.timestamp_start_fs,
            frame.index,
        )
