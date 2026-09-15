# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy of tb_property_fifo.vhd."""

from hypothesis import strategies as st


# docs-start: operations
def fifo_operations() -> st.SearchStrategy[list[str]]:
    """Up to 32 clock cycles, each a push, a pop or both at once"""
    return st.lists(st.sampled_from(["push", "pop", "push_pop"]), max_size=32)


# docs-end: operations
