# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The Hypothesis strategies of the property examples, one function per example."""

from example_records import Pair
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, rule

from awesome_vunit_vcs.common.property import pin, step
from awesome_vunit_vcs.records import strategy_for

BYTE = st.integers(0, 255)


def scalar():
    return BYTE


def composite():
    return st.fixed_dictionaries({"offset": BYTE, "values": st.lists(BYTE, max_size=8)})


def tagged_union():
    add = st.fixed_dictionaries({"kind": st.just("add"), "a": BYTE, "b": BYTE})
    return add | st.fixed_dictionaries({"kind": st.just("negate"), "value": BYTE})


class Registers(RuleBasedStateMachine):
    """A reference model of the register bank: a read returns the last write."""

    def __init__(self):
        super().__init__()
        self.model = [0] * 8

    @rule(address=st.integers(0, 7), data=BYTE)
    def write(self, address, data):
        step("write", address=address, data=data)
        self.model[address] = data

    @rule(address=st.integers(0, 7))
    def read(self, address):
        assert step("read", address=address) == self.model[address]


def registers():
    return Registers


def timed_writes():
    # Data and idle cycles are drawn apart, so a failure shrinks each on its own
    idle = st.lists(st.integers(0, 3), min_size=8, max_size=8)
    return st.fixed_dictionaries({"data": st.lists(BYTE, min_size=1, max_size=8), "idle": idle})


def swarm():
    # Each example enables a random subset of the operations, then draws only those
    def operations(kinds):
        operation = st.fixed_dictionaries({"kind": st.sampled_from(sorted(kinds)), "a": BYTE, "b": BYTE})
        return st.lists(operation, max_size=8)

    return st.sets(st.sampled_from(["add", "subtract"]), min_size=1).flatmap(operations)


def pair():
    return strategy_for(Pair)


def frame_data():
    return st.binary(min_size=60, max_size=128)


def backpressure():
    return st.fixed_dictionaries(
        {"frame": frame_data(), "ready_high_percent": st.integers(10, 100), "seed": st.integers(0, 1000)}
    )


# docs-start: pin
@pin([255, 0])  # the lockup found once, always tried first
def byte_stream():
    return st.lists(st.sampled_from([0x00, 0xFF]) | BYTE, max_size=6)


# docs-end: pin
