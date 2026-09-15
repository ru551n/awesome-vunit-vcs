# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Recursive, grammar-based generation of arithmetic expression trees, with structural shrinking."""

from hypothesis import strategies as st

# All arithmetic wraps modulo 256 (8-bit unsigned), matching the VHDL stack machine's natural
# unsigned overflow.


def _evaluate(tree):
    op = tree["op"]
    if op == "const":
        return tree["value"] % 256
    if op == "negate":
        return (-_evaluate(tree["operand"])) % 256
    left = _evaluate(tree["left"])
    right = _evaluate(tree["right"])
    return (left + right) % 256 if op == "add" else (left - right) % 256


def _serialize(tree, program):
    op = tree["op"]
    if op == "const":
        program.append({"op": "const", "value": tree["value"]})
    elif op == "negate":
        _serialize(tree["operand"], program)
        program.append({"op": "negate", "value": 0})
    else:
        _serialize(tree["left"], program)
        _serialize(tree["right"], program)
        program.append({"op": op, "value": 0})


def _to_example(tree):
    program = []
    _serialize(tree, program)
    return {"tree": tree, "program": program, "expected": _evaluate(tree)}


# docs-start: expressions
def expressions():
    # Grammar: const(value) | add(e, e) | subtract(e, e) | negate(e); up to 8 leaves, so the
    # stack machine's depth-8 stack always suffices for the postfix program
    leaves = st.integers(0, 15).map(lambda value: {"op": "const", "value": value})

    def extend(child):
        binary = st.tuples(st.sampled_from(["add", "subtract"]), child, child).map(
            lambda t: {"op": t[0], "left": t[1], "right": t[2]}
        )
        unary = child.map(lambda operand: {"op": "negate", "operand": operand})
        return binary | unary

    return st.recursive(leaves, extend, max_leaves=8).map(_to_example)


# docs-end: expressions
