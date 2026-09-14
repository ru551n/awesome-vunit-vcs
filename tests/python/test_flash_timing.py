# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Busy timing: the deadline model, per-op overrides, and the global
enable. All times are integer femtoseconds."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash.config import BUSY_KEYS, DEFAULT_BUSY_FS
from awesome_vunit_vcs.flash.errors import FlashValueError
from awesome_vunit_vcs.flash.timing import Timing

NS = 10**6
US = 10**9
MS = 10**12
SEC = 10**15


@pytest.fixture
def timing() -> Timing:
    return Timing(DEFAULT_BUSY_FS)


def test_every_contract_key_is_present(timing: Timing) -> None:
    assert BUSY_KEYS == (
        "tPP",
        "tSE",
        "tBE32",
        "tBE64",
        "tCE",
        "tW",
        "tRST",
        "tRES1",
        "tRES2",
    )
    for key in BUSY_KEYS:
        assert timing.busy_fs(key) > 0
        assert isinstance(timing.busy_fs(key), int)


def test_busy_is_a_deadline_not_a_flag(timing: Timing) -> None:
    duration = timing.start_busy(SEC, "tPP")
    assert duration == 700 * US
    assert timing.deadline_fs() == SEC + 700 * US
    assert timing.is_busy(SEC)
    assert timing.is_busy(SEC + 699 * US)
    # The deadline is exclusive: at exactly the deadline the device is free.
    assert timing.is_busy(SEC + duration - 1)
    assert not timing.is_busy(SEC + duration)
    assert not timing.is_busy(2 * SEC)
    # Asking twice does not consume anything -- nothing is stateful but t.
    assert timing.is_busy(SEC + 100 * US)


def test_a_later_command_rearms_from_its_own_now(timing: Timing) -> None:
    timing.start_busy(0, "tPP")
    timing.start_busy(5 * SEC, "tSE")
    assert timing.is_busy(5 * SEC + 44 * MS)
    assert not timing.is_busy(5 * SEC + 100 * MS)


def test_override_one_op(timing: Timing) -> None:
    timing.set_busy("tSE", NS)
    assert timing.start_busy(0, "tSE") == NS
    assert timing.busy_fs("tPP") == 700 * US  # untouched


def test_override_rejects_unknown_names_and_negative_times(timing: Timing) -> None:
    with pytest.raises(FlashValueError):
        timing.set_busy("tPp", US)
    with pytest.raises(FlashValueError):
        timing.set_busy("tERASE", US)
    with pytest.raises(ValueError):
        timing.set_busy("tPP", -US)


def test_disable_collapses_every_single_op(timing: Timing) -> None:
    timing.set_busy("tCE", 60 * SEC)
    timing.set_enable(False)
    assert timing.enabled is False
    for key in BUSY_KEYS:
        assert timing.busy_fs(key) == 0
        assert timing.start_busy(0, key) == 0
        assert not timing.is_busy(0)


def test_enable_restores_the_table_including_overrides(timing: Timing) -> None:
    timing.set_busy("tPP", MS)
    timing.set_enable(False)
    assert timing.start_busy(0, "tPP") == 0
    timing.set_enable(True)
    assert timing.start_busy(0, "tPP") == MS


def test_timing_can_start_disabled() -> None:
    timing = Timing(DEFAULT_BUSY_FS, enabled=False)
    assert timing.enabled is False
    assert timing.start_busy(0, "tCE") == 0
    timing.set_enable(True)
    assert timing.start_busy(0, "tCE") == 20 * SEC


def test_a_command_with_no_busy_key_never_arms_the_deadline(timing: Timing) -> None:
    timing.start_busy(0, "tCE")
    assert timing.is_busy(SEC)
    assert timing.busy_fs(None) == 0


def test_end_busy_cuts_a_running_deadline_short(timing: Timing) -> None:
    timing.start_busy(0, "tCE")
    timing.end_busy(SEC)
    assert timing.deadline_fs() == SEC
    assert not timing.is_busy(SEC)
    assert timing.is_busy(SEC - 1), "only ended from that time on"


def test_end_busy_never_extends_a_deadline(timing: Timing) -> None:
    timing.start_busy(0, "tPP")
    timing.end_busy(SEC)
    assert timing.deadline_fs() == 700 * US


def test_clear_busy_drops_the_deadline(timing: Timing) -> None:
    timing.start_busy(0, "tCE")
    timing.clear_busy()
    assert timing.deadline_fs() == 0
    assert not timing.is_busy(0)


def test_the_table_is_copied_not_aliased() -> None:
    busy = dict(DEFAULT_BUSY_FS)
    timing = Timing(busy)
    busy["tPP"] = 1
    timing.set_busy("tSE", 1)
    assert timing.busy_fs("tPP") == 700 * US
    assert busy["tSE"] == 45 * MS


def test_a_table_missing_a_busy_key_is_rejected() -> None:
    busy = dict(DEFAULT_BUSY_FS)
    del busy["tRES2"]
    with pytest.raises(ValueError, match="tRES2"):
        Timing(busy)
