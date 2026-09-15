"""
Guardrails that keep the documentation true to the code.

Tests marked xfail wait for documentation work in progress. Remove the marker when it
lands so the guardrail blocks regressions.
"""

from __future__ import annotations

import importlib
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


#: The documentation section of every component family, holding its VHDL and Python API pages
SECTIONS = ("ethernet", "property_testing", "flash", "common")


def _generated_includes() -> set[str]:
    includes: set[str] = set()
    for page in DOCS.rglob("*.rst"):
        if "_generated" not in page.parts and "_build" not in page.parts:
            includes |= set(re.findall(r"^\.\. include:: /_generated/vhdl/(\S+)\.inc$", page.read_text(), re.MULTILINE))
    return includes


def test_every_vhdl_package_group_is_in_the_reference() -> None:
    includes = _generated_includes()
    missing = [
        f"{family.name}.{path.stem.split('_')[0]}"
        for family in _families()
        for path in sorted(family.glob("*.vhd"))
        if family.name not in includes and f"{family.name}.{path.stem.split('_')[0]}" not in includes
    ]
    assert not missing, "Include these generated groups in a VHDL API page: " + ", ".join(sorted(set(missing)))


@pytest.mark.parametrize("section", SECTIONS)
def test_every_section_has_its_vhdl_and_python_api(section: str) -> None:
    index = (DOCS / section / "index.rst").read_text(encoding="utf-8")
    for page in ("vhdl_api", "python_api"):
        assert (DOCS / section / f"{page}.rst").is_file(), f"Add docs/{section}/{page}.rst"
        assert re.search(rf"^\s+{page}$", index, re.MULTILINE), f"Add {page} to the toctree of docs/{section}/index.rst"


#: Public Python modules whose ``__all__`` must appear in a Python API page
PUBLIC_MODULES = (
    "awesome_vunit_vcs.ethernet",
    "awesome_vunit_vcs.ethernet.lowlevel",
    "awesome_vunit_vcs.common.property",
    "awesome_vunit_vcs.flash",
    "awesome_vunit_vcs.records",
    "awesome_vunit_vcs.gen_vhdl",
)


@pytest.mark.parametrize("module_name", PUBLIC_MODULES)
def test_every_public_python_name_is_in_the_api_reference(module_name: str) -> None:
    module = importlib.import_module(module_name)
    pages = [(DOCS / section / "python_api.rst").read_text(encoding="utf-8") for section in SECTIONS]
    automodules = set(
        re.findall(
            r"^\.\. automodule:: (\S+)\n(?:   :[\w-]+:[^\n]*\n)*?   :members:\s*$", "\n".join(pages), re.MULTILINE
        )
    )
    if module_name in automodules:
        return
    text = "\n".join(pages)
    missing = [name for name in module.__all__ if not re.search(rf"\b{re.escape(name)}\b", text)]
    assert not missing, f"Document in a python_api.rst page: {', '.join(missing)}"


def test_no_concepts_section() -> None:
    assert not (DOCS / "explanation").exists(), "Technical concepts belong in ARCHITECTURE.md"


def test_docs_hold_no_benchmarks_design_records_or_spec_citations() -> None:
    patterns = {
        "benchmark timing": r"\b\d+(\.\d+)?\s*(µs|us per|ms per)\b|[Ww]all clock",
        "design decision records": r"^Design decisions?\n[=~-]{3,}$",
        "specification clause citations": r"IEEE 802\.3[a-z]*\s+(Clause|Table|\d+\.\d)|JESD216[A-Z]?\s+(section|table)",
    }
    offenders = []
    for page in sorted(DOCS.rglob("*.rst")):
        if "_generated" in page.parts or "_build" in page.parts:
            continue
        text = page.read_text(encoding="utf-8")
        offenders += [
            f"{page.relative_to(REPO)}: {what}"
            for what, pattern in patterns.items()
            if re.search(pattern, text, re.MULTILINE)
        ]
    assert not offenders, "Move these to ARCHITECTURE.md: " + "; ".join(offenders)


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


#: A count of data in bytes, which Ethernet material gives in octets
_BYTE = re.compile(r"\bbytes?\b")
#: In Python sources ``bytes`` is also the name of a type, so only a byte and a number of bytes count
_PYTHON_BYTE = re.compile(r"\bbyte\b|\d[\d_,]*[\s-]+bytes\b")
#: Inline code, which names objects such as ``bytes()`` rather than counting data
_CODE_SPAN = re.compile(r"``.*?``", re.DOTALL)
#: The Ethernet pages outside ``docs/ethernet``, by name
_ETHERNET_PAGES = ("getting_started/quickstart.rst",)
_ETHERNET_SUFFIXES = {".md", ".py", ".rst", ".vhd"}


def _ethernet_material(repo: Path) -> list[Path]:
    """
    The documentation and sources of the Ethernet family: ``docs/ethernet``, the Ethernet pages outside
    it, and the Python and VHDL sources of the family.
    """
    docs = repo / "docs"
    package = repo / "src" / "awesome_vunit_vcs"
    trees = [docs / "ethernet", package / "ethernet", package / "vhdl" / "ethernet"]
    files = {
        path
        for tree in trees
        if tree.is_dir()
        for path in tree.rglob("*")
        if path.is_file() and path.suffix in _ETHERNET_SUFFIXES
    }
    files |= {docs / name for name in _ETHERNET_PAGES if (docs / name).is_file()}
    return sorted(files)


def _octet_offenders(repo: Path) -> list[str]:
    """The Ethernet material of repo that counts data in bytes."""
    offenders = []
    for path in _ethernet_material(repo):
        text = _CODE_SPAN.sub("", path.read_text(encoding="utf-8"))
        pattern = _PYTHON_BYTE if path.suffix == ".py" else _BYTE
        if pattern.search(text):
            offenders.append(path.relative_to(repo).as_posix())
    return offenders


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def test_the_octet_guardrail_checks_ethernet_material(tmp_path: Path) -> None:
    package = tmp_path / "src" / "awesome_vunit_vcs"
    _write(tmp_path / "docs" / "ethernet" / "checks.rst", "A frame of 64 bytes.\n")
    _write(tmp_path / "docs" / "getting_started" / "quickstart.rst", "One byte per clock cycle.\n")
    _write(tmp_path / "docs" / "ethernet" / "notes-mii.md", "Frames are counted in octets.\n")
    _write(package / "vhdl" / "ethernet" / "gmii_pkg.vhd", "-- A preamble of 7 bytes\n")
    _write(package / "ethernet" / "frame.py", '"""A 4-byte FCS."""\n\n\ndef fcs(data: bytes) -> bytes: ...\n')
    _write(
        package / "ethernet" / "api.py", 'def frame(data: bytes) -> None:\n    """Anything ``bytes()`` accepts."""\n'
    )
    assert set(_octet_offenders(tmp_path)) == {
        "docs/ethernet/checks.rst",
        "docs/getting_started/quickstart.rst",
        "src/awesome_vunit_vcs/vhdl/ethernet/gmii_pkg.vhd",
        "src/awesome_vunit_vcs/ethernet/frame.py",
    }


def test_the_octet_guardrail_leaves_out_the_flash_family(tmp_path: Path) -> None:
    package = tmp_path / "src" / "awesome_vunit_vcs"
    _write(tmp_path / "docs" / "flash" / "qspi_flash.rst", "A 16 MiB part holds 16777216 bytes.\n")
    _write(tmp_path / "docs" / "flash" / "python.rst", "One bridge call per byte on the bus.\n")
    _write(package / "vhdl" / "flash" / "flash_pkg.vhd", "-- A vector of whole bytes\n")
    _write(package / "flash" / "device.py", "# One byte at a time\n")
    assert _octet_offenders(tmp_path) == []


def test_ethernet_data_is_counted_in_octets() -> None:
    assert _ethernet_material(REPO), "No Ethernet material found"
    assert not _octet_offenders(REPO)


def _literalincludes() -> list[tuple[Path, Path, dict[str, str]]]:
    includes = []
    for page in sorted(DOCS.rglob("*.rst")):
        if "_generated" in page.parts:
            continue
        text = page.read_text(encoding="utf-8")
        for match in re.finditer(r"^\.\. literalinclude:: (\S+)\n((?:[ \t]+:[\w-]+:[^\n]*\n)*)", text, re.MULTILINE):
            options = dict(re.findall(r":([\w-]+):[ \t]*([^\n]*)", match[2]))
            includes.append((page, (page.parent / match[1]).resolve(), options))
    return includes


def test_no_include_selects_lines_by_number() -> None:
    offenders = [
        f"{page.relative_to(REPO)}: {path.name}" for page, path, options in _literalincludes() if "lines" in options
    ]
    assert not offenders, "Use docs-start/docs-end markers instead of :lines:"


def test_every_include_marker_exists_exactly_once() -> None:
    offenders = []
    for page, path, options in _literalincludes():
        text = path.read_text(encoding="utf-8")
        for option in ("start-after", "end-before"):
            if option not in options:
                continue
            count = text.count(options[option])
            if count != 1:
                offenders.append(f"{page.relative_to(REPO)}: {options[option]!r} occurs {count} times in {path.name}")
    assert not offenders, "Every marker must be unique; a marker that is a prefix of another one also matches it"


def test_no_include_comes_from_the_test_suite() -> None:
    offenders = [
        f"{page.relative_to(REPO)}: {path.relative_to(REPO)}"
        for page, path, _ in _literalincludes()
        if (REPO / "tests") in path.parents
    ]
    assert not offenders, "Include tested examples from examples/, not the test suite"


def test_every_example_is_in_the_cookbook() -> None:
    index = (DOCS / "cookbook" / "index.rst").read_text(encoding="utf-8")
    examples = sorted(path.name for path in (REPO / "examples").iterdir() if path.is_dir())
    missing = [name for name in examples if f"examples/{name}" not in index]
    assert not missing, "Add these examples to the table in docs/cookbook/index.rst"
