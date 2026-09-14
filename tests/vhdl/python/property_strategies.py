"""Hypothesis strategies used by tests/vhdl/tb_property.vhd."""

from dataclasses import dataclass

from hypothesis import strategies as st


def payloads(max_size: int = 16) -> st.SearchStrategy[list[int]]:
    """Byte values, up to max_size of them."""
    return st.lists(st.integers(0, 255), max_size=max_size)


def lockup_payloads() -> st.SearchStrategy[list[int]]:
    """
    Byte values biased towards the lockup DUT's planted trigger.

    Boundary bytes come up often, so any seed reaches the lockup within a few
    examples; plain integers keep the rest of the space covered.
    """
    return st.lists(st.sampled_from([0x00, 0x0F, 0xF0, 0xFF]) | st.integers(0, 255), max_size=16)


@dataclass(frozen=True)
class Config:
    lanes: int
    enabled: bool


def composite() -> st.SearchStrategy[dict[str, object]]:
    """A record with a dataclass, a list of records and an optional field."""
    return st.fixed_dictionaries(
        {
            "config": st.builds(Config, lanes=st.sampled_from([4, 8]), enabled=st.booleans()),
            "frames": st.lists(
                st.fixed_dictionaries(
                    {"payload": st.binary(min_size=1, max_size=8), "name": st.text("ab", max_size=3)}
                ),
                min_size=1,
                max_size=3,
            ),
            "vlan": st.none() | st.integers(1, 4094),
        }
    )
