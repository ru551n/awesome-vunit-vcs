# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
I2C speed modes and their timing: the limits a protocol checker enforces and the times a master drives.

The limits are the minimums of the characteristics table of the I2C-bus
specification (NXP UM10204) for Standard-mode, Fast-mode and Fast-mode Plus.
Times are integers in femtoseconds (fs), frequencies in Hz.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, fields, replace

from .errors import I2cValueError

__all__ = ["BusLimits", "MasterTiming", "SpeedMode", "bus_limits", "master_timing"]

_NS = 1_000_000
_US = 1_000 * _NS


class SpeedMode(enum.IntEnum):
    """The speed modes, numbered like ``i2c_speed_t`` in VHDL."""

    #: Standard-mode, up to 100 kHz
    STANDARD = 0
    #: Fast-mode, up to 400 kHz
    FAST = 1
    #: Fast-mode Plus, up to 1 MHz
    FAST_PLUS = 2

    @classmethod
    def parse(cls, mode: SpeedMode | int | str) -> SpeedMode:
        """
        A speed mode from a member, its number or its name (``"fast"``, ``"FAST_PLUS"``).

        Raises:
            I2cValueError: No such mode.
        """
        if isinstance(mode, SpeedMode):
            return mode
        try:
            if isinstance(mode, int):
                return cls(mode)
            return cls[mode.strip().upper().removesuffix("_MODE")]
        except (KeyError, ValueError):
            raise I2cValueError(f"Unknown I2C speed mode {mode!r}") from None


@dataclass(frozen=True)
class BusLimits:
    """
    The timing a bus must meet, as the protocol checker checks it. Every time is a minimum in fs.

    Attributes:
        f_scl_max_hz: The highest SCL clock frequency, checked as the shortest time between two
            rising edges of SCL.
        t_hd_sta_fs: Hold time of a (repeated) START, from SDA falling to SCL falling.
        t_low_fs: Low period of SCL.
        t_high_fs: High period of SCL.
        t_su_sta_fs: Setup time of a repeated START, from SCL rising to SDA falling.
        t_hd_dat_fs: Data hold time, from SCL falling to a change of SDA.
        t_su_dat_fs: Data setup time, from a change of SDA to SCL rising.
        t_su_sto_fs: Setup time of a STOP, from SCL rising to SDA rising.
        t_buf_fs: Bus free time between a STOP and the next START.
    """

    f_scl_max_hz: int
    t_hd_sta_fs: int
    t_low_fs: int
    t_high_fs: int
    t_su_sta_fs: int
    t_hd_dat_fs: int
    t_su_dat_fs: int
    t_su_sto_fs: int
    t_buf_fs: int

    @property
    def t_period_min_fs(self) -> int:
        """The shortest SCL period, 1 / ``f_scl_max_hz``, rounded up to whole fs."""
        return -(-(10**15) // self.f_scl_max_hz)


@dataclass(frozen=True)
class MasterTiming:
    """
    The times a master drives, in fs. The defaults of each speed mode meet :class:`BusLimits` of that
    mode with the full SCL frequency.

    Attributes:
        t_low_fs: SCL low period.
        t_high_fs: SCL high period.
        t_hd_dat_fs: From SCL falling to driving SDA.
        t_su_sta_fs: From SCL rising to SDA falling for a repeated START.
        t_hd_sta_fs: From SDA falling to SCL falling for a START.
        t_su_sto_fs: From SCL rising to SDA rising for a STOP.
        t_buf_fs: Bus free time the master waits after a STOP before its next START.
    """

    t_low_fs: int
    t_high_fs: int
    t_hd_dat_fs: int
    t_su_sta_fs: int
    t_hd_sta_fs: int
    t_su_sto_fs: int
    t_buf_fs: int


_LIMITS = {
    SpeedMode.STANDARD: BusLimits(
        f_scl_max_hz=100_000,
        t_hd_sta_fs=4_000 * _NS,
        t_low_fs=4_700 * _NS,
        t_high_fs=4_000 * _NS,
        t_su_sta_fs=4_700 * _NS,
        t_hd_dat_fs=0,
        t_su_dat_fs=250 * _NS,
        t_su_sto_fs=4_000 * _NS,
        t_buf_fs=4_700 * _NS,
    ),
    SpeedMode.FAST: BusLimits(
        f_scl_max_hz=400_000,
        t_hd_sta_fs=600 * _NS,
        t_low_fs=1_300 * _NS,
        t_high_fs=600 * _NS,
        t_su_sta_fs=600 * _NS,
        t_hd_dat_fs=0,
        t_su_dat_fs=100 * _NS,
        t_su_sto_fs=600 * _NS,
        t_buf_fs=1_300 * _NS,
    ),
    SpeedMode.FAST_PLUS: BusLimits(
        f_scl_max_hz=1_000_000,
        t_hd_sta_fs=260 * _NS,
        t_low_fs=500 * _NS,
        t_high_fs=260 * _NS,
        t_su_sta_fs=260 * _NS,
        t_hd_dat_fs=0,
        t_su_dat_fs=50 * _NS,
        t_su_sto_fs=260 * _NS,
        t_buf_fs=500 * _NS,
    ),
}

_MASTER = {
    SpeedMode.STANDARD: MasterTiming(
        t_low_fs=5 * _US,
        t_high_fs=5 * _US,
        t_hd_dat_fs=1 * _US,
        t_su_sta_fs=5 * _US,
        t_hd_sta_fs=5 * _US,
        t_su_sto_fs=5 * _US,
        t_buf_fs=5 * _US,
    ),
    SpeedMode.FAST: MasterTiming(
        t_low_fs=1_300 * _NS,
        t_high_fs=1_200 * _NS,
        t_hd_dat_fs=300 * _NS,
        t_su_sta_fs=700 * _NS,
        t_hd_sta_fs=700 * _NS,
        t_su_sto_fs=700 * _NS,
        t_buf_fs=1_300 * _NS,
    ),
    SpeedMode.FAST_PLUS: MasterTiming(
        t_low_fs=500 * _NS,
        t_high_fs=500 * _NS,
        t_hd_dat_fs=100 * _NS,
        t_su_sta_fs=300 * _NS,
        t_hd_sta_fs=300 * _NS,
        t_su_sto_fs=300 * _NS,
        t_buf_fs=500 * _NS,
    ),
}


def _overridden(value: BusLimits | MasterTiming, overrides: dict[str, int | None]) -> dict[str, int]:
    names = {field.name for field in fields(value)}
    unknown = sorted(set(overrides) - names)
    if unknown:
        raise I2cValueError(f"Unknown timing parameters {unknown}, known: {sorted(names)}")
    negative = sorted(name for name, time in overrides.items() if time is not None and time < 0)
    if negative:
        raise I2cValueError(f"Negative timing parameters {negative}")
    return {name: time for name, time in overrides.items() if time}


def bus_limits(mode: SpeedMode | int | str = SpeedMode.STANDARD, **overrides: int | None) -> BusLimits:
    """
    The limits of a speed mode, with some replaced.

    Args:
        mode: The speed mode.
        overrides: Fields of :class:`BusLimits` to replace. 0 and None keep the value of the mode.

    Raises:
        I2cValueError: An unknown mode or field, or a negative value.
    """
    limits = _LIMITS[SpeedMode.parse(mode)]
    return replace(limits, **_overridden(limits, overrides))


def master_timing(mode: SpeedMode | int | str = SpeedMode.STANDARD, **overrides: int | None) -> MasterTiming:
    """
    The times a master drives in a speed mode, with some replaced.

    Args:
        mode: The speed mode.
        overrides: Fields of :class:`MasterTiming` to replace. 0 and None keep the value of the mode.

    Raises:
        I2cValueError: An unknown mode or field, a negative value, or a data hold time not shorter
            than the low period.
    """
    timing = _MASTER[SpeedMode.parse(mode)]
    timing = replace(timing, **_overridden(timing, overrides))
    if timing.t_hd_dat_fs >= timing.t_low_fs:
        raise I2cValueError(f"t_hd_dat_fs={timing.t_hd_dat_fs} must be shorter than t_low_fs={timing.t_low_fs}")
    return timing
