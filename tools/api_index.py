# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Write the machine-readable API index published with the documentation.

* ``api/vhdl.json``: every VHDL package, context and entity with its declarations, parameters,
  generics, ports and doc comments, parsed like the VHDL reference (tools/vhdl_docs.py).
* ``api/python.json``: the public Python API, the ``__all__`` of every public module, with
  signatures, parameters and docstrings.
* ``api/examples.json``: every task heading of the cookbook with its page, example files,
  test cases and the command that runs them.
* ``api/schema/*.schema.json``: a JSON Schema for each file.

Every file has a ``schema_version``; it changes only when a field is renamed or removed. docs/conf.py
writes the files when the build starts.

Run standalone::

    python tools/api_index.py <output directory>
"""

from __future__ import annotations

import enum
import importlib
import inspect
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

import vhdl_docs  # noqa: E402

SCHEMA_VERSION = 1
BASE_URL = "https://awesome-vunit-vcs.readthedocs.io/en/latest/"

#: Public Python modules, in the order they are documented
PUBLIC_MODULES = (
    "awesome_vunit_vcs",
    "awesome_vunit_vcs.errors",
    "awesome_vunit_vcs.ethernet",
    "awesome_vunit_vcs.ethernet.lowlevel",
    "awesome_vunit_vcs.ethernet.traffic",
    "awesome_vunit_vcs.common.vunit_bridge",
    "awesome_vunit_vcs.common.backend",
    "awesome_vunit_vcs.common.property",
    "awesome_vunit_vcs.records",
    "awesome_vunit_vcs.gen_vhdl",
    "awesome_vunit_vcs.flash",
    "awesome_vunit_vcs.i2c",
    "awesome_vunit_vcs.axi4",
)

# -- Schemas ------------------------------------------------------------------

_STRING = {"type": "string"}
_STRINGS = {"type": "array", "items": _STRING}
_PARAMETER = {
    "type": "object",
    "required": ["names", "mode", "type", "default", "comment"],
    "properties": {
        "names": _STRINGS,
        "mode": _STRING,
        "type": _STRING,
        "default": _STRING,
        "comment": _STRING,
    },
    "additionalProperties": False,
}

VHDL_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "awesome-vunit-vcs VHDL API index",
    "type": "object",
    "required": ["schema_version", "project", "families"],
    "properties": {
        "schema_version": {"const": SCHEMA_VERSION},
        "project": _STRING,
        "families": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["name", "library", "context", "units"],
                "properties": {
                    "name": _STRING,
                    "library": _STRING,
                    "context": _STRING,
                    "units": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["kind", "name", "source", "description", "generics", "ports", "declarations"],
                            "properties": {
                                "kind": {"enum": ["package", "entity", "context"]},
                                "name": _STRING,
                                "source": _STRING,
                                "description": _STRING,
                                "generics": {"type": "array", "items": _PARAMETER},
                                "ports": {"type": "array", "items": _PARAMETER},
                                "declarations": {
                                    "type": "array",
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "kind",
                                            "name",
                                            "section",
                                            "code",
                                            "comment",
                                            "parameters",
                                            "returns",
                                        ],
                                        "properties": {
                                            "kind": _STRING,
                                            "name": _STRING,
                                            "section": _STRING,
                                            "code": _STRING,
                                            "comment": _STRING,
                                            "parameters": {"type": "array", "items": _PARAMETER},
                                            "returns": _STRING,
                                        },
                                        "additionalProperties": False,
                                    },
                                },
                            },
                            "additionalProperties": False,
                        },
                    },
                },
                "additionalProperties": False,
            },
        },
    },
    "additionalProperties": False,
}

_PY_PARAMETER = {
    "type": "object",
    "required": ["name", "kind", "annotation", "default"],
    "properties": {
        "name": _STRING,
        "kind": {"enum": ["positional_only", "positional_or_keyword", "var_positional", "keyword_only", "var_keyword"]},
        "annotation": {"type": ["string", "null"]},
        "default": {"type": ["string", "null"]},
    },
    "additionalProperties": False,
}
_PY_CALLABLE = {
    "type": "object",
    "required": ["name", "signature", "parameters", "returns", "doc"],
    "properties": {
        "name": _STRING,
        "signature": _STRING,
        "parameters": {"type": "array", "items": _PY_PARAMETER},
        "returns": {"type": ["string", "null"]},
        "doc": _STRING,
    },
    "additionalProperties": False,
}

PYTHON_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "awesome-vunit-vcs Python API index",
    "type": "object",
    "required": ["schema_version", "project", "modules"],
    "properties": {
        "schema_version": {"const": SCHEMA_VERSION},
        "project": _STRING,
        "modules": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["name", "doc", "members"],
                "properties": {
                    "name": _STRING,
                    "doc": _STRING,
                    "members": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["name", "kind", "defined_in", "doc"],
                            "properties": {
                                "name": _STRING,
                                "kind": {"enum": ["class", "enum", "function", "module", "constant"]},
                                "defined_in": _STRING,
                                "doc": _STRING,
                                "signature": _STRING,
                                "parameters": {"type": "array", "items": _PY_PARAMETER},
                                "returns": {"type": ["string", "null"]},
                                "value": _STRING,
                                "members": _STRINGS,
                                "methods": {"type": "array", "items": _PY_CALLABLE},
                            },
                            "additionalProperties": False,
                        },
                    },
                },
                "additionalProperties": False,
            },
        },
    },
    "additionalProperties": False,
}

EXAMPLES_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "awesome-vunit-vcs cookbook task index",
    "type": "object",
    "required": ["schema_version", "project", "base_url", "tasks"],
    "properties": {
        "schema_version": {"const": SCHEMA_VERSION},
        "project": _STRING,
        "base_url": _STRING,
        "tasks": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["task", "article", "url", "examples"],
                "properties": {
                    "task": _STRING,
                    "article": _STRING,
                    "url": _STRING,
                    "examples": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["file", "language", "marker", "test", "run"],
                            "properties": {
                                "file": _STRING,
                                "language": {"enum": ["vhdl", "python", "text"]},
                                "marker": {"type": ["string", "null"]},
                                "test": {"type": ["string", "null"]},
                                "run": {"type": ["string", "null"]},
                            },
                            "additionalProperties": False,
                        },
                    },
                },
                "additionalProperties": False,
            },
        },
    },
    "additionalProperties": False,
}

# -- VHDL ---------------------------------------------------------------------


def _parameter(parameter: vhdl_docs.Parameter) -> dict[str, Any]:
    return {
        "names": list(parameter.names),
        "mode": parameter.mode,
        "type": parameter.type,
        "default": parameter.default,
        "comment": "\n".join(parameter.comment).strip(),
    }


def vhdl_index(vhdl_root: Path = ROOT / "src" / "awesome_vunit_vcs" / "vhdl") -> dict[str, Any]:
    families = []
    for family_dir in sorted(path for path in vhdl_root.iterdir() if path.is_dir()):
        family = family_dir.name
        units = []
        for path in sorted(family_dir.glob("*.vhd"), key=lambda path: vhdl_docs._unit_order(path, family)):
            for unit in vhdl_docs.parse_file(path):
                declarations = []
                section = ""
                for item in unit.items:
                    if isinstance(item, vhdl_docs.Section):
                        section = item.title
                        continue
                    declarations.append(
                        {
                            "kind": item.kind,
                            "name": item.name,
                            "section": section,
                            "code": item.code,
                            "comment": "\n".join(item.comment).strip(),
                            "parameters": [_parameter(p) for p in item.parameters],
                            "returns": item.returns,
                        }
                    )
                units.append(
                    {
                        "kind": unit.kind,
                        "name": unit.name,
                        "source": path.relative_to(ROOT).as_posix(),
                        "description": "\n".join(unit.description).strip(),
                        "generics": [_parameter(p) for p in unit.generics],
                        "ports": [_parameter(p) for p in unit.ports],
                        "declarations": declarations,
                    }
                )
        families.append(
            {
                "name": family,
                "library": "awesome_vunit_vcs",
                "context": f"awesome_vunit_vcs.{family}_context" if family != "common" else "",
                "units": units,
            }
        )
    return {"schema_version": SCHEMA_VERSION, "project": "awesome-vunit-vcs", "families": families}


# -- Python -------------------------------------------------------------------


def _annotation(value: Any) -> str | None:
    if value is inspect.Parameter.empty:
        return None
    return value if isinstance(value, str) else inspect.formatannotation(value)


def _callable(name: str, obj: Any) -> dict[str, Any]:
    try:
        signature = inspect.signature(obj)
    except (TypeError, ValueError):
        return {"name": name, "signature": "", "parameters": [], "returns": None, "doc": inspect.getdoc(obj) or ""}
    parameters = [
        {
            "name": parameter.name,
            "kind": parameter.kind.name.lower(),
            "annotation": _annotation(parameter.annotation),
            "default": None if parameter.default is inspect.Parameter.empty else repr(parameter.default),
        }
        for parameter in signature.parameters.values()
    ]
    return {
        "name": name,
        "signature": f"{name}{signature}",
        "parameters": parameters,
        "returns": _annotation(signature.return_annotation),
        "doc": inspect.getdoc(obj) or "",
    }


def _public_names(module: Any) -> list[str]:
    names = getattr(module, "__all__", None)
    if names is not None:
        return list(names)
    return [
        name
        for name, value in vars(module).items()
        if not name.startswith("_") and getattr(value, "__module__", None) == module.__name__
    ]


def _member(module: Any, name: str) -> dict[str, Any]:
    obj = getattr(module, name)
    defined_in = getattr(obj, "__module__", None) or module.__name__
    if inspect.ismodule(obj):
        return {"name": name, "kind": "module", "defined_in": obj.__name__, "doc": inspect.getdoc(obj) or ""}
    if inspect.isclass(obj):
        entry: dict[str, Any] = {
            "name": name,
            "kind": "enum" if issubclass(obj, enum.Enum) else "class",
            "defined_in": defined_in,
            "doc": inspect.getdoc(obj) or "",
        }
        entry.update({key: value for key, value in _callable(name, obj).items() if key in ("signature", "parameters")})
        if issubclass(obj, enum.Enum):
            entry["members"] = [member.name for member in obj]  # type: ignore[var-annotated]
        else:
            entry["methods"] = [
                _callable(method_name, method)
                for method_name, method in vars(obj).items()
                if not method_name.startswith("_")
                and (inspect.isfunction(method) or isinstance(method, (classmethod, staticmethod)))
                for method in [getattr(obj, method_name)]
            ]
        return entry
    if callable(obj):
        entry = {"name": name, "kind": "function", "defined_in": defined_in}
        entry.update({key: value for key, value in _callable(name, obj).items() if key != "name"})
        return entry
    return {"name": name, "kind": "constant", "defined_in": module.__name__, "doc": "", "value": repr(obj)}


def python_index(modules: tuple[str, ...] = PUBLIC_MODULES) -> dict[str, Any]:
    entries = []
    for module_name in modules:
        module = importlib.import_module(module_name)
        entries.append(
            {
                "name": module_name,
                "doc": inspect.getdoc(module) or "",
                "members": [_member(module, name) for name in _public_names(module)],
            }
        )
    return {"schema_version": SCHEMA_VERSION, "project": "awesome-vunit-vcs", "modules": entries}


# -- Cookbook tasks -----------------------------------------------------------

_UNDERLINE = re.compile(r"^([=\-~^\"'*+#])\1{2,}\s*$")
_INCLUDE = re.compile(r"^\.\. literalinclude:: (\S+)\s*$")
_OPTION = re.compile(r"^\s+:([\w-]+):\s*(.*)$")
_RUN = re.compile(r'run\("(test_[A-Za-z0-9_]+)"\)')


def _anchor(title: str) -> str:
    """The id docutils gives a section title (docutils.nodes.make_id), without importing docutils."""
    ascii_title = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode("ascii")
    anchor = re.sub(r"[^a-z0-9]+", "-", ascii_title.lower())
    return re.sub(r"^[^a-z]+|-+$", "", anchor)


def _test_for(path: Path, marker: str | None) -> str | None:
    if marker is None or path.suffix != ".vhd":
        return None
    lines = path.read_text(encoding="utf-8").splitlines()
    start = next((index for index, line in enumerate(lines) if line.strip() == marker.strip()), None)
    if start is None:
        return None
    end = next((index for index in range(start, len(lines)) if "docs-end:" in lines[index]), len(lines))
    inside = [_RUN.search(line) for line in lines[start:end]]
    found = [match.group(1) for match in inside if match]
    if found:
        return found[0]
    # The nearest test case above the region, unless an architecture or process starts in between
    for line in reversed(lines[:start]):
        match = _RUN.search(line)
        if match:
            return match.group(1)
        if re.match(r"^\s*(architecture|begin|signal|constant)\b", line) and "run(" not in line:
            return None
    return None


def _run_command(path: Path, test: str | None) -> str | None:
    relative = path.relative_to(ROOT)
    if relative.parts[0] != "examples":
        return None
    if path.suffix == ".py" and relative.parts[1] == "python":
        return f"python {relative.as_posix()}" if not path.name.startswith("test_") else f"pytest {relative.as_posix()}"
    project = ROOT / relative.parts[0] / relative.parts[1]
    if not (project / "run.py").exists():
        return None
    command = f"python examples/{relative.parts[1]}/run.py"
    return f"{command} '*.{test}'" if test else command


def examples_index(docs: Path = ROOT / "docs", base_url: str = BASE_URL) -> dict[str, Any]:
    tasks: list[dict[str, Any]] = []
    for page in sorted((docs / "cookbook").glob("*.rst")):
        lines = page.read_text(encoding="utf-8").splitlines()
        article = lines[0].strip() if lines else page.stem
        docname = page.relative_to(docs).with_suffix("").as_posix()
        current: dict[str, Any] | None = None
        for index, line in enumerate(lines):
            if (
                index + 1 < len(lines)
                and line.strip()
                and _UNDERLINE.match(lines[index + 1])
                and not _UNDERLINE.match(line)
            ):
                if len(lines[index + 1].strip()) >= len(line.strip()):
                    current = {
                        "task": line.strip(),
                        "article": article,
                        "url": f"{base_url}{docname}.html#{_anchor(line.strip())}",
                        "examples": [],
                    }
                    tasks.append(current)
                continue
            include = _INCLUDE.match(line)
            if not include or current is None:
                continue
            path = (page.parent / include.group(1)).resolve()
            if ROOT not in path.parents or not path.exists():
                continue
            options: dict[str, str] = {}
            for option_line in lines[index + 1 :]:
                option = _OPTION.match(option_line)
                if not option:
                    break
                options[option.group(1)] = option.group(2)
            marker = options.get("start-after")
            test = _test_for(path, marker)
            language = {".vhd": "vhdl", ".py": "python"}.get(path.suffix, "text")
            current["examples"].append(
                {
                    "file": path.relative_to(ROOT).as_posix(),
                    "language": language,
                    "marker": marker,
                    "test": test,
                    "run": _run_command(path, test),
                }
            )
    tasks = [task for task in tasks if task["examples"]]
    return {"schema_version": SCHEMA_VERSION, "project": "awesome-vunit-vcs", "base_url": base_url, "tasks": tasks}


# -- Output -------------------------------------------------------------------


def generate(output: Path, base_url: str = BASE_URL) -> list[Path]:
    """Write the index files and their schemas into ``<output>/api``."""
    api = output / "api"
    (api / "schema").mkdir(parents=True, exist_ok=True)
    files = {
        api / "vhdl.json": vhdl_index(),
        api / "python.json": python_index(),
        api / "examples.json": examples_index(base_url=base_url),
        api / "schema" / "vhdl.schema.json": VHDL_SCHEMA,
        api / "schema" / "python.schema.json": PYTHON_SCHEMA,
        api / "schema" / "examples.schema.json": EXAMPLES_SCHEMA,
    }
    for path, data in files.items():
        text = json.dumps(data, indent=1, ensure_ascii=False) + "\n"
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
    return list(files)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    for path in generate(Path(arguments[0])):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
