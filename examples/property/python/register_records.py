# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
(f) with records: register operations as Python dataclasses.

The dataclasses define the strategy (strategy_for) and, through run.py, the
VHDL records and getters of register_records_pkg, so the testbench reads a
whole sequence with one call.
"""

import enum
from dataclasses import dataclass, replace
from typing import Annotated, Any

from awesome_vunit_vcs.records import Length, Range, strategy_for


# docs-start: register_records
class Kind(enum.Enum):
    """What an operation does."""

    FETCH = 0
    STORE = 1


@dataclass(frozen=True)
class Operation:
    """One register operation; expected is what a fetch must return."""

    kind: Kind
    address: Annotated[int, Range(0, 7)]
    data: Annotated[int, Range(0, 255)]
    expected: Annotated[int, Range(0, 255)] | None = None


@dataclass(frozen=True)
class OperationSequence:
    """Register operations in order."""

    operations: Annotated[list[Operation], Length(max=20)]


def _with_expected(sequence: OperationSequence) -> OperationSequence:
    """The reference model: eight registers reset to 0 give each fetch its expected value."""
    registers = [0] * 8
    operations = []
    for operation in sequence.operations:
        if operation.kind is Kind.STORE:
            registers[operation.address] = operation.data
            operations.append(replace(operation, expected=None))
        else:
            operations.append(replace(operation, expected=registers[operation.address]))
    return OperationSequence(operations)


def register_operation_records() -> Any:
    """Operation sequences with the results of the reference model."""
    return strategy_for(OperationSequence).map(_with_expected)


# docs-end: register_records
