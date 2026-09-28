"""
Guardrails that keep the documentation true to the code.

Tests marked xfail wait for documentation work in progress. Remove the marker when it
lands so the guardrail blocks regressions.
"""

from __future__ import annotations

import ast
import builtins
import importlib
import importlib.util
import re
import sys
import textwrap
from pathlib import Path
from types import ModuleType, SimpleNamespace

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
SECTIONS = ("ethernet", "property_testing", "flash", "i2c", "axi4", "common")


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
    "awesome_vunit_vcs.i2c",
    "awesome_vunit_vcs.axi4",
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
    # Comments may hold semicolons, such as the tHD;STA of I2C
    text = re.sub(r"--[^\n]*", "", vhdl_package.read_text(encoding="utf-8"))
    match = re.search(r"type\s+\w+_check_t\s+is\s*\((?P<literals>[^;]*?)\)\s*;", text, re.IGNORECASE | re.DOTALL)
    assert match is not None, f"No check type in {vhdl_package.name}"
    return {literal.strip().upper() for literal in match["literals"].split(",") if literal.strip()}


def test_vhdl_checks_are_the_python_check_ids() -> None:
    from awesome_vunit_vcs.ethernet.checker import CheckId

    packages = [path for path in (VHDL / "ethernet").glob("*_pkg.vhd") if re.search(r"_check_t\s+is", path.read_text())]
    assert packages, "No VHDL package declares the Ethernet checks"
    vhdl_checks: set[str] = set()
    for package in packages:
        vhdl_checks |= _check_literals(package)
    assert vhdl_checks == {check.value.upper() for check in CheckId}


def test_vhdl_i2c_checks_are_the_python_check_ids() -> None:
    from awesome_vunit_vcs.i2c import I2cCheckId

    assert _check_literals(VHDL / "i2c" / "i2c_pkg.vhd") == {check.value for check in I2cCheckId}


def test_every_i2c_check_is_in_the_checks_table() -> None:
    from awesome_vunit_vcs.i2c import I2cCheckId

    table = (DOCS / "i2c" / "i2c_protocol_checker.rst").read_text(encoding="utf-8")
    missing = [check.value for check in I2cCheckId if f"``{check.value.lower()}``" not in table]
    assert not missing


def test_vhdl_axi4_checks_are_the_python_check_ids() -> None:
    from awesome_vunit_vcs.axi4 import Axi4CheckId

    assert _check_literals(VHDL / "axi4" / "axi4_pkg.vhd") == {check.value for check in Axi4CheckId}


def test_every_axi4_check_is_in_the_checks_table() -> None:
    from awesome_vunit_vcs.axi4 import Axi4CheckId

    table = (DOCS / "axi4" / "axi4_protocol_checker.rst").read_text(encoding="utf-8")
    missing = [check.value for check in Axi4CheckId if f"``{check.value.lower()}``" not in table]
    assert not missing


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
        pattern = r"^[ \t]*\.\. literalinclude:: (\S+)\n((?:[ \t]+:[\w-]+:[^\n]*\n)*)"
        for match in re.finditer(pattern, text, re.MULTILINE):
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


_TESTBENCH_HELPERS = {
    "apply": "property-helper-apply",
    "item": "property-helper-item",
    "new_example": "property-helper-new-example",
    "pulse": "property-helper-pulse",
}


def _included_text(path: Path, options: dict[str, str]) -> str:
    text = path.read_text(encoding="utf-8")
    if "start-after" in options:
        text = text.split(options["start-after"], 1)[-1]
    if "end-before" in options:
        text = text.split(options["end-before"], 1)[0]
    return text


def test_testbench_helpers_are_linked_where_they_are_used() -> None:
    """A page showing code that calls a testbench helper links to where the helper is defined."""
    offenders = set()
    for page, path, options in _literalincludes():
        included = _included_text(path, options)
        page_text = page.read_text(encoding="utf-8")
        for helper, label in _TESTBENCH_HELPERS.items():
            if re.search(rf"\b{helper}\s*\(", included) and label not in page_text:
                offenders.add(f"{page.relative_to(REPO)}: {helper}")
    assert not offenders, f"link these helpers to their definition with :ref:: {sorted(offenders)}"


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


_FAMILY_CONTEXT = re.compile(r"context\s+awesome_vunit_vcs\.(ethernet|flash|i2c|axi4|property)_context\b")
_INCLUDED_CONTEXT = re.compile(
    r"context\s+(vunit_lib\.vunit_context|vunit_lib\.com_context|python_bridge\.python_context)\b"
)


def test_family_contexts_are_used_alone() -> None:
    """A family context includes VUnit's and the bridge's contexts, so examples and docs don't repeat them."""
    offenders = []
    sources = [*REPO.glob("examples/**/*.vhd"), *DOCS.rglob("*.rst")]
    for path in sources:
        text = path.read_text(encoding="utf-8")
        if _FAMILY_CONTEXT.search(text) and _INCLUDED_CONTEXT.search(text):
            offenders.append(str(path.relative_to(REPO)))
    assert not offenders, f"these repeat contexts a family context already includes: {offenders}"


def test_included_code_never_shows_docs_markers(tmp_path: Path) -> None:
    """A region that contains a smaller region's markers is rendered without them."""
    code = pytest.importorskip("sphinx.directives.code", reason="the docs build dependencies are not installed")
    LiteralIncludeReader = code.LiteralIncludeReader

    spec = importlib.util.spec_from_file_location("docs_conf", REPO / "docs" / "conf.py")
    assert spec is not None and spec.loader is not None
    conf = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conf)
    conf._install_marker_filter()
    config = SimpleNamespace(source_encoding="utf-8")

    source = tmp_path / "tb.vhd"
    source.write_text(
        "-- docs-start: outer\na <= b;\n-- docs-start: inner\nc <= d;\n  # docs-end: inner\n-- docs-end: outer\n"
    )
    options = {"start-after": "-- docs-start: outer", "end-before": "-- docs-end: outer"}
    text, _ = LiteralIncludeReader(str(source), options, config).read()  # type: ignore[arg-type]
    assert text == "a <= b;\nc <= d;\n"

    leaks = []
    for page, path, include_options in _literalincludes():
        reader_options: dict[str, object] = dict(include_options)
        if "dedent" in reader_options:
            reader_options["dedent"] = int(include_options["dedent"]) if include_options["dedent"] else None
        reader = LiteralIncludeReader(str(path), reader_options, config)  # type: ignore[arg-type]
        included, _ = reader.read()
        if re.search(r"docs-(start|end):", included):
            leaks.append(f"{page.relative_to(REPO)}: {path.name}")
    assert not leaks, f"Includes that show docs markers: {leaks}"


def _page_text(page: Path) -> str:
    """The text of a page with the shared notes it includes appended."""
    text = page.read_text(encoding="utf-8")
    for match in re.finditer(r"^[ \t]*\.\. include:: (\S+)$", text, re.MULTILINE):
        include = (page.parent / match[1]).resolve()
        if include.suffix == ".inc" and "_generated" not in include.parts and include.is_file():
            text += "\n" + include.read_text(encoding="utf-8")
    return text


def _mentioned(name: str, text: str) -> bool:
    """Whether name appears in inline code or in a link or role of a page."""
    word = re.escape(name)
    return re.search(rf"``[^`\n]*\b{word}\b[^`\n]*``|`[^`\n]*\b{word}\b[^`\n]*`", text, re.IGNORECASE) is not None


def _without_code(text: str) -> str:
    """The prose of a page: blocks that show code are dropped."""
    kept: list[str] = []
    block_indent: int | None = None
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip())
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        if re.match(r"\s*\.\. (code-block|literalinclude)::", line):
            block_indent = indent
            continue
        kept.append(line)
    return "\n".join(kept)


_MODULE_NAMES = {"__file__", "__name__", "__doc__"}


def _python_snippet(path: Path, options: dict[str, str]) -> str:
    if "pyobject" in options:
        source = path.read_text(encoding="utf-8")
        for node in ast.parse(source).body:
            if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name == options["pyobject"]:
                return ast.get_source_segment(source, node, padded=True) or ""
        return ""
    return textwrap.dedent(_included_text(path, options))


def _bound_names(tree: ast.AST) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and not isinstance(node.ctx, ast.Load):
            names.add(node.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names |= {(alias.asname or alias.name).split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
    return names


def test_python_snippets_define_the_names_they_use() -> None:
    """A Python snippet defines, imports or explains on its page every name it uses."""
    snippets: list[tuple[Path, Path, ast.Module]] = []
    for page, path, options in _literalincludes():
        if path.suffix != ".py":
            continue
        try:
            snippets.append((page, path, ast.parse(_python_snippet(path, options))))
        except SyntaxError:
            continue  # a fragment, such as the start of a multi-line statement
    shown: dict[Path, set[str]] = {}
    for page, _, tree in snippets:
        shown.setdefault(page, set()).update(_bound_names(tree))
    offenders = set()
    for page, path, tree in snippets:
        # a name is defined by any snippet on the page; names the file imports are conventional (st, Path)
        allowed = shown[page] | _imported_names(path) | set(dir(builtins)) | _MODULE_NAMES
        text = _without_code(_page_text(page))
        used = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)}
        offenders |= {f"{page.relative_to(REPO)}: {name}" for name in used - allowed if not _mentioned(name, text)}
    assert not offenders, f"define, import or explain these names where the snippet is shown: {sorted(offenders)}"


def _imported_names(path: Path) -> set[str]:
    return {
        (alias.asname or alias.name).split(".")[0]
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8")))
        if isinstance(node, (ast.Import, ast.ImportFrom))
        for alias in node.names
    }


def test_run_commands_keep_output_out_of_the_checkout() -> None:
    sources = [page for page in DOCS.rglob("*.rst") if "_generated" not in page.parts and "_build" not in page.parts]
    sources += [REPO / name for name in ("README.md", "CONTRIBUTING.md", "AGENTS.md")]
    offenders = [
        f"{path.relative_to(REPO)}:{number}"
        for path in sources
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
        if re.search(r"python\S*\s+\S*run\.py\b", line) and "--output-path" not in line
    ]
    assert not offenders, f"add --output-path so these runs write outside the checkout: {offenders}"


#: Standard VHDL names that VUnit's packages overload; readers know them without a note
_STANDARD_VHDL_NAMES = {"to_integer", "to_string", "to_hstring", "to_ostring", "resize", "write", "read"}

_VHDL_DECLARATION = re.compile(
    r"^\s*(?:impure\s+|pure\s+)?(procedure|function|type|subtype|alias)\s+(\w+)", re.IGNORECASE | re.MULTILINE
)


def _vunit_names() -> dict[str, str]:
    """VUnit's public subprograms and types that the examples may use, by kind."""
    spec = importlib.util.find_spec("vunit")
    if spec is None or spec.origin is None:
        pytest.skip("VUnit is not installed")
    vhdl = Path(spec.origin).parent / "vhdl"
    files = [
        *vhdl.glob("check/src/check*.vhd"),
        *vhdl.glob("logging/src/*_pkg.vhd"),
        *vhdl.glob("run/src/run*.vhd"),
        vhdl / "com" / "src" / "com_api.vhd",
        vhdl / "com" / "src" / "com_types.vhd",
        *vhdl.glob("data_types/src/*_pkg.vhd"),
        vhdl / "verification_components" / "src" / "sync_pkg.vhd",
    ]
    names: dict[str, str] = {}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        declarations = re.split(r"^\s*package\s+body\b", text, flags=re.IGNORECASE | re.MULTILINE)[0]
        for kind, name in _VHDL_DECLARATION.findall(declarations):
            names.setdefault(name.lower(), kind.lower())
    names["randomptype"] = "type"  # OSVVM
    ours = {name.lower() for path in VHDL.rglob("*.vhd") for _, name in _VHDL_DECLARATION.findall(path.read_text())}
    return {name: kind for name, kind in names.items() if name not in ours and name not in _STANDARD_VHDL_NAMES}


def _vhdl_code(page: Path, includes: list[tuple[Path, Path, dict[str, str]]]) -> str:
    code = [
        _included_text(path, options)
        for include_page, path, options in includes
        if include_page == page and (path.suffix == ".vhd" or options.get("language") == "vhdl")
    ]
    lines = page.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"(\s*)\.\. code-block:: vhdl", line)
        if match:
            block = []
            for body in lines[index + 1 :]:
                if body.strip() and len(body) - len(body.lstrip()) <= len(match[1]):
                    break
                block.append(body)
            code.append("\n".join(block))
    return re.sub(r"--[^\n]*", "", "\n".join(code))


def test_vunit_names_are_explained_where_they_are_used() -> None:
    """VUnit's subprograms and types in a page's VHDL are named in its VUnit note or linked."""
    vunit = _vunit_names()
    includes = _literalincludes()
    offenders = {}
    for page in sorted(DOCS.rglob("*.rst")):
        if "_generated" in page.parts or "_build" in page.parts:
            continue
        code = _vhdl_code(page, includes)
        used = {
            match[1].lower()
            for match in re.finditer(r"\b(\w+)\s*\(", code)
            if vunit.get(match[1].lower()) in {"procedure", "function", "alias"}
        }
        used |= {
            match[1].lower()
            for match in re.finditer(r":\s*(?:in\s+|out\s+|inout\s+)?(\w+)", code)
            if vunit.get(match[1].lower()) in {"type", "subtype"}
        }
        text = _without_code(_page_text(page))
        missing = sorted(name for name in used if not _mentioned(name, text))
        if missing:
            offenders[str(page.relative_to(REPO))] = missing
    assert not offenders, f"name these in the VUnit note (docs/_includes/vunit_names.inc) or link them: {offenders}"
