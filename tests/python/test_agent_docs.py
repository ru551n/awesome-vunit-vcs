# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The files for AI agents: api/*.json from tools/api_index.py and llms.txt from tools/llms_docs.py."""

from __future__ import annotations

import importlib
import importlib.util
import json
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

REPO = Path(__file__).resolve().parents[2]
DOCS = REPO / "docs"
BASE_URL = "https://awesome-vunit-vcs.readthedocs.io/en/latest/"


def _load(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, REPO / "tools" / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Registered before running it: dataclasses look their module up in sys.modules
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return sys.modules[name]


@pytest.fixture(scope="module")
def api_files(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    api_index = _load("api_index")
    output = tmp_path_factory.mktemp("api")
    api_index.generate(output)
    return {path.name: json.loads(path.read_text(encoding="utf-8")) for path in (output / "api").rglob("*.json")}


@pytest.mark.parametrize("name", ["vhdl", "python", "examples"])
def test_api_files_follow_their_schema(api_files: dict[str, Any], name: str) -> None:
    jsonschema = pytest.importorskip("jsonschema")
    schema = api_files[f"{name}.schema.json"]
    jsonschema.Draft202012Validator.check_schema(schema)
    jsonschema.validate(api_files[f"{name}.json"], schema)


def test_every_public_vhdl_declaration_is_in_the_vhdl_index(api_files: dict[str, Any]) -> None:
    vhdl_docs = _load("vhdl_docs")
    indexed = {
        (unit["name"], declaration["name"])
        for family in api_files["vhdl.json"]["families"]
        for unit in family["units"]
        for declaration in unit["declarations"]
    }
    units = {unit["name"] for family in api_files["vhdl.json"]["families"] for unit in family["units"]}
    missing = []
    for path in sorted((REPO / "src" / "awesome_vunit_vcs" / "vhdl").rglob("*.vhd")):
        for unit in vhdl_docs.parse_file(path):
            if unit.name not in units:
                missing.append(unit.name)
            missing += [
                f"{unit.name}.{item.name}" for item in unit.declarations if (unit.name, item.name) not in indexed
            ]
    assert not missing, f"Missing from api/vhdl.json: {missing}"


def test_every_public_python_name_is_in_the_python_index(api_files: dict[str, Any]) -> None:
    api_index = _load("api_index")
    modules = {
        module["name"]: {member["name"] for member in module["members"]}
        for module in api_files["python.json"]["modules"]
    }
    missing = []
    for module_name in api_index.PUBLIC_MODULES:
        module = importlib.import_module(module_name)
        names = getattr(module, "__all__", None)
        if names is None:
            continue
        missing += [f"{module_name}.{name}" for name in names if name not in modules.get(module_name, set())]
    assert not missing, f"Missing from api/python.json: {missing}"


def test_the_python_index_covers_the_documented_public_modules() -> None:
    api_index = _load("api_index")
    spec = importlib.util.spec_from_file_location("test_docs", REPO / "tests" / "python" / "test_docs.py")
    assert spec is not None and spec.loader is not None
    test_docs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(test_docs)
    assert set(test_docs.PUBLIC_MODULES) <= set(api_index.PUBLIC_MODULES)


def test_every_cookbook_example_exists_with_its_test(api_files: dict[str, Any]) -> None:
    tasks = api_files["examples.json"]["tasks"]
    assert tasks, "api/examples.json lists no cookbook tasks"
    problems = []
    for task in tasks:
        assert task["url"].startswith(BASE_URL + "cookbook/")
        for example in task["examples"]:
            path = REPO / example["file"]
            text = path.read_text(encoding="utf-8") if path.exists() else ""
            if not text:
                problems.append(f"{task['task']}: {example['file']} does not exist")
            elif example["marker"] and example["marker"].strip() not in text:
                problems.append(f"{task['task']}: no {example['marker']} in {example['file']}")
            elif example["test"] and f'run("{example["test"]}")' not in text:
                problems.append(f"{task['task']}: no test case {example['test']} in {example['file']}")
    assert not problems, problems
    # Most tasks show code from a test case, so a reader can run exactly that case
    with_tests = sum(1 for task in tasks for example in task["examples"] if example["test"])
    assert with_tests >= len(tasks) // 2


_MARKER_LINE = re.compile(r"^\s*(--|#)\s*docs-(start|end):", re.MULTILINE)


@pytest.fixture(scope="module")
def llms_output(tmp_path_factory: pytest.TempPathFactory) -> Path:
    pytest.importorskip("sphinx_markdown_builder", reason="the docs build dependencies are not installed")
    llms_docs = _load("llms_docs")
    output = tmp_path_factory.mktemp("llms")
    llms_docs.build(DOCS, output, BASE_URL)
    return output


def _toctree_pages() -> list[str]:
    """Every page reachable from the navigation, by its docname."""
    pages = []
    for rst in sorted(DOCS.rglob("*.rst")):
        relative = rst.relative_to(DOCS)
        if relative.parts[0].startswith("_") or (relative.parts[0] == "release_notes" and rst.stem != "index"):
            continue
        pages.append(relative.with_suffix("").as_posix())
    return pages


def test_llms_txt_links_every_page(llms_output: Path) -> None:
    llms = (llms_output / "llms.txt").read_text(encoding="utf-8")
    assert llms.startswith("# awesome-vunit-vcs\n\n> ")
    for heading in (
        "Getting started",
        "Cookbook",
        "Ethernet",
        "Property-based testing",
        "Flash / QSPI",
        "Common",
        "API reference",
    ):
        assert f"\n## {heading}\n" in llms
    missing = [page for page in _toctree_pages() if page != "index" and f"]({BASE_URL}{page}.md)" not in llms]
    assert not missing, f"llms.txt does not link: {missing}"
    for name in ("api/vhdl.json", "api/python.json", "api/examples.json"):
        assert f"]({BASE_URL}{name})" in llms


def test_llms_full_txt_has_every_page_in_reading_order(llms_output: Path) -> None:
    full = (llms_output / "llms-full.txt").read_text(encoding="utf-8")
    sources = re.findall(r"^Source: " + re.escape(BASE_URL) + r"(\S+)\.html$", full, re.MULTILINE)
    missing = [page for page in _toctree_pages() if page != "index" and page not in sources]
    assert not missing, f"llms-full.txt does not contain: {missing}"
    assert sources.index("getting_started/quickstart") < sources.index("cookbook/first_test")
    assert sources.index("cookbook/first_test") < sources.index("cookbook/property_errors")
    first_api = min(index for index, page in enumerate(sources) if page.endswith(("vhdl_api", "python_api")))
    assert all(not page.endswith(("vhdl_api", "python_api")) for page in sources[:first_api])
    assert not _MARKER_LINE.search(full), "llms-full.txt shows docs markers"
    # Included code is resolved and keeps its file name
    assert "**examples/quickstart/run.py**" in full
    assert 'vu.add_package("awesome-vunit-vcs")' in full
    assert not re.search(r"^\s*\.\. literalinclude::", full, re.MULTILINE)


def test_every_page_has_a_markdown_version(llms_output: Path) -> None:
    missing = [page for page in _toctree_pages() if not (llms_output / f"{page}.md").exists()]
    assert not missing, f"No Markdown version of: {missing}"
    assert not _MARKER_LINE.search((llms_output / "cookbook" / "first_test.md").read_text(encoding="utf-8"))
