# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy for the targeted FIFO occupancy property, tb_property_fifo.vhd."""

from hypothesis import strategies as st

# docs-start: operations
BYTE = st.integers(0, 255)


def operations():
    # A bounded sequence of per-cycle push/pop operations. The testbench scores
    # each example on how far it drives the FIFO's occupancy, so Hypothesis
    # steers generation towards sequences that reach full and wraparound
    # instead of the mostly-empty sequences a plain random search finds.
    operation = st.fixed_dictionaries({"push": st.booleans(), "pop": st.booleans(), "data": BYTE})
    return st.lists(operation, max_size=24)


# docs-end: operations
