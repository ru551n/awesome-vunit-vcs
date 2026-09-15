# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The Hypothesis strategy of the CDC example: clock-ratio, phase and event timing for a toggle-based
pulse synchronizer (tb_property_cdc.vhd, toggle_synchronizer.vhd).

THIS DOES NOT MODEL ANALOG METASTABILITY. It explores digital issues: the clock relationship, the
destination clock's phase, event loss, duplicate events, reset timing and synchronizer control logic
-- not the analog settling behaviour of a real flip-flop sampling a changing input.
"""

# docs-start: imports
import math
from itertools import accumulate

from hypothesis import strategies as st

# docs-end: imports


# docs-start: toggle_sync
def toggle_sync() -> st.SearchStrategy[dict[str, object]]:
    """
    Source and destination clock periods, the destination clock's phase, and 1 to 6 source-domain
    event cycles. Events are drawn as gaps of at least the minimum legal spacing for the correct
    design -- ceil(3 * dst_period / src_period) + 2 source cycles, the synchronizer's latency plus
    margin -- so a passing run stays legal while shrinking still explores fast source / slow
    destination ratios and events placed close together.
    """
    periods = st.fixed_dictionaries(
        {"src_period_ps": st.integers(2_000, 20_000), "dst_period_ps": st.integers(2_000, 20_000)}
    )

    def with_events(periods: dict[str, int]) -> st.SearchStrategy[dict[str, object]]:
        min_spacing = math.ceil(3 * periods["dst_period_ps"] / periods["src_period_ps"]) + 2
        gaps = st.lists(st.integers(min_spacing, min_spacing + 20), min_size=1, max_size=6)
        events = gaps.map(lambda values: list(accumulate(values)))
        fields: dict[str, st.SearchStrategy[object]] = {
            **{key: st.just(value) for key, value in periods.items()},
            "dst_phase_ps": st.integers(0, periods["dst_period_ps"]),
            "events": events,
        }
        return st.fixed_dictionaries(fields, optional={"reset_release_ps": st.integers(0, periods["dst_period_ps"])})

    return periods.flatmap(with_events)


# docs-end: toggle_sync
