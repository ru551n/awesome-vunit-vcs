# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Unit tests of cookbook_model.py, run with pytest and no simulator."""

# docs-start: unit-test
from cookbook_model import expected_payload_octets, gain_table


def test_gain_table() -> None:
    assert gain_table(4) == [0, 1, 4, 9]


def test_expected_payload_octets() -> None:
    assert expected_payload_octets([60, 100]) == 46 + 86


# docs-end: unit-test
