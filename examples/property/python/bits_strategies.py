# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The Hypothesis strategies of the bit-pattern examples, one function per example."""

from bit_patterns import interesting_unsigned
from hypothesis import strategies as st

WIDTH = 16


# docs-start: differential_popcount
def differential_popcount():
    # One hardware-aware 16-bit pattern, fed to both popcount implementations
    return interesting_unsigned(WIDTH)


# docs-end: differential_popcount


# docs-start: roundtrip_pack
def roundtrip_pack():
    # The fields of the packed record, drawn independently
    return st.fixed_dictionaries(
        {
            "opcode": st.integers(0, 15),
            "flag": st.integers(0, 1),
            "address": st.integers(0, 63),
            "value": st.integers(0, 31),
        }
    )


# docs-end: roundtrip_pack
