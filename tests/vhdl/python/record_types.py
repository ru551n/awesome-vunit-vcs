"""Dataclasses of tests/vhdl/tb_records.vhd, covering every field type the VHDL record generator supports."""

import enum
from dataclasses import dataclass
from typing import Annotated, Any

from awesome_vunit_vcs.gen_vhdl import vhdl_image
from awesome_vunit_vcs.records import Choices, Length, Range, strategy_for


class Mode(enum.Enum):
    """How the link runs."""

    IDLE = 0
    FAST = 1
    SLOW = 2


@dataclass(frozen=True)
class Lane:
    """One lane of a link."""

    index: Annotated[int, Range(0, 7)]
    enabled: bool


@dataclass(frozen=True)
class Link:
    """Every supported field type."""

    lanes_used: Annotated[int, Choices(1, 2, 4, 8)]
    rate: Annotated[int, Range(-100, 100)]
    name: Annotated[str, Length(max=6)]
    color: Annotated[str, Choices("red", "green")]
    payload: Annotated[bytes, Length(max=12)]
    offsets: Annotated[list[int], Length(max=5)]
    flags: Annotated[list[bool], Length(max=3)]
    modes: Annotated[list[Mode], Length(max=3)]
    lanes: Annotated[list[Lane], Length(min=1, max=4)]
    mode: Mode
    primary: Lane
    vlan: Annotated[int, Range(1, 4094)] | None
    backup: Lane | None
    tag: Annotated[bytes, Length(max=4)] | None


def links() -> Any:
    """A generated Link and the text its VHDL record must show."""
    return strategy_for(Link).map(lambda link: {"value": link, "image": vhdl_image(link)})


def lanes_only() -> Any:
    """A Lane at the top of the example, read with the empty path."""
    # Hypothesis is imported here, so run.py can import the dataclasses without it
    from hypothesis import strategies as st

    return st.builds(Lane, index=st.integers(0, 7), enabled=st.booleans())
