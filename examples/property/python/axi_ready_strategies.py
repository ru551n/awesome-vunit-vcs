# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy of the AXI4-Stream TREADY fork example, tb_property_axi_ready."""

# docs-start: ready-fork
from hypothesis import strategies as st

MAX_IDLE_CYCLES = 3


@st.composite
def _ready_fork(draw: st.DrawFn) -> dict[str, int | str]:
    # One word, loaded after some idle cycles
    data = draw(st.integers(0, 255))
    idle = draw(st.integers(0, MAX_IDLE_CYCLES))
    # Where the one-cycle TREADY fork goes. TVALID is low in both places, so no
    # transfer can happen in the fork cycle:
    #   before_load:    nothing is pending yet
    #   pending_window: the word is pending, and TVALID has not risen yet
    # The offset is drawn in both cases, so a shrink can switch the case alone
    case = draw(st.sampled_from(["before_load", "pending_window"]))
    offset = draw(st.integers(0, MAX_IDLE_CYCLES))
    fork = min(offset, idle) if case == "before_load" else idle + 1
    # How many cycles to watch after the fork
    window = draw(st.integers(3, 6))
    return {"data": data, "idle": idle, "case": case, "fork": fork, "window": window}


def ready_fork() -> st.SearchStrategy[dict[str, int | str]]:
    return _ready_fork()


# docs-end: ready-fork
