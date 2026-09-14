"""
Guardrails that keep the documentation true to the code.

Tests marked xfail wait for documentation work in progress. Remove the marker when it
lands so the guardrail blocks regressions.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO = Path(__file__).resolve().parents[2]
DOCS = REPO / "docs"
VHDL = REPO / "src" / "awesome_vunit_vcs" / "vhdl"


def _load_vhdl_docs() -> ModuleType:
    spec = importlib.util.spec_from_file_location("vhdl_docs", REPO / "tools" / "vhdl_docs.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # dataclasses look the module up while the classes are created
    sys.modules.setdefault("vhdl_docs", module)
    spec.loader.exec_module(module)
    return module


vhdl_docs = _load_vhdl_docs()


def _families() -> list[Path]:
    return sorted(path for path in VHDL.iterdir() if path.is_dir())


@pytest.mark.parametrize("family", _families(), ids=lambda path: path.name)
def test_every_vhdl_family_has_a_reference_page(family: Path) -> None:
    page = DOCS / "reference" / "vhdl" / f"{family.name}.rst"
    assert page.is_file(), f"Add {page.relative_to(REPO)} including /_generated/vhdl/{family.name}.inc"
    assert f"/_generated/vhdl/{family.name}.inc" in page.read_text(encoding="utf-8")
    index = (DOCS / "reference" / "vhdl" / "index.rst").read_text(encoding="utf-8")
    assert re.search(rf"^\s+{family.name}$", index, re.MULTILINE), f"Add {family.name} to the reference toctree"


def test_every_vhdl_file_parses_into_a_design_unit() -> None:
    for path in sorted(VHDL.rglob("*.vhd")):
        assert vhdl_docs.parse_file(path), f"{path.relative_to(REPO)} has no package, entity or context"


def _check_literals(vhdl_package: Path) -> set[str]:
    text = vhdl_package.read_text(encoding="utf-8")
    match = re.search(r"type\s+\w+_check_t\s+is\s*\((?P<literals>[^;]*?)\)\s*;", text, re.IGNORECASE | re.DOTALL)
    assert match is not None, f"No check type in {vhdl_package.name}"
    code = re.sub(r"--[^\n]*", "", match["literals"])
    return {literal.strip().upper() for literal in code.split(",") if literal.strip()}


def test_vhdl_checks_are_the_python_check_ids() -> None:
    from awesome_vunit_vcs.ethernet.checker import CheckId

    packages = [path for path in (VHDL / "ethernet").glob("*_pkg.vhd") if re.search(r"_check_t\s+is", path.read_text())]
    assert packages, "No VHDL package declares the Ethernet checks"
    vhdl_checks: set[str] = set()
    for package in packages:
        vhdl_checks |= _check_literals(package)
    assert vhdl_checks == {check.value.upper() for check in CheckId}


def test_every_check_is_in_the_checks_table() -> None:
    from awesome_vunit_vcs.ethernet.checker import CheckId

    table = (DOCS / "ethernet" / "checks.rst").read_text(encoding="utf-8")
    missing = [check.name for check in CheckId if check.name.lower() not in table.lower()]
    assert not missing


def test_every_public_vhdl_declaration_has_a_doc_comment() -> None:
    missing = [
        f"{unit.name}.{name}"
        for path in sorted(VHDL.rglob("*_pkg.vhd"))
        for unit in vhdl_docs.parse_file(path)
        for name in vhdl_docs.undocumented(unit)
    ]
    assert not missing, "Undocumented: " + ", ".join(missing)


def test_every_entity_is_in_the_status_matrix() -> None:
    index = (DOCS / "index.rst").read_text(encoding="utf-8")
    entities = [
        unit.name
        for path in sorted(VHDL.rglob("*.vhd"))
        for unit in vhdl_docs.parse_file(path)
        if unit.kind == "entity"
    ]
    interfaces = {name.rsplit("_", 1)[0] for name in entities}
    missing = [name for name in sorted(interfaces) if name.upper() not in index.upper()]
    assert not missing


def test_readme_has_no_code_beyond_the_install_line() -> None:
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    blocks = re.findall(r"```[^\n]*\n(.*?)```", readme, re.DOTALL)
    assert all(block.strip().startswith("pip install") for block in blocks)


def test_ethernet_data_is_counted_in_octets() -> None:
    sources = [REPO / "src" / "awesome_vunit_vcs" / "ethernet" / "checker.py", *DOCS.rglob("*.rst")]
    offenders = [
        path.relative_to(REPO).as_posix()
        for path in sources
        if "_generated" not in path.parts and re.search(r"\bbytes?\b", path.read_text(encoding="utf-8"))
    ]
    assert not offenders
