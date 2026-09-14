"""
Generate VHDL records from Python dataclasses for property-based tests.

The dataclasses of :mod:`awesome_vunit_vcs.records` describe the examples of a
property. From them this module writes a VHDL-2008 package with, for every
dataclass, a record type ``<name>_t``, a getter
``get_<name>(prop, path)`` that reads an example of ``property_pkg`` into the
record in one call, and ``to_string(value)``, whose text equals
:func:`vhdl_image` of the Python value.

Type mapping:

* ``bool`` → ``boolean``; ``int`` → ``integer range <min> to <max>``
* an :class:`enum.Enum` → an enumeration type with the member names in lower case
* a dataclass → its record type
* ``str`` → ``string(1 to <max>)`` plus ``<field>_length``
* ``bytes`` and ``list[int]`` → ``integer_vector(0 to <max> - 1)`` plus
  ``<field>_length``; the items are read in one bridge call
* ``list`` of bool, an Enum or a dataclass → an array type
  ``<record>_<field>_array_t`` of ``<max>`` items plus ``<field>_length``
* ``T | None`` → the field of ``T`` plus ``has_<field> : boolean``

Fixed capacities keep the records constrained, so they can be signals,
compared and assigned. A maximum length of 0 still gets one item of capacity.

Generate from a run script, which rewrites the package only when it changes::

    from awesome_vunit_vcs.gen_vhdl import write_vhdl
    write_vhdl([Config], "config_pkg", ROOT / "generated" / "config_pkg.vhd")

or from the command line::

    python -m awesome_vunit_vcs.gen_vhdl my_props:Config --package config_pkg --output config_pkg.vhd
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import importlib
import re
import sys
from collections.abc import Sequence
from pathlib import Path

from . import __version__
from .records import FieldType, RecordError, field_types

__all__ = ["generate_vhdl", "main", "vhdl_image", "write_vhdl"]

VHDL_RESERVED_WORDS = frozenset(
    [
        "abs",
        "access",
        "after",
        "alias",
        "all",
        "and",
        "architecture",
        "array",
        "assert",
        "assume",
        "assume_guarantee",
        "attribute",
        "begin",
        "block",
        "body",
        "buffer",
        "bus",
        "case",
        "component",
        "configuration",
        "constant",
        "context",
        "cover",
        "default",
        "disconnect",
        "downto",
        "else",
        "elsif",
        "end",
        "entity",
        "exit",
        "fairness",
        "file",
        "for",
        "force",
        "function",
        "generate",
        "generic",
        "group",
        "guarded",
        "if",
        "impure",
        "in",
        "inertial",
        "inout",
        "is",
        "label",
        "library",
        "linkage",
        "literal",
        "loop",
        "map",
        "mod",
        "nand",
        "new",
        "next",
        "nor",
        "not",
        "null",
        "of",
        "on",
        "open",
        "or",
        "others",
        "out",
        "package",
        "parameter",
        "port",
        "postponed",
        "procedure",
        "process",
        "property",
        "protected",
        "pure",
        "range",
        "record",
        "register",
        "reject",
        "release",
        "rem",
        "report",
        "restrict",
        "restrict_guarantee",
        "return",
        "rol",
        "ror",
        "select",
        "sequence",
        "severity",
        "shared",
        "signal",
        "sla",
        "sll",
        "sra",
        "srl",
        "strong",
        "subtype",
        "then",
        "to",
        "transport",
        "type",
        "unaffected",
        "units",
        "until",
        "use",
        "variable",
        "vmode",
        "vprop",
        "vunit",
        "wait",
        "when",
        "while",
        "with",
        "xnor",
        "xor",
    ]
)

# Names property_pkg already uses for its getters
_PROPERTY_PKG_NAMES = frozenset(
    {"integer", "boolean", "string", "integer_vector", "unsigned", "length", "id", "logger", "checker", "outcome"}
)

_IDENTIFIER = re.compile(r"[a-z][a-z0-9]*(_[a-z0-9]+)*")


def generate_vhdl(types: Sequence[type], package_name: str) -> str:
    """
    The VHDL package of record types for dataclasses.

    Args:
        types: The dataclasses to generate. Nested dataclasses and enums are
            included automatically.
        package_name: The name of the VHDL package.

    Raises:
        RecordError: A type or field is not supported, or a name is not a valid
            VHDL identifier or collides with another.
    """
    _identifier(package_name, "The package name")
    if not types:
        raise RecordError("Give at least one dataclass")
    records, enums = _collect(types)
    return _Writer(package_name, list(types), records, enums).text()


def write_vhdl(types: Sequence[type], package_name: str, path: str | Path) -> bool:
    """
    Write the generated package to ``path`` if its content changed.

    Returns:
        True when the file was written, False when it was up to date, so an
        unchanged package is not recompiled.
    """
    text = generate_vhdl(types, package_name)
    target = Path(path)
    if target.exists() and target.read_text(encoding="utf-8") == text:
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    return True


def vhdl_image(value: object) -> str:
    """
    The text the generated ``to_string`` gives for the VHDL record of a dataclass value.

    Raises:
        RecordError: The value is not a supported dataclass value.
    """
    return _image(value, None, type(value).__qualname__)


def main(argv: Sequence[str] | None = None) -> int:
    """The command line interface; see the module documentation."""
    parser = argparse.ArgumentParser(
        prog="python -m awesome_vunit_vcs.gen_vhdl",
        description="Generate VHDL records and property getters from Python dataclasses.",
    )
    parser.add_argument("types", nargs="+", help="dataclasses as package.module:Class")
    parser.add_argument("--package", required=True, help="the name of the VHDL package")
    parser.add_argument("--output", default="-", help="the VHDL file to write, - for standard output")
    parser.add_argument("--search-path", default=".", help="a directory to import the modules from")
    args = parser.parse_args(argv)
    sys.path.insert(0, args.search_path)
    try:
        types = [_resolve_type(spec) for spec in args.types]
        if args.output == "-":
            sys.stdout.write(generate_vhdl(types, args.package))
        else:
            write_vhdl(types, args.package, args.output)
    except RecordError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


# Names
def _snake(name: str) -> str:
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)).lower()


def _identifier(name: str, what: str) -> str:
    lowered = name.lower()
    if not _IDENTIFIER.fullmatch(lowered):
        raise RecordError(f"{what} {name!r} is not a valid VHDL identifier")
    if lowered in VHDL_RESERVED_WORDS:
        raise RecordError(f"{what} {name!r} is a VHDL reserved word")
    return lowered


def _type_name(cls: type) -> str:
    base = _identifier(_snake(cls.__name__), f"The name of {cls.__qualname__}")
    if base in _PROPERTY_PKG_NAMES:
        raise RecordError(f"{cls.__qualname__} would generate get_{base}, which property_pkg already has")
    return base


def _collect(types: Sequence[type]) -> tuple[list[type], list[type[enum.Enum]]]:
    """Records in dependency order and the enums they use; rejects name collisions."""
    records: list[type] = []
    enums: list[type[enum.Enum]] = []
    names: dict[str, type] = {}

    def claim(cls: type) -> None:
        name = _type_name(cls)
        if names.setdefault(name, cls) is not cls:
            raise RecordError(f"{cls.__qualname__} and {names[name].__qualname__} both become {name}_t")

    def visit_field(field_type: FieldType) -> None:
        if field_type.element is not None:
            visit_field(field_type.element)
        if field_type.kind == "enum" and field_type.enum is not None and field_type.enum not in enums:
            claim(field_type.enum)
            enums.append(field_type.enum)
        if field_type.kind == "record" and field_type.record is not None:
            visit_record(field_type.record)

    def visit_record(cls: type) -> None:
        if cls in records:
            return
        for _, field_type in field_types(cls):
            visit_field(field_type)
        claim(cls)
        records.append(cls)

    for cls in types:
        if not (isinstance(cls, type) and dataclasses.is_dataclass(cls)):
            raise RecordError(f"{cls!r} is not a dataclass")
        visit_record(cls)
    return records, enums


def _resolve_type(spec: str) -> type:
    module_name, colon, attribute = spec.partition(":")
    if not colon or not module_name or not attribute:
        raise RecordError(f"{spec!r} is not a 'package.module:Class' spec")
    try:
        target: object = importlib.import_module(module_name)
    except ImportError as exc:
        raise RecordError(f"Cannot import module {module_name!r} of {spec!r}: {exc}") from None
    for name in attribute.split("."):
        if not hasattr(target, name):
            raise RecordError(f"{spec!r}: {module_name!r} has no attribute {attribute!r}")
        target = getattr(target, name)
    if not isinstance(target, type):
        raise RecordError(f"{spec!r} is not a class")
    return target


# Python image
def _image(value: object, field_type: FieldType | None, where: str) -> str:
    if field_type is None or field_type.kind == "record":
        cls = type(value)
        if not dataclasses.is_dataclass(cls):
            raise RecordError(f"{where} is {value!r}, not a dataclass value")
        parts = [
            f"{name.lower()} => {_image(getattr(value, name), ftype, f'{where}.{name}')}"
            for name, ftype in field_types(cls)
        ]
        return "(" + ", ".join(parts) + ")"
    kind = field_type.kind
    if kind == "optional":
        assert field_type.element is not None
        return "none" if value is None else _image(value, field_type.element, where)
    if kind == "bool":
        return "true" if value else "false"
    if kind == "int":
        return str(value)
    if kind == "enum":
        assert isinstance(value, enum.Enum)
        return value.name.lower()
    if kind == "str":
        return f'"{value}"'
    if kind == "bytes":
        assert isinstance(value, bytes)
        return "(" + ", ".join(str(octet) for octet in value) + ")"
    assert kind == "list" and field_type.element is not None and isinstance(value, list)
    return (
        "(" + ", ".join(_image(item, field_type.element, f"{where}[{index}]") for index, item in enumerate(value)) + ")"
    )


# VHDL
def _is_vector(field_type: FieldType) -> bool:
    """bytes and list[int] are integer_vectors, read in one bridge call."""
    return field_type.kind == "bytes" or (
        field_type.kind == "list" and field_type.element is not None and field_type.element.kind == "int"
    )


def _doc(obj: object) -> str | None:
    doc = obj.__doc__
    if not doc or doc.startswith(f"{getattr(obj, '__name__', '')}("):
        return None  # the default dataclass docstring is the signature
    return doc.strip().splitlines()[0]


class _Writer:
    def __init__(self, package: str, roots: list[type], records: list[type], enums: list[type[enum.Enum]]) -> None:
        self.package = package
        self.roots = roots
        self.records = records
        self.enums = enums

    def text(self) -> str:
        sources = ", ".join(f"{cls.__module__}.{cls.__qualname__}" for cls in self.roots)
        lines = [
            f"-- Generated by awesome_vunit_vcs.gen_vhdl {__version__} from {sources}.",
            "-- Do not edit: change the dataclasses and generate the package again.",
            "",
            "use std.textio.all;",
            "",
            "library awesome_vunit_vcs;",
            "use awesome_vunit_vcs.property_pkg.all;",
            "",
            f"package {self.package} is",
        ]
        for enum_cls in self.enums:
            lines += self._doc_lines(enum_cls)
            members = ", ".join(
                _identifier(member.name, f"Member {member.name} of {enum_cls.__qualname__}") for member in enum_cls
            )
            lines += [f"  type {_type_name(enum_cls)}_t is ({members});", ""]
        for cls in self.records:
            lines += self._record_declaration(cls)
        lines += ["end package;", "", f"package body {self.package} is"]
        lines += self._helpers()
        for cls in self.records:
            lines += self._getter(cls) + self._to_string(cls)
        lines += ["end package body;", ""]
        return "\n".join(lines)

    def _doc_lines(self, obj: object) -> list[str]:
        doc = _doc(obj)
        return [f"  -- {doc}"] if doc else []

    # Declarations
    def _element_type(self, field_type: FieldType) -> str:
        kind = field_type.kind
        if kind == "bool":
            return "boolean"
        if kind == "int":
            return f"integer range {field_type.low} to {field_type.high}"
        if kind == "enum":
            assert field_type.enum is not None
            return f"{_type_name(field_type.enum)}_t"
        assert kind == "record" and field_type.record is not None
        return f"{_type_name(field_type.record)}_t"

    def _record_declaration(self, cls: type) -> list[str]:
        name = _type_name(cls)
        arrays: list[str] = []
        elements: list[str] = []
        taken: dict[str, str] = {}

        def element(element_name: str, subtype: str, field: str) -> None:
            if element_name in taken:
                owner = f"{cls.__qualname__}.{taken[element_name]}"
                raise RecordError(f"{cls.__qualname__}.{field} generates {element_name}, which {owner} also generates")
            taken[element_name] = field
            elements.append(f"    {element_name} : {subtype};")

        for field, field_type in field_types(cls):
            vhdl_field = _identifier(field, f"Field {cls.__qualname__}.{field}")
            optional = field_type.kind == "optional"
            inner = field_type.element if optional else field_type
            assert inner is not None
            capacity = max(inner.high, 1)
            if inner.kind == "str":
                element(vhdl_field, f"string(1 to {capacity})", field)
                element(f"{vhdl_field}_length", f"natural range 0 to {inner.high}", field)
            elif _is_vector(inner):
                element(vhdl_field, f"integer_vector(0 to {capacity - 1})", field)
                element(f"{vhdl_field}_length", f"natural range 0 to {inner.high}", field)
            elif inner.kind == "list":
                assert inner.element is not None
                array = f"{name}_{vhdl_field}_array_t"
                arrays.append(f"  type {array} is array (0 to {capacity - 1}) of {self._element_type(inner.element)};")
                element(vhdl_field, array, field)
                element(f"{vhdl_field}_length", f"natural range 0 to {inner.high}", field)
            else:
                element(vhdl_field, self._element_type(inner), field)
            if optional:
                element(f"has_{vhdl_field}", "boolean", field)

        lines = arrays + ([""] if arrays else []) + self._doc_lines(cls)
        lines += [f"  type {name}_t is record", *elements, "  end record;", ""]
        lines += [
            f"  -- Read the example at ``path`` of a property into a :vhdl:`{self.package}.{name}_t`.",
            f'  impure function get_{name}(prop : property_t; path : string := "") return {name}_t;',
            "  -- The value as text, equal to vhdl_image of the Python value.",
            f"  impure function to_string(value : {name}_t) return string;",
            "",
        ]
        return lines

    # Bodies
    def _helpers(self) -> list[str]:
        return [
            "  function p_field(path, name : string) return string is",
            "  begin",
            '    if path = "" then',
            "      return name;",
            "    end if;",
            '    return path & "." & name;',
            "  end;",
            "",
            "  function p_item(path : string; idx : natural) return string is",
            "  begin",
            '    return path & "(" & integer\'image(idx) & ")";',
            "  end;",
            "",
            "  procedure p_copy(value : string; variable target : inout string; variable length : out natural) is",
            "    alias normalized : string(1 to value'length) is value;",
            "  begin",
            "    for idx in normalized'range loop",
            "      target(target'left + idx - 1) := normalized(idx);",
            "    end loop;",
            "    length := value'length;",
            "  end;",
            "",
            "  procedure p_copy(",
            "    value : integer_vector; variable target : inout integer_vector; variable length : out natural",
            "  ) is",
            "    alias normalized : integer_vector(0 to value'length - 1) is value;",
            "  begin",
            "    for idx in normalized'range loop",
            "      target(target'left + idx) := normalized(idx);",
            "    end loop;",
            "    length := value'length;",
            "  end;",
            "",
            "  impure function p_image(value : integer_vector; length : natural) return string is",
            "    variable text : line;",
            "  begin",
            '    write(text, string\'("("));',
            "    for idx in 0 to length - 1 loop",
            "      if idx > 0 then",
            '        write(text, string\'(", "));',
            "      end if;",
            "      write(text, integer'image(value(value'left + idx)));",
            "    end loop;",
            '    write(text, string\'(")"));',
            "    return text.all;",
            "  end;",
            "",
        ]

    def _read(self, field_type: FieldType, target: str, path: str, indent: str) -> list[str]:
        kind = field_type.kind
        if kind == "optional":
            assert field_type.element is not None
            flag = re.sub(r"(\w+)$", r"has_\1", target)
            return [
                f"{indent}{flag} := has_field(prop, {path});",
                f"{indent}if {flag} then",
                *self._read(field_type.element, target, path, indent + "  "),
                f"{indent}end if;",
            ]
        if kind == "bool":
            return [f"{indent}{target} := get_boolean(prop, {path});"]
        if kind == "int":
            return [f"{indent}{target} := get_integer(prop, {path});"]
        if kind == "enum":
            assert field_type.enum is not None
            return [f"{indent}{target} := {_type_name(field_type.enum)}_t'value(get_string(prop, {path}));"]
        if kind == "record":
            assert field_type.record is not None
            return [f"{indent}{target} := get_{_type_name(field_type.record)}(prop, {path});"]
        if kind == "str":
            return [f"{indent}p_copy(get_string(prop, {path}), {target}, {target}_length);"]
        if _is_vector(field_type):
            return [f"{indent}p_copy(get_integer_vector(prop, {path}), {target}, {target}_length);"]
        assert kind == "list" and field_type.element is not None
        return [
            f"{indent}{target}_length := get_length(prop, {path});",
            f"{indent}for idx in 0 to {target}_length - 1 loop",
            *self._read(field_type.element, f"{target}(idx)", f"p_item({path}, idx)", indent + "  "),
            f"{indent}end loop;",
        ]

    def _getter(self, cls: type) -> list[str]:
        name = _type_name(cls)
        lines = [
            f'  impure function get_{name}(prop : property_t; path : string := "") return {name}_t is',
            f"    variable result : {name}_t;",
            "  begin",
        ]
        for field, field_type in field_types(cls):
            vhdl_field = field.lower()
            lines += self._read(field_type, f"result.{vhdl_field}", f'p_field(path, "{vhdl_field}")', "    ")
        return [*lines, "    return result;", "  end;", ""]

    def _image_expression(self, field_type: FieldType, value: str) -> str:
        kind = field_type.kind
        if kind == "bool":
            return f"boolean'image({value})"
        if kind == "int":
            return f"integer'image({value})"
        if kind == "enum":
            assert field_type.enum is not None
            return f"{_type_name(field_type.enum)}_t'image({value})"
        if kind == "record":
            return f"to_string({value})"
        if kind == "str":
            return f'"""" & {value}(1 to {value}_length) & """"'
        assert _is_vector(field_type)
        return f"p_image({value}, {value}_length)"

    def _write_image(self, field_type: FieldType, value: str, indent: str) -> list[str]:
        kind = field_type.kind
        if kind == "optional":
            assert field_type.element is not None
            flag = re.sub(r"(\w+)$", r"has_\1", value)
            return [
                f"{indent}if {flag} then",
                *self._write_image(field_type.element, value, indent + "  "),
                f"{indent}else",
                f'{indent}  write(text, string\'("none"));',
                f"{indent}end if;",
            ]
        if kind == "list" and not _is_vector(field_type):
            assert field_type.element is not None
            return [
                f'{indent}write(text, string\'("("));',
                f"{indent}for idx in 0 to {value}_length - 1 loop",
                f"{indent}  if idx > 0 then",
                f'{indent}    write(text, string\'(", "));',
                f"{indent}  end if;",
                *self._write_image(field_type.element, f"{value}(idx)", indent + "  "),
                f"{indent}end loop;",
                f'{indent}write(text, string\'(")"));',
            ]
        return [f"{indent}write(text, {self._image_expression(field_type, value)});"]

    def _to_string(self, cls: type) -> list[str]:
        name = _type_name(cls)
        lines = [
            f"  impure function to_string(value : {name}_t) return string is",
            "    variable text : line;",
            "  begin",
            '    write(text, string\'("("));',
        ]
        for index, (field, field_type) in enumerate(field_types(cls)):
            separator = ", " if index else ""
            lines.append(f'    write(text, string\'("{separator}{field.lower()} => "));')
            lines += self._write_image(field_type, f"value.{field.lower()}", "    ")
        return [*lines, '    write(text, string\'(")"));', "    return text.all;", "  end;", ""]


if __name__ == "__main__":
    raise SystemExit(main())
