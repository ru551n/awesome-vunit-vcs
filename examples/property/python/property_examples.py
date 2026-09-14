# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Hypothesis strategies of the property-based testing examples.

A strategy is a plain function returning a Hypothesis strategy; the testbench
names it as ``"property_examples:<function>"`` and reads the drawn example
through paths such as ``"config.limit"`` or ``"(2).kind"``.
"""

from dataclasses import replace
from typing import Any

from hypothesis import strategies as st

from awesome_vunit_vcs import ethernet as eth

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


# docs-start: ethernet
#: The malformations of the example. GIANT is a frame property rather than a wire
#: option, and BAD_SFD is left out while expected_violations mispredicts the gap
#: check of the frame after a bad SFD.
MALFORMATIONS = sorted(
    eth.supported_malformations(eth.GMII) - {eth.Malformation.GIANT, eth.Malformation.BAD_SFD},
    key=lambda kind: kind.value,
)


def _describe_traffic(traffic: list[tuple[eth.Frame, eth.Malformation | None, int]]) -> dict[str, Any]:
    """What the testbench sends, frame by frame, and the violations the protocol checker must count."""
    frames = []
    expected: dict[str, int] = {}
    previous = None
    for frame, kind, ifg_octets in traffic:
        options = eth.WireOptions.malformed(kind) if kind else eth.WireOptions()
        if kind is not eth.Malformation.SHORT_IFG:
            options = replace(options, ifg_octets=ifg_octets)
        for check in eth.expected_violations(frame, options, interface=eth.GMII, previous=previous):
            expected[check.value.lower()] = expected.get(check.value.lower(), 0) + 1
        frames.append(
            {
                "data": frame.octets[:-4],  # destination address to payload; the source adds the FCS
                "fcs": "bad" if options.fcs == "bad" else "append",
                "pad": options.pad,
                "preamble_octets": options.preamble_octets,
                "ifg_octets": options.ifg_octets,
                "errors": list(options.errors),
            }
        )
        previous = options
    return {"frames": frames, "expected": expected}


def ethernet_traffic() -> st.SearchStrategy[dict[str, Any]]:
    """(e) Composite Ethernet traffic: frames, each maybe malformed, and the checks that must fire."""
    frame = st.builds(
        eth.Frame.from_payload,
        st.binary(min_size=1, max_size=64),
        dst=st.binary(min_size=6, max_size=6),
        ethertype=st.integers(0x0600, 0xFFFF),
    )
    item = st.tuples(frame, st.none() | st.sampled_from(MALFORMATIONS), st.integers(12, 20))
    return st.lists(item, min_size=1, max_size=4).map(_describe_traffic)


# docs-end: ethernet
