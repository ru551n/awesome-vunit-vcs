# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Python functions that tb_cookbook.vhd calls: a lookup table and a reference model."""


# docs-start: helper
def gain_table(length: int) -> list[int]:
    """The squares 0, 1, 4, 9, ... as a lookup table."""
    return [index * index for index in range(length)]


# docs-end: helper


# docs-start: model
def expected_payload_octets(frame_sizes: list[int]) -> int:
    """What the DUT should report: the payload octets of frames of these sizes, without headers."""
    return sum(size - 14 for size in frame_sizes)


# docs-end: model
