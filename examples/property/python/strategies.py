# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The Hypothesis strategies of the property examples, one function per example."""

from example_records import Pair
from hypothesis import strategies as st

from awesome_vunit_vcs.records import strategy_for

BYTE = st.integers(0, 255)


def scalar():
    return BYTE


def composite():
    return st.fixed_dictionaries({"offset": BYTE, "values": st.lists(BYTE, max_size=8)})


def tagged_union():
    add = st.fixed_dictionaries({"kind": st.just("add"), "a": BYTE, "b": BYTE})
    return add | st.fixed_dictionaries({"kind": st.just("negate"), "value": BYTE})


def _with_expected_reads(operations):
    registers = [0] * 8
    for operation in operations:
        if operation["kind"] == "write":
            registers[operation["address"]] = operation["data"]
        else:
            operation["expected"] = registers[operation["address"]]
    return operations


def sequence():
    write = st.fixed_dictionaries({"kind": st.just("write"), "address": st.integers(0, 7), "data": BYTE})
    read = st.fixed_dictionaries({"kind": st.just("read"), "address": st.integers(0, 7)})
    return st.lists(read | write, max_size=16).map(_with_expected_reads)


def pair():
    return strategy_for(Pair)


def frame_data():
    return st.binary(min_size=60, max_size=128)


def byte_stream():
    return st.lists(st.sampled_from([0x00, 0xFF]) | BYTE, max_size=6)
