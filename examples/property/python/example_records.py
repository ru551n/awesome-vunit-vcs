# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The dataclass of the generated record example; run.py generates example_records_pkg from it."""

from dataclasses import dataclass
from typing import Annotated

from awesome_vunit_vcs.records import Range


@dataclass(frozen=True)
class Pair:
    a: Annotated[int, Range(0, 255)]
    b: Annotated[int, Range(0, 255)]
