# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy for the targeted FIFO occupancy property, tb_property_fifo.vhd."""

from hypothesis import strategies as st

from awesome_vunit_vcs.common.property import pin

# docs-start: operations
BYTE = st.integers(0, 255)


# Confirmed minimal: 4 pushes reach full, then a simultaneous push+pop drops
# the pushed word. Pinning it keeps the counterexample this small: Hypothesis's
# generic list shrinker reliably finds *a* failure here but, for a strategy of
# mostly-independent booleans, does not always delete every removable no-op
# element from its front, so a couple of harmless {push: False, pop: False}
# steps can survive an unpinned shrink even though this 5-step sequence alone
# already fails every time.
@pin(
    [
        {"push": True, "pop": False, "data": 0},
        {"push": True, "pop": False, "data": 0},
        {"push": True, "pop": False, "data": 0},
        {"push": True, "pop": False, "data": 0},
        {"push": True, "pop": True, "data": 0},
    ]
)
def operations():
    # A bounded sequence of per-cycle push/pop operations. The testbench scores
    # each example on how far it drives the FIFO's occupancy, so Hypothesis
    # steers generation towards sequences that reach full and wraparound
    # instead of the mostly-empty sequences a plain random search finds.
    operation = st.fixed_dictionaries({"push": st.booleans(), "pop": st.booleans(), "data": BYTE})
    return st.lists(operation, max_size=24)


# docs-end: operations
