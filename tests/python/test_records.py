"""Tests of the record markers, their strategies and the VHDL record generator."""

from __future__ import annotations

import enum
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Optional, Union

import pytest

from awesome_vunit_vcs import __version__
from awesome_vunit_vcs.gen_vhdl import generate_vhdl, vhdl_image, write_vhdl
from awesome_vunit_vcs.records import Choices, Length, Range, RecordError, field_types, strategy_for, validate

GOLDEN = Path(__file__).parent / "golden" / "records_pkg.vhd"


class Mode(enum.Enum):
    """How the link runs."""

    IDLE = 0
    FAST = 1


@dataclass(frozen=True)
class Lane:
    """One lane."""

    index: Annotated[int, Range(0, 7)]
    enabled: bool


@dataclass(frozen=True)
class Link:
    """Every supported field type."""

    lanes_used: Annotated[int, Choices(1, 2, 4, 8)]
    name: Annotated[str, Length(max=6)]
    color: Annotated[str, Choices("red", "green")]
    payload: Annotated[bytes, Length(max=12)]
    offsets: Annotated[list[int], Length(max=5)]
    modes: Annotated[list[Mode], Length(max=3)]
    lanes: Annotated[list[Lane], Length(min=1, max=4)]
    mode: Mode
    primary: Lane
    vlan: Annotated[int, Range(1, 4094)] | None
    backup: Optional[Lane]  # noqa: UP045 - Optional must work as well as T | None


def a_link(**changes: Any) -> Link:
    fields: dict[str, Any] = {
        "lanes_used": 4,
        "name": "eth0",
        "color": "red",
        "payload": b"\x01\x02",
        "offsets": [3, -1],
        "modes": [Mode.FAST],
        "lanes": [Lane(0, True), Lane(1, False)],
        "mode": Mode.IDLE,
        "primary": Lane(2, True),
        "vlan": None,
        "backup": Lane(3, False),
    }
    fields.update(changes)
    return Link(**fields)


# Markers and validation
def test_markers_reject_impossible_bounds() -> None:
    with pytest.raises(RecordError, match="minimum above its maximum"):
        Range(2, 1)
    with pytest.raises(RecordError, match="range of a VHDL integer"):
        Range(0, 2**31)
    with pytest.raises(RecordError, match="0 <= min <= max"):
        Length(max=3, min=4)
    with pytest.raises(RecordError, match="all int or all str"):
        Choices(1, "a")
    with pytest.raises(RecordError, match="at least one value"):
        Choices()


def test_validate_accepts_values_within_bounds() -> None:
    validate(a_link())


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"lanes_used": 3}, r"Link.lanes_used is 3, not one of \(1, 2, 4, 8\)"),
        ({"name": "toolong"}, r"Link.name has length 7, outside Length\(min=0, max=6\)"),
        ({"name": "café"}, "only printable ASCII"),
        ({"lanes": []}, r"Link.lanes has length 0, outside Length\(min=1, max=4\)"),
        ({"primary": Lane(8, True)}, r"Lane.index is 8, outside Range\(0, 7\)"),
        ({"vlan": 0}, r"Link.vlan is 0, outside Range\(1, 4094\)"),
        ({"mode": 1}, "not a <enum 'Mode'>"),
    ],
)
def test_validate_names_the_field_out_of_bounds(changes: dict[str, Any], message: str) -> None:
    with pytest.raises(RecordError, match=message):
        validate(a_link(**changes))


def test_strategy_draws_only_valid_values() -> None:
    hypothesis = pytest.importorskip("hypothesis")

    @hypothesis.settings(max_examples=150, deadline=None, database=None)
    @hypothesis.given(strategy_for(Link))
    def check(link: Link) -> None:
        validate(link)
        assert link.lanes_used in (1, 2, 4, 8)
        assert 1 <= len(link.lanes) <= 4

    check()


# Unsupported types
@dataclass(frozen=True)
class WithFloat:
    speed: float


@dataclass(frozen=True)
class WithUnboundedStr:
    name: str


@dataclass(frozen=True)
class WithUnboundedList:
    items: list[int]


@dataclass(frozen=True)
class WithUnion:
    value: Union[int, str]  # noqa: UP007


@dataclass(frozen=True)
class WithDict:
    table: dict[str, int]


@dataclass(frozen=True)
class WithTuple:
    pair: tuple[int, int]


@dataclass(frozen=True)
class WithListOfStr:
    names: Annotated[list[Annotated[str, Length(max=4)]], Length(max=2)]


@dataclass(frozen=True)
class WithMisplacedMarker:
    flag: Annotated[bool, Range(0, 1)]


@dataclass(frozen=True)
class WithReservedField:
    range: Annotated[int, Range(0, 3)]


class Direction(enum.Enum):
    IN = 0
    OUT = 1


@dataclass(frozen=True)
class WithReservedEnumMember:
    direction: Direction


@dataclass(frozen=True)
class WithLengthCollision:
    items: Annotated[bytes, Length(max=2)]
    items_length: Annotated[int, Range(0, 2)]


@dataclass(frozen=True)
class Integer:
    value: int


@pytest.mark.parametrize(
    ("cls", "message"),
    [
        (WithFloat, "WithFloat.speed: float is not supported"),
        (WithUnboundedStr, r"WithUnboundedStr.name: a str field needs Length\(max=...\) or Choices"),
        (WithUnboundedList, r"WithUnboundedList.items: a list field needs Length\(max=...\)"),
        (WithUnion, "is a union; only Optional"),
        (WithDict, "WithDict.table: dict is not supported"),
        (WithTuple, "WithTuple.pair: tuple is not supported"),
        (WithListOfStr, "list items of kind str are not supported"),
        (WithMisplacedMarker, "Range does not apply to a bool field"),
    ],
)
def test_unsupported_field_types_name_the_field(cls: type, message: str) -> None:
    with pytest.raises(RecordError, match=message):
        field_types(cls)
    with pytest.raises(RecordError, match=message):
        generate_vhdl([cls], "records_pkg")


@pytest.mark.parametrize(
    ("cls", "message"),
    [
        (WithReservedField, "Field WithReservedField.range 'range' is a VHDL reserved word"),
        (WithReservedEnumMember, "Member IN of Direction 'IN' is a VHDL reserved word"),
        (WithLengthCollision, "WithLengthCollision.items_length generates items_length, which"),
        (Integer, "would generate get_integer, which property_pkg already has"),
    ],
)
def test_names_that_cannot_be_generated(cls: type, message: str) -> None:
    with pytest.raises(RecordError, match=re.escape(message) if "(" in message else message):
        generate_vhdl([cls], "records_pkg")


def test_invalid_package_name() -> None:
    with pytest.raises(RecordError, match="not a valid VHDL identifier"):
        generate_vhdl([Lane], "records-pkg")


# Generation
def _normalized(text: str) -> str:
    return text.replace(__version__, "<version>")


def test_generated_package_matches_the_golden_file() -> None:
    """Regenerate with UPDATE_GOLDEN=1 after a deliberate change of the generator."""
    text = _normalized(generate_vhdl([Link], "records_pkg"))
    if __import__("os").environ.get("UPDATE_GOLDEN"):
        GOLDEN.parent.mkdir(exist_ok=True)
        GOLDEN.write_text(text, encoding="utf-8")
    assert text == GOLDEN.read_text(encoding="utf-8")


def test_generated_package_declares_dependencies_first() -> None:
    text = generate_vhdl([Link], "records_pkg")
    assert text.index("type mode_t") < text.index("type lane_t") < text.index("type link_lanes_array_t")
    assert text.index("type link_lanes_array_t") < text.index("type link_t")
    assert "-- Generated by awesome_vunit_vcs.gen_vhdl" in text.splitlines()[0]


def test_write_vhdl_only_writes_changes(tmp_path: Path) -> None:
    target = tmp_path / "generated" / "records_pkg.vhd"
    assert write_vhdl([Lane], "records_pkg", target)
    assert not write_vhdl([Lane], "records_pkg", target)
    assert write_vhdl([Link], "records_pkg", target)


def test_vhdl_image() -> None:
    link = a_link()
    assert vhdl_image(link) == (
        '(lanes_used => 4, name => "eth0", color => "red", payload => (1, 2), offsets => (3, -1), '
        "modes => (fast), lanes => ((index => 0, enabled => true), (index => 1, enabled => false)), mode => idle, "
        "primary => (index => 2, enabled => true), vlan => none, backup => (index => 3, enabled => false))"
    )


def test_command_line(tmp_path: Path) -> None:
    (tmp_path / "cli_types.py").write_text(
        "from dataclasses import dataclass\n"
        "from typing import Annotated\n"
        "from awesome_vunit_vcs.records import Range\n\n"
        "@dataclass(frozen=True)\nclass Point:\n    x: Annotated[int, Range(0, 9)]\n"
        "    y: Annotated[int, Range(0, 9)]\n"
    )
    output = tmp_path / "points_pkg.vhd"
    command = [sys.executable, "-m", "awesome_vunit_vcs.gen_vhdl", "cli_types:Point", "--package", "points_pkg"]
    subprocess.run([*command, "--output", str(output), "--search-path", str(tmp_path)], check=True)
    assert "type point_t is record" in output.read_text()

    failed = subprocess.run(
        [*command[:4], "cli_types:Missing", "--package", "points_pkg", "--search-path", str(tmp_path)],
        capture_output=True,
        text=True,
    )
    assert failed.returncode == 1
    assert "has no attribute 'Missing'" in failed.stderr
