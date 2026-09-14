# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Hypothesis strategies of the property-based testing examples.

A strategy is a plain function returning a Hypothesis strategy; the testbench
names it as ``"property_examples:<function>"`` and reads the drawn example
through paths such as ``"config.limit"`` or ``"(2).kind"``.
"""

from typing import Any

from hypothesis import strategies as st

BYTE = st.integers(0, 255)


# docs-start: integer
def any_16_bit_value() -> st.SearchStrategy[int]:
    """(a) A single integer: every 16-bit value."""
    return st.integers(0, 2**16 - 1)


# docs-end: integer


# docs-start: record
def counter_config() -> st.SearchStrategy[dict[str, Any]]:
    """(b) A record: the configuration of the wrap counter and how long to run it."""
    return st.fixed_dictionaries(
        {
            "config": st.fixed_dictionaries(
                {"limit": st.integers(1, 255), "step": st.integers(1, 15), "enable": st.booleans()}
            ),
            "cycles": st.integers(0, 64),
        }
    )


# docs-end: record


# docs-start: byte_vectors
def packets() -> st.SearchStrategy[list[bytes]]:
    """(c) A list of variable-length byte vectors."""
    return st.lists(st.binary(min_size=1, max_size=32), min_size=1, max_size=8)


# docs-end: byte_vectors


# docs-start: tagged_union
def alu_operation() -> st.SearchStrategy[dict[str, Any]]:
    """(d) A tagged union: one ALU operation, each kind with its own fields."""
    return st.one_of(
        st.fixed_dictionaries({"kind": st.just("add"), "a": BYTE, "b": BYTE}),
        st.fixed_dictionaries({"kind": st.just("shift"), "value": BYTE, "amount": st.integers(0, 7)}),
        st.fixed_dictionaries({"kind": st.just("compare"), "a": BYTE, "b": BYTE}),
    )


# docs-end: tagged_union


# docs-start: operations
def _with_expected_reads(operations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The reference model: eight registers, reset to 0. Each read gets the value it must return."""
    registers = [0] * 8
    checked = []
    for operation in operations:
        if operation["kind"] == "write":
            registers[operation["address"]] = operation["data"]
            checked.append(operation)
        else:
            checked.append({**operation, "expected": registers[operation["address"]]})
    return checked


def register_operations() -> st.SearchStrategy[list[dict[str, Any]]]:
    """(f) A sequence of register writes and reads with the results of the reference model."""
    address = st.integers(0, 7)
    operation = st.one_of(
        st.fixed_dictionaries({"kind": st.just("read"), "address": address}),
        st.fixed_dictionaries({"kind": st.just("write"), "address": address, "data": BYTE}),
    )
    return st.lists(operation, max_size=20).map(_with_expected_reads)


# docs-end: operations
