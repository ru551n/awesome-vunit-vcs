# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The I2C protocol checker: bus timing and bit-level protocol, from SCL and SDA samples.

Every check has a stable identifier (:class:`CheckId`) and can be enabled or
disabled on its own. A violation message starts with the check ID and gives
the measured value, the limit and the simulation time, all in fs.
"""

from __future__ import annotations

import enum
from collections.abc import Iterable
from dataclasses import dataclass

from ..common.events import Publisher
from .bus import SCL_BIT, SCL_METAVALUE_BIT, SDA_BIT, SDA_METAVALUE_BIT, BusDecoder, BusEvent, EventKind
from .errors import I2cValueError
from .timing import BusLimits, bus_limits

__all__ = ["CheckId", "I2cProtocolChecker", "Violation"]


class CheckId(str, enum.Enum):
    """
    The stable identifiers of the I2C checks.

    The value is the name used in messages, accepted by VHDL (``i2c_t_low``) and Python (``"I2C_T_LOW"``,
    ``"T_LOW"``) alike.
    """

    #: Two rising SCL edges closer than 1 / fSCL max
    F_SCL = "I2C_F_SCL"
    #: A START held for less than tHD;STA before SCL fell
    T_HD_STA = "I2C_T_HD_STA"
    #: SCL low for less than tLOW
    T_LOW = "I2C_T_LOW"
    #: SCL high for less than tHIGH
    T_HIGH = "I2C_T_HIGH"
    #: A repeated START less than tSU;STA after SCL rose
    T_SU_STA = "I2C_T_SU_STA"
    #: SDA changed less than tHD;DAT after SCL fell
    T_HD_DAT = "I2C_T_HD_DAT"
    #: SDA changed less than tSU;DAT before SCL rose
    T_SU_DAT = "I2C_T_SU_DAT"
    #: A STOP less than tSU;STO after SCL rose
    T_SU_STO = "I2C_T_SU_STO"
    #: A START less than tBUF after a STOP
    T_BUF = "I2C_T_BUF"
    #: SDA changed while SCL was high inside a byte: a START or STOP after 1 to 7 bits
    SDA_STABLE = "I2C_SDA_STABLE"
    #: A byte without an acknowledge bit: a START or STOP right after 8 bits
    ACK_SLOT = "I2C_ACK_SLOT"
    #: A metavalue on SCL or SDA
    METAVALUE = "I2C_METAVALUE"
    #: SCL or SDA low for longer than the stuck-low time
    STUCK_LOW = "I2C_STUCK_LOW"
    #: A transfer differs from the expected one, or an expected transfer never came (monitor)
    SCOREBOARD = "I2C_SCOREBOARD"

    @classmethod
    def parse(cls, check: CheckId | str) -> CheckId:
        """
        Look up a check by member, value or name, case insensitively.

        Raises:
            I2cValueError: ``check`` names no check.
        """
        if isinstance(check, CheckId):
            return check
        name = check.strip().upper()
        for member in cls:
            if name in (member.value, member.name):
                return member
        known = ", ".join(member.value for member in cls)
        raise I2cValueError(f"Unknown I2C check {check!r}, known checks: {known}")


#: The checks :class:`I2cProtocolChecker` runs; the monitor runs the others
PROTOCOL_CHECKS = frozenset(CheckId) - {CheckId.SCOREBOARD}


@dataclass(frozen=True, slots=True)
class Violation:
    """A failed check."""

    check: CheckId
    #: Starts with the check ID
    message: str
    #: Simulation time of the violation in fs
    time_fs: int


class I2cProtocolChecker:
    """
    Check the timing and bit-level protocol of an I2C bus from its samples.

    Feed it the sample words of :mod:`~awesome_vunit_vcs.i2c.bus` with :meth:`feed`. Violations of
    enabled checks are counted and published on ``violations``; all checks are enabled initially.

    Args:
        limits: The timing limits, :func:`~awesome_vunit_vcs.i2c.timing.bus_limits` of Standard-mode by
            default.
        t_stuck_fs: How long SCL or SDA may stay low, 0 to never report it.
    """

    def __init__(self, limits: BusLimits | None = None, t_stuck_fs: int = 35_000_000_000_000) -> None:
        if t_stuck_fs < 0:
            raise I2cValueError(f"Negative t_stuck_fs={t_stuck_fs}")
        self.limits = limits or bus_limits()
        self.t_stuck_fs = t_stuck_fs
        self.violations: Publisher[Violation] = Publisher()
        self._enabled = set(PROTOCOL_CHECKS)
        self._counts = dict.fromkeys(PROTOCOL_CHECKS, 0)
        self._decoder = BusDecoder()
        self.reset()

    def reset(self, clear_counts: bool = True) -> None:
        """Forget the timing history, and the violation counts unless ``clear_counts`` is false."""
        self._decoder.reset()
        if clear_counts:
            self._counts = dict.fromkeys(PROTOCOL_CHECKS, 0)
        self._busy = False
        self._bits = 0
        self._last_rise: int | None = None
        self._last_fall: int | None = None
        self._last_stop: int | None = None
        self._start: int | None = None
        self._condition_in_high = False
        self._condition_since_rise = False
        self._data_change: int | None = None
        # Since when each line (0 SCL, 1 SDA) is low, and whether that was reported
        self._low_since: list[int | None] = [None, None]
        self._stuck_reported = [False, False]
        self._metavalue = [False, False]

    # Switches and counts
    def enable(self, *checks: CheckId | str) -> None:
        """Enable checks, given as :class:`CheckId` or names."""
        self._enabled.update(self._protocol_check(check) for check in checks)

    def disable(self, *checks: CheckId | str) -> None:
        """Disable checks; a disabled check neither reports nor counts."""
        self._enabled.difference_update(self._protocol_check(check) for check in checks)

    def is_enabled(self, check: CheckId | str) -> bool:
        """Whether a check is enabled."""
        return self._protocol_check(check) in self._enabled

    def count(self, check: CheckId | str) -> int:
        """Violations found by a check while it was enabled."""
        return self._counts[self._protocol_check(check)]

    @staticmethod
    def _protocol_check(check: CheckId | str) -> CheckId:
        parsed = CheckId.parse(check)
        if parsed not in PROTOCOL_CHECKS:
            raise I2cValueError(f"{parsed.value} is not a check of the protocol checker")
        return parsed

    def _report(self, check: CheckId, text: str, time_fs: int) -> None:
        if check not in self._enabled:
            return
        self._counts[check] += 1
        self.violations.publish(Violation(check, f"{check.value}: {text} at {time_fs} fs", time_fs))

    def _minimum(self, check: CheckId, what: str, measured: int, limit: int, time_fs: int) -> None:
        if measured < limit:
            self._report(check, f"{what} {measured} fs, less than the minimum {limit} fs", time_fs)

    # Samples
    def feed(self, words: Iterable[int], times_fs: Iterable[int]) -> None:
        """Check a batch of sample words with their times in fs."""
        for word, time_fs in zip(words, times_fs, strict=True):
            word = int(word)
            time_fs = int(time_fs)
            for event in self._decoder.decode(word, time_fs):
                self._event(event)
            self._levels(word, time_fs)

    def check_stuck(self, now_fs: int) -> None:
        """Report a line that has been low for longer than the stuck-low time at ``now_fs``."""
        if not self.t_stuck_fs:
            return
        for line, name in enumerate(("SCL", "SDA")):
            since = self._low_since[line]
            if since is not None and not self._stuck_reported[line] and now_fs - since > self.t_stuck_fs:
                self._stuck_reported[line] = True
                self._report(
                    CheckId.STUCK_LOW,
                    f"{name} low since {since} fs, longer than the limit {self.t_stuck_fs} fs,",
                    now_fs,
                )

    def _levels(self, word: int, time_fs: int) -> None:
        for line, (value_bit, meta_bit, name) in enumerate(
            ((SCL_BIT, SCL_METAVALUE_BIT, "SCL"), (SDA_BIT, SDA_METAVALUE_BIT, "SDA"))
        ):
            metavalue = bool(word & meta_bit)
            if metavalue and not self._metavalue[line]:
                self._report(CheckId.METAVALUE, f"metavalue on {name}", time_fs)
            self._metavalue[line] = metavalue
            if metavalue:
                continue
            if word & value_bit:
                self._low_since[line] = None
                self._stuck_reported[line] = False
            elif self._low_since[line] is None:
                self._low_since[line] = time_fs
        self.check_stuck(time_fs)

    def _event(self, event: BusEvent) -> None:
        limits = self.limits
        time_fs = event.time_fs
        kind = event.kind
        if kind is EventKind.RISE:
            # A period across a START or STOP is not a clock period; tSU;STA and tHD;STA apply
            if self._last_rise is not None and not self._condition_since_rise:
                self._minimum(CheckId.F_SCL, "SCL period", time_fs - self._last_rise, limits.t_period_min_fs, time_fs)
            if self._last_fall is not None:
                self._minimum(CheckId.T_LOW, "SCL low for", time_fs - self._last_fall, limits.t_low_fs, time_fs)
            if self._data_change is not None:
                self._minimum(
                    CheckId.T_SU_DAT,
                    "SDA changed before SCL rose by",
                    time_fs - self._data_change,
                    limits.t_su_dat_fs,
                    time_fs,
                )
            self._data_change = None
            self._last_rise = time_fs
            self._condition_in_high = False
            self._condition_since_rise = False
            if self._busy:
                self._bits += 1
        elif kind is EventKind.FALL:
            if self._start is not None:
                self._minimum(CheckId.T_HD_STA, "START held for", time_fs - self._start, limits.t_hd_sta_fs, time_fs)
                self._start = None
            elif self._last_rise is not None and not self._condition_in_high:
                self._minimum(CheckId.T_HIGH, "SCL high for", time_fs - self._last_rise, limits.t_high_fs, time_fs)
            self._last_fall = time_fs
            self._data_change = None
        elif kind is EventKind.DATA:
            if self._last_fall is not None and self._data_change is None:
                self._minimum(
                    CheckId.T_HD_DAT,
                    "SDA changed after SCL fell by",
                    time_fs - self._last_fall,
                    limits.t_hd_dat_fs,
                    time_fs,
                )
            self._data_change = time_fs
        elif kind is EventKind.START:
            self._condition_in_high = True
            self._condition_since_rise = True
            if self._busy:
                self._check_byte_boundary("repeated START", time_fs)
                if self._last_rise is not None:
                    self._minimum(
                        CheckId.T_SU_STA,
                        "repeated START after SCL rose by",
                        time_fs - self._last_rise,
                        limits.t_su_sta_fs,
                        time_fs,
                    )
            elif self._last_stop is not None:
                self._minimum(CheckId.T_BUF, "bus free for", time_fs - self._last_stop, limits.t_buf_fs, time_fs)
            self._busy = True
            self._bits = 0
            self._start = time_fs
        elif kind is EventKind.STOP:
            self._condition_in_high = True
            self._condition_since_rise = True
            if self._busy:
                self._check_byte_boundary("STOP", time_fs)
            if self._last_rise is not None:
                self._minimum(
                    CheckId.T_SU_STO, "STOP after SCL rose by", time_fs - self._last_rise, limits.t_su_sto_fs, time_fs
                )
            self._busy = False
            self._start = None
            self._last_stop = time_fs

    def _check_byte_boundary(self, condition: str, time_fs: int) -> None:
        # The last rise of SCL belongs to the condition, not to a byte
        if not self._bits:
            return
        bits = (self._bits - 1) % 9
        if bits == 8:
            self._report(
                CheckId.ACK_SLOT, f"{condition} after the 8 bits of a byte, without an acknowledge bit", time_fs
            )
        elif bits:
            self._report(
                CheckId.SDA_STABLE,
                f"SDA changed while SCL was high after {bits} bits of a byte, a {condition} inside the byte",
                time_fs,
            )
