# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The AXI4 protocol checker: the rules of the AXI4 and AXI4-Lite protocol, from the sample words of
:mod:`~awesome_vunit_vcs.axi4.bus`.

Every check has a stable identifier (:class:`~awesome_vunit_vcs.axi4.checks.Axi4CheckId`) and can be
enabled or disabled on its own. A violation message starts with the check ID and gives the channel,
the IDs, addresses and beat numbers involved and the simulation time in fs.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterable

from ..common.events import Publisher
from .burst import BurstType, crosses_4k
from .bus import AddressPayload, Axi4Config, Axi4Control, Axi4Sample, Channel, ControlKind, SampleDecoder
from .checks import PROTOCOL_CHECKS, Axi4CheckId, Axi4Violation
from .errors import Axi4ValueError
from .transaction import TransactionTracker

__all__ = ["Axi4ProtocolChecker", "address_violations"]

#: The signal names of payload fields whose name differs
_SIGNAL_NAMES = {"address": "ADDR"}

#: The largest exclusive access, in bytes
EXCLUSIVE_MAX_BYTES = 128


def address_violations(channel: Channel, payload: AddressPayload, config: Axi4Config) -> list[tuple[Axi4CheckId, str]]:
    """
    The rules an AW or AR handshake breaks on its own: burst type, length, size, alignment, the 4 KB
    boundary, AxCACHE and the exclusive access rules.

    Args:
        channel: ``Channel.AW`` or ``Channel.AR``.
        payload: The address phase.
        config: The widths of the interface.

    Returns:
        ``(check, message)`` for every rule broken; the messages do not start with the check ID.
    """
    p = payload
    number_bytes = 1 << p.size
    beats = p.len + 1
    prefix = f"{channel.name}ID {p.id} {channel.name}ADDR 0x{p.address:X}"
    result: list[tuple[Axi4CheckId, str]] = []
    if number_bytes > config.data_bytes:
        result.append(
            (
                Axi4CheckId.SIZE,
                f"{prefix}: {channel.name}SIZE {p.size} ({number_bytes} bytes) is wider than the "
                f"{config.data_bytes} byte data bus",
            )
        )
    if p.burst == BurstType.RESERVED:
        result.append((Axi4CheckId.BURST_TYPE, f"{prefix}: {channel.name}BURST is the reserved value 0b11"))
    if p.burst == BurstType.FIXED and beats > 16:
        result.append((Axi4CheckId.LEN_FIXED, f"{prefix}: a FIXED burst of {beats} beats, more than 16"))
    if p.burst == BurstType.WRAP:
        if beats not in (2, 4, 8, 16):
            result.append((Axi4CheckId.WRAP_LEN, f"{prefix}: a WRAP burst of {beats} beats, not 2, 4, 8 or 16"))
        if p.address % number_bytes:
            result.append(
                (Axi4CheckId.WRAP_ALIGN, f"{prefix}: a WRAP burst not aligned to its {number_bytes} byte beats")
            )
    if crosses_4k(p.address, p.len, p.size, p.burst):
        last = p.address // number_bytes * number_bytes + beats * number_bytes - 1
        result.append(
            (
                Axi4CheckId.BURST_4K,
                f"{prefix}: an INCR burst of {beats} x {number_bytes} bytes up to 0x{last:X} crosses a 4 KB boundary",
            )
        )
    if not p.cache & 0b0010 and p.cache & 0b1100:
        result.append(
            (
                Axi4CheckId.CACHE,
                f"{prefix}: {channel.name}CACHE 0b{p.cache:04b} sets allocate bits on a non-modifiable transaction",
            )
        )
    if p.lock:
        total = beats * number_bytes
        if total > EXCLUSIVE_MAX_BYTES or total & (total - 1):
            result.append(
                (Axi4CheckId.EXCL, f"{prefix}: an exclusive access of {total} bytes, not a power of 2 up to 128")
            )
        elif p.address % total:
            result.append((Axi4CheckId.EXCL, f"{prefix}: an exclusive access not aligned to its {total} bytes"))
        if beats > 16:
            result.append((Axi4CheckId.EXCL, f"{prefix}: an exclusive access of {beats} beats, more than 16"))
    return result


class Axi4ProtocolChecker:
    """
    Check the AXI4 or AXI4-Lite protocol of an interface from its samples.

    Feed it the sample words of :mod:`~awesome_vunit_vcs.axi4.bus` with :meth:`feed`. Violations of enabled
    checks are counted and published on ``violations``; all checks are enabled initially.

    Args:
        config: The widths of the interface, 32-bit data and address without IDs by default.
        timeout_cycles: How many clock cycles a transaction may wait for its response, write data for
            its address, and VALID for READY; 0 to never report ``AXI4_TIMEOUT``.

    Raises:
        Axi4ValueError: ``timeout_cycles`` is negative.
    """

    def __init__(self, config: Axi4Config | None = None, timeout_cycles: int = 0) -> None:
        if timeout_cycles < 0:
            raise Axi4ValueError(f"Negative timeout_cycles={timeout_cycles}")
        self.config = config or Axi4Config()
        self.timeout_cycles = timeout_cycles
        self.violations: Publisher[Axi4Violation] = Publisher()
        self._enabled = set(PROTOCOL_CHECKS)
        self._counts = dict.fromkeys(PROTOCOL_CHECKS, 0)
        self._decoder = SampleDecoder(self.config)
        self._tracker = TransactionTracker(self.config, lambda _: None, self._report)
        self._period_fs = 0
        self.reset()

    def reset(self, clear_counts: bool = True) -> None:
        """Forget the bus history, and the violation counts unless ``clear_counts`` is false."""
        self._decoder.reset()
        self._tracker.reset()
        if clear_counts:
            self._counts = dict.fromkeys(PROTOCOL_CHECKS, 0)
        self._previous: dict[Channel, Axi4Sample] = {}
        self._stall_since: dict[Channel, int] = {}
        self._stall_reported: set[Channel] = set()
        self._in_reset = False
        self._release_fs: int | None = None
        self._now_fs = 0

    # Switches and counts
    def enable(self, *checks: Axi4CheckId | str) -> None:
        """Enable checks, given as :class:`~awesome_vunit_vcs.axi4.checks.Axi4CheckId` or names."""
        self._enabled.update(self._protocol_check(check) for check in checks)

    def disable(self, *checks: Axi4CheckId | str) -> None:
        """Disable checks; a disabled check neither reports nor counts."""
        self._enabled.difference_update(self._protocol_check(check) for check in checks)

    def is_enabled(self, check: Axi4CheckId | str) -> bool:
        """Whether a check is enabled."""
        return self._protocol_check(check) in self._enabled

    def count(self, check: Axi4CheckId | str) -> int:
        """The violations of a check found while it was enabled."""
        return self._counts[self._protocol_check(check)]

    @property
    def counts(self) -> dict[Axi4CheckId, int]:
        """The violations of every check."""
        return dict(self._counts)

    @staticmethod
    def _protocol_check(check: Axi4CheckId | str) -> Axi4CheckId:
        member = Axi4CheckId.parse(check)
        if member not in PROTOCOL_CHECKS:
            raise Axi4ValueError(f"{member.value} is a check of the monitor, not of the protocol checker")
        return member

    # Samples
    @property
    def period_fs(self) -> int:
        """The clock period the VHDL component measured, 0 before the second rising edge."""
        return self._period_fs

    def feed(self, words: Iterable[int], times: Iterable[int]) -> None:
        """Check sample words with their times in fs."""
        for record in self._decoder.decode(list(words), list(times)):
            if isinstance(record, Axi4Control):
                self._control(record)
            else:
                self._sample(record)
        self._check_timeouts()

    def advance(self, now_fs: int) -> None:
        """Let time pass without samples, and report what timed out by ``now_fs``."""
        self._now_fs = max(self._now_fs, now_fs)
        self._check_timeouts()

    def _report(self, check: Axi4CheckId, message: str, time_fs: int) -> None:
        if check in self._enabled:
            self._counts[check] += 1
            self.violations.publish(Axi4Violation(check, message, time_fs))

    def _violation(self, check: Axi4CheckId, message: str, time_fs: int) -> None:
        self._report(check, f"{check.value}: {message} at {time_fs} fs", time_fs)

    def _control(self, control: Axi4Control) -> None:
        self._now_fs = control.time_fs
        if control.kind == ControlKind.PERIOD:
            self._period_fs = control.period_fs
        elif control.kind == ControlKind.RESET:
            if control.resetn_metavalue:
                self._violation(Axi4CheckId.METAVALUE, "metavalue on ARESETn", control.time_fs)
            if control.in_reset and not self._in_reset:
                self._tracker.reset()
                self._previous.clear()
                self._stall_since.clear()
                self._stall_reported.clear()
            elif not control.in_reset and self._in_reset:
                self._release_fs = control.time_fs
            self._in_reset = control.in_reset

    def _sample(self, sample: Axi4Sample) -> None:
        self._now_fs = sample.time_fs
        channel = sample.channel
        name = channel.name
        time_fs = sample.time_fs
        if sample.valid and (sample.in_reset or time_fs == self._release_fs):
            when = "while ARESETn is 0" if sample.in_reset else "at the first rising edge of ACLK after reset"
            self._violation(Axi4CheckId.RESET_VALID, f"{name}VALID is 1 {when}", time_fs)
        if sample.in_reset:
            self._previous.pop(channel, None)
            return
        if sample.valid_metavalue:
            self._violation(Axi4CheckId.METAVALUE, f"metavalue on {name}VALID", time_fs)
        if sample.ready_metavalue:
            self._violation(Axi4CheckId.METAVALUE, f"metavalue on {name}READY", time_fs)
        if sample.valid and sample.payload_metavalue:
            self._violation(Axi4CheckId.METAVALUE, f"metavalue on the {name} payload while {name}VALID is 1", time_fs)
        payload = sample.payload
        if sample.valid and channel == Channel.W:
            strobed = payload.lane_metavalues & payload.strb  # type: ignore[union-attr]
            if strobed:
                self._violation(Axi4CheckId.METAVALUE, f"metavalue on strobed WDATA lanes 0x{strobed:X}", time_fs)
        previous = self._previous.get(channel)
        if previous is not None and previous.stall:
            if sample.valid:
                changed = self._changed(previous, sample)
                if changed:
                    self._violation(
                        Axi4CheckId.STABLE,
                        f"{', '.join(changed)} changed while {name}VALID was 1 and {name}READY 0",
                        time_fs,
                    )
            elif not sample.valid_metavalue:
                self._violation(
                    Axi4CheckId.VALID_DROP,
                    f"{name}VALID fell before {name}READY accepted the payload offered since"
                    f" {self._stall_since.get(channel, previous.time_fs)} fs",
                    time_fs,
                )
        if sample.stall:
            self._stall_since.setdefault(channel, time_fs)
        else:
            self._stall_since.pop(channel, None)
            self._stall_reported.discard(channel)
        if sample.handshake:
            if isinstance(payload, AddressPayload):
                for check, message in address_violations(channel, payload, self.config):
                    self._violation(check, message, time_fs)
            self._tracker.handshake(sample)
        self._previous[channel] = sample

    def _changed(self, previous: Axi4Sample, sample: Axi4Sample) -> list[str]:
        """The payload fields that differ, data compared on the lanes that carry data."""
        before, after = previous.payload, sample.payload
        changed = []
        for field in dataclasses.fields(before):
            if field.name == "lane_metavalues":
                continue
            old, new = getattr(before, field.name), getattr(after, field.name)
            if field.name == "data":
                mask = self._data_mask(sample)
                old, new = old & mask, new & mask
            if old != new:
                changed.append(f"{sample.channel.name}{_SIGNAL_NAMES.get(field.name, field.name.upper())}")
        return changed

    def _data_mask(self, sample: Axi4Sample) -> int:
        if sample.channel == Channel.W:
            lanes = sample.payload.strb  # type: ignore[union-attr]
        else:
            lanes = self._tracker.next_read_lanes(sample.payload.id)  # type: ignore[union-attr]
            if lanes is None:
                lanes = (1 << self.config.data_bytes) - 1
        mask = 0
        for lane in range(self.config.data_bytes):
            if lanes >> lane & 1:
                mask |= 0xFF << (8 * lane)
        return mask

    def _check_timeouts(self) -> None:
        if not self.timeout_cycles or not self._period_fs:
            return
        limit_fs = self.timeout_cycles * self._period_fs
        self._tracker.check_timeouts(self._now_fs, limit_fs)
        for channel, since in self._stall_since.items():
            if channel not in self._stall_reported and self._now_fs - since >= limit_fs:
                self._stall_reported.add(channel)
                name = channel.name
                self._violation(
                    Axi4CheckId.TIMEOUT,
                    f"{name}VALID has waited for {name}READY since {since} fs, more than {self.timeout_cycles} cycles",
                    self._now_fs,
                )
