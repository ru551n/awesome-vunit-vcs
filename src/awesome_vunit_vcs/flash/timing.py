# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Busy time: how long the device holds WIP after a program, erase, status write, reset or power-down release.

It is modelled as a *deadline*, not a flag: ``cs_deassert`` computes
``deadline = now + duration`` and every later query derives
``WIP = now < deadline``. There is no busy flag anywhere in the model.

Why a deadline and not a flag: the Python model has no clock. It only ever
learns the time when VHDL tells it, and VHDL only calls at CS edges and
byte boundaries. A flag would have to be cleared by *someone*, and there is
no one -- the only honest representation of "busy until t" is t. It also
makes the model immune to the testbench polling at arbitrary times, and
makes ``set_enable(False)`` a one-line change of semantics (every duration
armed afterwards is 0, so its deadline is already in the past) instead of a
special case threaded through the state machine.

All times are integer femtoseconds (fs).
"""

from __future__ import annotations

from collections.abc import Mapping

from .config import BUSY_KEYS

__all__ = ["BUSY_KEYS", "Timing"]


class Timing:
    """
    Busy-time table and the WIP deadline for one device instance.

    Args:
        busy_fs: Busy time in fs of every name in
            :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`. Other keys are
            ignored.
        enabled: Whether busy times apply, see :meth:`set_enable`.

    Attributes:
        enabled: Whether busy times apply. When False every busy time is 0.

    Raises:
        ValueError: ``busy_fs`` is missing a name of
            :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`.
    """

    def __init__(self, busy_fs: Mapping[str, int], *, enabled: bool = True) -> None:
        missing = [key for key in BUSY_KEYS if key not in busy_fs]
        if missing:
            raise ValueError(f"the busy time table is missing: {missing}")
        self._busy = {key: int(busy_fs[key]) for key in BUSY_KEYS}
        self.enabled = bool(enabled)
        self._deadline_fs = 0

    # -- table -------------------------------------------------------------

    def set_busy(self, name: str, duration_fs: int) -> None:
        """
        Override one busy time.

        Unknown names raise: a typo'd override that silently did nothing would
        be indistinguishable from a model bug. The new time applies to busy
        periods started afterwards; a running one keeps its deadline.

        Args:
            name: A name of :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`.
            duration_fs: The busy time in fs.

        Raises:
            KeyError: ``name`` is not a busy-time name.
            ValueError: ``duration_fs`` is negative.
        """
        if name not in self._busy:
            raise KeyError(f"unknown timing name {name!r}; known: {list(BUSY_KEYS)}")
        if duration_fs < 0:
            raise ValueError(f"timing {name} must not be negative (got {duration_fs} fs)")
        self._busy[name] = int(duration_fs)

    def set_enable(self, enable: bool) -> None:
        """
        Enable or disable busy times.

        ``False`` collapses every busy time to zero. For the common test that
        cares about protocol, not milliseconds -- and it must collapse *all*
        of them, so no test can accidentally depend on one op still being
        slow. A deadline armed before the call is kept, so a device that is
        already busy stays busy until that deadline.

        Args:
            enable: True to apply the busy times, False to use 0 for all of them.
        """
        self.enabled = bool(enable)

    def busy_fs(self, name: str | None) -> int:
        """
        The busy time a command would start.

        Args:
            name: A name of :data:`~awesome_vunit_vcs.flash.config.BUSY_KEYS`,
                or None for a command that does not go busy.

        Returns:
            The busy time in fs, 0 for None or when busy times are disabled.

        Raises:
            KeyError: ``name`` is not a busy-time name and busy times are enabled.
        """
        if name is None or not self.enabled:
            return 0
        return self._busy[name]

    # -- the deadline ------------------------------------------------------

    def start_busy(self, now_fs: int, name: str | None) -> int:
        """
        Arm the WIP deadline and return the duration the VC should expect.

        A zero duration leaves the deadline in the past, so WIP is never
        observed -- no special case needed. The new deadline replaces any
        earlier one.

        Args:
            now_fs: The current simulation time in fs.
            name: The busy-time name, or None for no busy time.

        Returns:
            The busy time in fs, see :meth:`busy_fs`.
        """
        duration = self.busy_fs(name)
        self._deadline_fs = now_fs + duration
        return duration

    def is_busy(self, now_fs: int) -> bool:
        """
        WIP, derived rather than stored.

        Args:
            now_fs: The simulation time in fs to evaluate WIP at.

        Returns:
            True while ``now_fs`` is before the deadline.
        """
        return now_fs < self._deadline_fs

    def deadline_fs(self) -> int:
        """
        The WIP deadline.

        Returns:
            The simulation time in fs at which WIP clears, 0 before the first
            busy period and after :meth:`clear_busy`.
        """
        return self._deadline_fs

    def clear_busy(self) -> None:
        """Clear WIP immediately. Used by a reset, which aborts whatever was in progress."""
        self._deadline_fs = 0
