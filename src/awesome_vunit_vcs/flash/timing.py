# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Busy time: how long the device holds WIP after a program or erase.

It is modelled as a *deadline*, not a flag: ``cs_deassert`` computes
``deadline = now + duration`` and every later query derives
``WIP = now < deadline``. There is no busy flag anywhere in the model.

Why a deadline and not a flag: the Python model has no clock. It only ever
learns the time when VHDL tells it, and VHDL only calls at CS edges and
byte boundaries. A flag would have to be cleared by *someone*, and there is
no one -- the only honest representation of "busy until t" is t. It also
makes the model immune to the testbench polling at arbitrary times, and
makes ``set_enable(False)`` a one-line change of semantics (every duration
becomes 0, so every deadline is already in the past) instead of a special
case threaded through the state machine.

All times are integer femtoseconds.
"""

from __future__ import annotations

from collections.abc import Mapping

from .config import BUSY_KEYS

__all__ = ["BUSY_KEYS", "Timing"]


class Timing:
    """Busy-time table and the WIP deadline for one device instance."""

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
        Override one busy time. Unknown names raise: a typo'd override that
        silently did nothing would be indistinguishable from a model bug.
        """
        if name not in self._busy:
            raise KeyError(f"unknown timing name {name!r}; known: {list(BUSY_KEYS)}")
        if duration_fs < 0:
            raise ValueError(f"timing {name} must not be negative (got {duration_fs} fs)")
        self._busy[name] = int(duration_fs)

    def set_enable(self, enable: bool) -> None:
        """
        ``False`` collapses every busy time to zero. For the common test that
        cares about protocol, not milliseconds -- and it must collapse *all*
        of them, so no test can accidentally depend on one op still being slow.
        """
        self.enabled = bool(enable)

    def busy_fs(self, name: str | None) -> int:
        if name is None or not self.enabled:
            return 0
        return self._busy[name]

    # -- the deadline ------------------------------------------------------

    def start_busy(self, now_fs: int, name: str | None) -> int:
        """
        Arm the WIP deadline and return the duration the VC should expect. A
        zero duration leaves the deadline in the past, so WIP is never
        observed -- no special case needed.
        """
        duration = self.busy_fs(name)
        self._deadline_fs = now_fs + duration
        return duration

    def is_busy(self, now_fs: int) -> bool:
        """WIP, derived rather than stored."""
        return now_fs < self._deadline_fs

    def deadline_fs(self) -> int:
        return self._deadline_fs

    def clear_busy(self) -> None:
        """Used by a reset, which aborts whatever was in progress."""
        self._deadline_fs = 0
