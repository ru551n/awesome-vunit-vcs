# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy of tb_property_getters: a record of integer fields."""

from hypothesis import strategies as st


def fields(count=50):
    return st.fixed_dictionaries({f"field_{idx}": st.integers(0, 255) for idx in range(count)})
