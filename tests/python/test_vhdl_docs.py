"""Tests of tools/vhdl_docs.py, the generator of the VHDL API reference."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "vhdl_docs.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("vhdl_docs", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # dataclasses look the module up while the classes are created
    sys.modules.setdefault("vhdl_docs", module)
    spec.loader.exec_module(module)
    return module


vhdl_docs = _load()

PACKAGE = """\
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handles of the example components.
--
--   an indented block

library vunit_lib;

package example_pkg is
  -- The kinds, one per line
  type kind_t is (
    -- The first kind
    first,
    second
  );

  type handle_t is record
    -- Private
    p_width : positive;
  end record;

  -- A new handle
  impure function new_handle(
    width : positive := 8; -- Trailing comment
    name : string := "a;b"
  ) return handle_t;

  impure function get_width(handle : handle_t) return positive;
  impure function get_name(handle : handle_t) return string;

  ---------------------------------------------------------------------------
  -- Sending
  --
  -- Procedures that send.
  ---------------------------------------------------------------------------

  -- Send one value
  procedure send(
    signal net : inout network_t;
    handle : handle_t;
    variable value : out natural
  );
  -- Send another value
  procedure send(signal net : inout network_t; handle : handle_t);

  constant undocumented_constant : natural := 3;
end package;

package body example_pkg is
  -- Not public
  procedure hidden is
  begin
  end;
end package body;
"""

ENTITY = """\
-- Example monitor.

library ieee;
use ieee.std_logic_1164.all;

entity example_monitor is
  generic (
    -- The handle
    handle : handle_t;
    depth : natural := 4
  );
  port (
    -- The clock
    clk : in std_ulogic;
    data : in std_ulogic_vector(handle.p_width - 1 downto 0); -- Not a doc comment
    ready : out std_ulogic := '0'
  );
end entity;

architecture a of example_monitor is
begin
end architecture;
"""


def _parse(tmp_path: Path, name: str, text: str) -> list[object]:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    result: list[object] = vhdl_docs.parse_file(path)
    return result


def test_package_declarations_and_comments(tmp_path: Path) -> None:
    (unit,) = _parse(tmp_path, "example_pkg.vhd", PACKAGE)
    assert unit.kind == "package"
    assert unit.name == "example_pkg"
    assert unit.description == ["Handles of the example components.", "", "  an indented block"]
    names = [declaration.name for declaration in unit.declarations]
    assert names == [
        "kind_t",
        "handle_t",
        "new_handle",
        "get_width",
        "get_name",
        "send",
        "send",
        "undocumented_constant",
    ]
    kind = unit.declarations[0]
    assert kind.comment == ["The kinds, one per line"]
    assert "-- The first kind" in kind.code
    assert unit.declarations[1].code.endswith("end record;")


def test_subprogram_parameters(tmp_path: Path) -> None:
    (unit,) = _parse(tmp_path, "example_pkg.vhd", PACKAGE)
    new_handle = unit.declarations[2]
    assert new_handle.returns == "handle_t"
    assert [(p.names, p.mode, p.type, p.default) for p in new_handle.parameters] == [
        (["width"], "", "positive", "8"),
        (["name"], "", "string", '"a;b"'),
    ]
    send = unit.declarations[5]
    assert [(p.names, p.mode, p.type) for p in send.parameters] == [
        (["net"], "signal inout", "network_t"),
        (["handle"], "", "handle_t"),
        (["value"], "variable out", "natural"),
    ]


def test_sections_groups_and_undocumented(tmp_path: Path) -> None:
    (unit,) = _parse(tmp_path, "example_pkg.vhd", PACKAGE)
    (section,) = [item for item in unit.items if isinstance(item, vhdl_docs.Section)]
    assert section.title == "Sending"
    assert section.text == ["Procedures that send."]
    # get_name follows get_width without a blank line: one undocumented group, reported once
    assert vhdl_docs.undocumented(unit) == ["handle_t", "get_width", "undocumented_constant"]


def test_package_body_is_not_documented(tmp_path: Path) -> None:
    units = _parse(tmp_path, "example_pkg.vhd", PACKAGE)
    assert [unit.name for unit in units] == ["example_pkg"]
    assert "hidden" not in [declaration.name for declaration in units[0].declarations]


def test_entity_generics_and_ports(tmp_path: Path) -> None:
    (unit,) = _parse(tmp_path, "example_monitor.vhd", ENTITY)
    assert unit.kind == "entity"
    assert unit.description == ["Example monitor."]
    assert [(g.names, g.type, g.default, g.comment) for g in unit.generics] == [
        (["handle"], "handle_t", "", ["The handle"]),
        (["depth"], "natural", "4", []),
    ]
    assert [(p.names, p.mode, p.type, p.default, p.comment) for p in unit.ports] == [
        (["clk"], "in", "std_ulogic", "", ["The clock"]),
        (["data"], "in", "std_ulogic_vector(handle.p_width - 1 downto 0)", "", []),
        (["ready"], "out", "std_ulogic", "'0'", []),
    ]


def test_generate_groups_a_family_and_marks_overloads(tmp_path: Path) -> None:
    family = tmp_path / "vhdl" / "example"
    family.mkdir(parents=True)
    (family / "example_pkg.vhd").write_text(PACKAGE, encoding="utf-8")
    (family / "example_monitor.vhd").write_text(ENTITY, encoding="utf-8")
    (family / "other_pkg.vhd").write_text(PACKAGE.replace("example_pkg", "other_pkg"), encoding="utf-8")

    (written,) = vhdl_docs.generate(tmp_path / "vhdl", tmp_path / "out")
    text = written.read_text(encoding="utf-8")

    assert written.name == "example.inc"
    # The family group first, packages before entities, then the other groups
    assert text.index("Shared\n------") < text.index("Package example_pkg") < text.index("Entity example_monitor")
    assert text.index("Entity example_monitor") < text.index("OTHER\n-----") < text.index("Package other_pkg")
    assert ".. vhdl:: example_pkg.new_handle" in text
    # The second declaration of an overload has no index entry of its own
    assert text.count(".. vhdl:: example_pkg.send\n   :no-index:") == 1
    assert ".. code-block:: text" in text
    assert "``positive``" in text


def test_generate_rewrites_only_changed_files(tmp_path: Path) -> None:
    family = tmp_path / "vhdl" / "example"
    family.mkdir(parents=True)
    (family / "example_pkg.vhd").write_text(PACKAGE, encoding="utf-8")
    (written,) = vhdl_docs.generate(tmp_path / "vhdl", tmp_path / "out")
    before = written.stat().st_mtime_ns
    vhdl_docs.generate(tmp_path / "vhdl", tmp_path / "out")
    assert written.stat().st_mtime_ns == before
