"""
Typed records for property-based tests.

One frozen dataclass describes the data of a property: its fields and their
bounds give the Hypothesis strategy (:func:`strategy_for`), the validation of
values (:func:`validate`) and, through :mod:`awesome_vunit_vcs.gen_vhdl`, a VHDL
record with a getter that reads an example into it.

Bounds are given with :class:`typing.Annotated` and the markers of this module::

    @dataclass(frozen=True)
    class Config:
        lanes: Annotated[int, Choices(4, 8)]
        rate: Annotated[int, Range(1, 100)]
        payload: Annotated[bytes, Length(max=64)]
        mode: Mode                              # an Enum
        vlan: Annotated[int, Range(1, 4094)] | None = None

Supported field types:

* ``bool``
* ``int``, bounded by :class:`Range` or :class:`Choices`; without a marker the
  range of a VHDL integer
* ``str`` with :class:`Length` or :class:`Choices`, printable ASCII
* ``bytes`` with :class:`Length`
* an :class:`enum.Enum`
* another dataclass
* ``list[T]`` with :class:`Length`, where ``T`` is ``bool``, ``int``, an
  :class:`enum.Enum` or a dataclass
* ``T | None`` (``Optional[T]``) of any of the above

Anything else raises :class:`RecordError` naming the class and the field.
Hypothesis is imported only by :func:`strategy_for`; the package does not
depend on it.
"""

from __future__ import annotations

import dataclasses
import enum
import types
import typing
from typing import Annotated, Any, Union, get_args, get_origin, get_type_hints

__all__ = ["Choices", "FieldType", "Length", "Range", "RecordError", "field_types", "strategy_for", "validate"]

VHDL_INTEGER_MIN = -(2**31)
VHDL_INTEGER_MAX = 2**31 - 1


class RecordError(ValueError):
    """A record type is not supported, or a value is outside the bounds of its type."""


@dataclasses.dataclass(frozen=True)
class Range:
    """The inclusive bounds of an ``int`` field."""

    min: int
    max: int

    def __post_init__(self) -> None:
        if self.min > self.max:
            raise RecordError(f"Range({self.min}, {self.max}) has a minimum above its maximum")
        if self.min < VHDL_INTEGER_MIN or self.max > VHDL_INTEGER_MAX:
            raise RecordError(f"Range({self.min}, {self.max}) exceeds the range of a VHDL integer")


@dataclasses.dataclass(frozen=True)
class Length:
    """The inclusive bounds of the length of a ``str``, ``bytes`` or ``list`` field."""

    max: int
    min: int = 0

    def __post_init__(self) -> None:
        if not 0 <= self.min <= self.max:
            raise RecordError(f"Length(min={self.min}, max={self.max}) needs 0 <= min <= max")


@dataclasses.dataclass(frozen=True, init=False)
class Choices:
    """The allowed values of an ``int`` or ``str`` field."""

    values: tuple[int | str, ...]

    def __init__(self, *values: int | str) -> None:
        if not values:
            raise RecordError("Choices needs at least one value")
        if not (all(isinstance(value, str) for value in values) or all(_is_int(value) for value in values)):
            raise RecordError(f"Choices must be all int or all str, got {values!r}")
        object.__setattr__(self, "values", tuple(values))


@dataclasses.dataclass(frozen=True)
class FieldType:
    """
    The parsed type of a record field.

    ``kind`` is ``bool``, ``int``, ``str``, ``enum``, ``bytes``, ``list``,
    ``record`` or ``optional``. ``low`` and ``high`` bound an ``int``, the
    length of ``str``, ``bytes`` and ``list``; ``element`` is the item type of a
    list and the inner type of an optional.
    """

    kind: str
    low: int = 0
    high: int = 0
    choices: tuple[int | str, ...] = ()
    enum: type[enum.Enum] | None = None
    record: type | None = None
    element: FieldType | None = None


def field_types(cls: type) -> list[tuple[str, FieldType]]:
    """
    The fields of a record dataclass with their parsed types.

    Raises:
        RecordError: ``cls`` is not a dataclass or a field type is not supported.
    """
    if not (isinstance(cls, type) and dataclasses.is_dataclass(cls)):
        raise RecordError(f"{cls!r} is not a dataclass")
    try:
        hints = get_type_hints(cls, include_extras=True)
    except (NameError, TypeError) as exc:
        raise RecordError(f"The field types of {cls.__qualname__} cannot be resolved: {exc}") from None
    return [
        (field.name, _parse(hints[field.name], f"{cls.__qualname__}.{field.name}")) for field in dataclasses.fields(cls)
    ]


def validate(value: object) -> None:
    """
    Check that a record value is within the bounds of its type, recursively.

    Raises:
        RecordError: A field is outside its bounds or of the wrong type.
    """
    cls = type(value)
    for name, field_type in field_types(cls):
        _check(getattr(value, name), field_type, f"{cls.__qualname__}.{name}")


def strategy_for(cls: type) -> Any:
    """
    A Hypothesis strategy drawing valid values of a record dataclass.

    Raises:
        RecordError: A field type is not supported, or Hypothesis is not installed.
    """
    try:
        from hypothesis import strategies as st
    except ImportError:
        raise RecordError("strategy_for needs Hypothesis, which is not installed: pip install hypothesis") from None
    fields = {name: _strategy(field_type, st) for name, field_type in field_types(cls)}
    return st.builds(cls, **fields)


# Parsing
_UNSUPPORTED_HINT = (
    "supported are bool, int with Range or Choices, str with Length or Choices, bytes with Length, "
    "an Enum, a dataclass, list[...] with Length and Optional[...]"
)


def _parse(hint: Any, where: str, markers: tuple[object, ...] = ()) -> FieldType:
    if get_origin(hint) is Annotated:
        base, *extra = get_args(hint)
        return _parse(base, where, (*markers, *extra))

    if _is_optional(hint):
        (inner,) = [arg for arg in get_args(hint) if arg is not type(None)]
        inner_type = _parse(inner, where, markers)
        if inner_type.kind == "optional":
            raise RecordError(f"{where}: nested Optional is not supported")
        return FieldType("optional", element=inner_type)
    if get_origin(hint) in (Union, types.UnionType):
        raise RecordError(f"{where}: {hint} is a union; only Optional[...] unions are supported")

    ranges = [marker for marker in markers if isinstance(marker, Range)]
    lengths = [marker for marker in markers if isinstance(marker, Length)]
    choices = [marker for marker in markers if isinstance(marker, Choices)]
    if len(ranges) > 1 or len(lengths) > 1 or len(choices) > 1:
        raise RecordError(f"{where}: give each marker at most once")

    if hint is bool:
        _no_markers(where, "bool", ranges, lengths, choices)
        return FieldType("bool")
    if hint is int:
        _no_markers(where, "int", [], lengths, [])
        if choices:
            values = choices[0].values
            if not all(_is_int(value) for value in values):
                raise RecordError(f"{where}: the Choices of an int field must be int")
            if ranges:
                raise RecordError(f"{where}: give Range or Choices, not both")
            numbers = [int(value) for value in values]
            return FieldType("int", low=min(numbers), high=max(numbers), choices=values)
        bounds = ranges[0] if ranges else Range(VHDL_INTEGER_MIN, VHDL_INTEGER_MAX)
        return FieldType("int", low=bounds.min, high=bounds.max)
    if hint is str:
        _no_markers(where, "str", ranges, [], [])
        if choices:
            values = choices[0].values
            if not all(isinstance(value, str) for value in values):
                raise RecordError(f"{where}: the Choices of a str field must be str")
            if lengths:
                raise RecordError(f"{where}: give Length or Choices, not both")
            return FieldType("str", low=0, high=max(len(str(value)) for value in values), choices=values)
        if not lengths:
            raise RecordError(
                f"{where}: a str field needs Length(max=...) or Choices, since a VHDL record has a fixed size"
            )
        return FieldType("str", low=lengths[0].min, high=lengths[0].max)
    if hint is bytes:
        _no_markers(where, "bytes", ranges, [], choices)
        if not lengths:
            raise RecordError(f"{where}: a bytes field needs Length(max=...), since a VHDL record has a fixed size")
        return FieldType("bytes", low=lengths[0].min, high=lengths[0].max)
    if get_origin(hint) is list:
        _no_markers(where, "list", ranges, [], choices)
        if not lengths:
            raise RecordError(f"{where}: a list field needs Length(max=...), since a VHDL record has a fixed size")
        (item_hint,) = get_args(hint) or (None,)
        if item_hint is None:
            raise RecordError(f"{where}: give the item type, as in list[int]")
        item = _parse(item_hint, f"{where}[item]")
        if item.kind not in ("bool", "int", "enum", "record"):
            raise RecordError(
                f"{where}: list items of kind {item.kind} are not supported; use bool, int, an Enum or a dataclass"
            )
        return FieldType("list", low=lengths[0].min, high=lengths[0].max, element=item)
    if isinstance(hint, type) and issubclass(hint, enum.Enum):
        _no_markers(where, "Enum", ranges, lengths, choices)
        for member in hint:
            if not member.name.isidentifier() or member.name.startswith("_") or "__" in member.name:
                raise RecordError(f"{where}: enum member {member.name!r} is not a valid VHDL identifier")
        return FieldType("enum", enum=hint)
    if isinstance(hint, type) and dataclasses.is_dataclass(hint):
        _no_markers(where, "dataclass", ranges, lengths, choices)
        field_types(hint)  # reject unsupported nested fields early
        return FieldType("record", record=hint)
    raise RecordError(f"{where}: {getattr(hint, '__name__', hint)} is not supported; {_UNSUPPORTED_HINT}")


def _no_markers(where: str, kind: str, *groups: list[Any]) -> None:
    for group in groups:
        if group:
            raise RecordError(f"{where}: {type(group[0]).__name__} does not apply to a {kind} field")


def _is_optional(hint: Any) -> bool:
    return get_origin(hint) in (Union, types.UnionType) and type(None) in get_args(hint) and len(get_args(hint)) == 2


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


# Validation
def _check(value: object, field_type: FieldType, where: str) -> None:
    kind = field_type.kind
    if kind == "optional":
        if value is not None:
            assert field_type.element is not None
            _check(value, field_type.element, where)
        return
    if kind == "bool":
        if not isinstance(value, bool):
            raise RecordError(f"{where} is {value!r}, not a bool")
    elif kind == "int":
        if not _is_int(value):
            raise RecordError(f"{where} is {value!r}, not an int")
        if field_type.choices and value not in field_type.choices:
            raise RecordError(f"{where} is {value}, not one of {field_type.choices}")
        if not field_type.low <= typing.cast(int, value) <= field_type.high:
            raise RecordError(f"{where} is {value}, outside Range({field_type.low}, {field_type.high})")
    elif kind == "str":
        if not isinstance(value, str):
            raise RecordError(f"{where} is {value!r}, not a str")
        if field_type.choices and value not in field_type.choices:
            raise RecordError(f"{where} is {value!r}, not one of {field_type.choices}")
        _check_length(len(value), field_type, where)
        if not all(32 <= ord(char) <= 126 for char in value):
            raise RecordError(f"{where} is {value!r}; only printable ASCII fits a VHDL string")
    elif kind == "bytes":
        if not isinstance(value, bytes):
            raise RecordError(f"{where} is {value!r}, not bytes")
        _check_length(len(value), field_type, where)
    elif kind == "list":
        if not isinstance(value, list):
            raise RecordError(f"{where} is {value!r}, not a list")
        _check_length(len(value), field_type, where)
        assert field_type.element is not None
        for index, item in enumerate(value):
            _check(item, field_type.element, f"{where}[{index}]")
    elif kind == "enum":
        if not isinstance(value, field_type.enum or ()):
            raise RecordError(f"{where} is {value!r}, not a {field_type.enum}")
    elif kind == "record":
        if type(value) is not field_type.record:
            raise RecordError(f"{where} is {value!r}, not a {field_type.record}")
        validate(value)


def _check_length(length: int, field_type: FieldType, where: str) -> None:
    if not field_type.low <= length <= field_type.high:
        raise RecordError(f"{where} has length {length}, outside Length(min={field_type.low}, max={field_type.high})")


# Strategies
def _strategy(field_type: FieldType, st: Any) -> Any:
    kind = field_type.kind
    if kind == "optional":
        assert field_type.element is not None
        return st.none() | _strategy(field_type.element, st)
    if kind == "bool":
        return st.booleans()
    if kind in ("int", "str") and field_type.choices:
        return st.sampled_from(field_type.choices)
    if kind == "int":
        return st.integers(field_type.low, field_type.high)
    if kind == "str":
        return st.text(
            st.characters(min_codepoint=32, max_codepoint=126), min_size=field_type.low, max_size=field_type.high
        )
    if kind == "bytes":
        return st.binary(min_size=field_type.low, max_size=field_type.high)
    if kind == "list":
        assert field_type.element is not None
        return st.lists(_strategy(field_type.element, st), min_size=field_type.low, max_size=field_type.high)
    if kind == "enum":
        return st.sampled_from(list(field_type.enum or ()))
    assert field_type.record is not None
    return strategy_for(field_type.record)
