# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Generate the VHDL API reference of the documentation from the VHDL sources.

There is no VHDL domain for Sphinx, so the reference is generated from doc comments:

* The file header, the comment after the license lines, describes the design unit.
* A doc comment is the ``--`` block directly above a declaration of a package declaration,
  or above a generic or port of an entity, with no blank line in between. A comment above
  the first declaration of a group of declarations without blank lines documents the group.
* Doc comments are reStructuredText. An indented block becomes a literal block.
* A banner, a line of dashes, a ``-- Title`` line, optional text and another line of dashes,
  starts a section.

For every VHDL family directory (``src/awesome_vunit_vcs/vhdl/<family>``) one include file,
``<output>/<family>.inc``, documents all its design units. A reference page includes it, so
design units added to a family appear without editing the page. Declarations get
``.. vhdl::`` targets named ``<unit>.<name>``, referenced with ``:vhdl:`<unit>.<name>```.

Run from docs/conf.py when the build starts, or standalone::

    python tools/vhdl_docs.py <vhdl directory> <output directory>
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DECLARATION_START = re.compile(
    r"^\s*(?:(?:pure|impure)\s+)?(?P<kind>function|procedure|type|subtype|constant|alias|signal|file|component)"
    r"\s+(?P<name>\"[^\"]+\"|\w+)",
    re.IGNORECASE,
)
PACKAGE_START = re.compile(r"^\s*package\s+(?P<name>\w+)\s+is\b", re.IGNORECASE)
# "end;", "end package;", "end package name;" or "end name;", but not the end of a record
PACKAGE_END = re.compile(
    r"^\s*end(\s+package(\s+\w+)?|\s+(?!record\b|protected\b|units\b)\w+)?\s*;",
    re.IGNORECASE,
)
ENTITY_START = re.compile(r"^\s*entity\s+(?P<name>\w+)\s+is\b", re.IGNORECASE)
CONTEXT_START = re.compile(r"^\s*context\s+(?P<name>\w+)\s+is\b", re.IGNORECASE)
BANNER = re.compile(r"^\s*-{8,}\s*$")
LICENSE_LINE = re.compile(r"Mozilla Public|License, v\. 2\.0|mozilla\.org/MPL", re.IGNORECASE)


@dataclass
class Parameter:
    """A formal parameter of a subprogram, or a generic or port of an entity."""

    names: list[str]
    mode: str
    type: str
    default: str
    comment: list[str] = field(default_factory=list)


@dataclass
class Declaration:
    kind: str
    name: str
    code: str
    comment: list[str]
    parameters: list[Parameter] = field(default_factory=list)
    returns: str = ""
    # Documented by the comment above the first declaration of its group
    grouped: bool = False


@dataclass
class Section:
    title: str
    text: list[str]


@dataclass
class DesignUnit:
    kind: str  # package, entity or context
    name: str
    path: Path
    description: list[str]
    items: list[Declaration | Section] = field(default_factory=list)
    generics: list[Parameter] = field(default_factory=list)
    ports: list[Parameter] = field(default_factory=list)

    @property
    def declarations(self) -> list[Declaration]:
        return [item for item in self.items if isinstance(item, Declaration)]


def _comment_text(line: str) -> str | None:
    """The text of a comment-only line without the ``-- `` prefix, None for other lines."""
    stripped = line.strip()
    if not stripped.startswith("--"):
        return None
    text = stripped[2:]
    return text[1:] if text.startswith(" ") else text


def _strip_trailing_comment(line: str) -> str:
    in_string = False
    for index, char in enumerate(line):
        if char == '"':
            in_string = not in_string
        elif not in_string and line.startswith("--", index):
            return line[:index].rstrip()
    return line.rstrip()


def _header(lines: list[str]) -> list[str]:
    """The file header comment after the license lines."""
    header: list[str] = []
    for line in lines:
        text = _comment_text(line)
        if text is None:
            if line.strip():
                break
            if header:
                break
            continue
        if LICENSE_LINE.search(text):
            continue
        header.append(text)
    while header and not header[0].strip():
        header.pop(0)
    while header and not header[-1].strip():
        header.pop()
    return header


def _parse_parameter(text: str, comment: list[str]) -> Parameter | None:
    text = " ".join(text.split())
    if ":" not in text:
        return None
    names_part, rest = text.split(":", 1)
    names_words = names_part.split()
    if names_words and names_words[0].lower() in ("signal", "variable", "constant", "file"):
        class_word = names_words.pop(0).lower()
    else:
        class_word = ""
    names = [name.strip() for name in " ".join(names_words).split(",") if name.strip()]
    default = ""
    if ":=" in rest:
        rest, default = rest.split(":=", 1)
        default = default.strip()
        # The split above left the "=" of ":=" on the type side
    rest = rest.strip()
    if rest.startswith("="):
        rest = rest[1:].strip()
    mode = ""
    words = rest.split(maxsplit=1)
    if words and words[0].lower() in ("in", "out", "inout", "buffer", "linkage"):
        mode = words[0].lower()
        rest = words[1] if len(words) > 1 else ""
    if class_word:
        mode = f"{class_word} {mode}".strip()
    return Parameter(names=names, mode=mode, type=rest.strip(), default=default, comment=comment)


def _parameters_with_comments(lines: list[str]) -> list[Parameter]:
    """Parse the lines between the parentheses of a parameter, generic or port list."""
    parameters: list[Parameter] = []
    comment: list[str] = []
    pending = ""
    pending_comment: list[str] = []
    depth = 0
    for line in lines:
        text = _comment_text(line)
        if text is not None:
            if not pending.strip():
                comment.append(text)
            continue
        code = _strip_trailing_comment(line)
        if not code.strip():
            if not pending.strip():
                comment = []
            continue
        if not pending.strip():
            pending_comment = comment
            comment = []
        in_string = False
        for char in code:
            if char == '"':
                in_string = not in_string
            elif in_string:
                pass
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            if char == ";" and depth == 0 and not in_string:
                parameter = _parse_parameter(pending, pending_comment)
                if parameter:
                    parameters.append(parameter)
                pending = ""
                pending_comment = []
            else:
                pending += char
        pending += " "
    if pending.strip():
        parameter = _parse_parameter(pending, pending_comment)
        if parameter:
            parameters.append(parameter)
    return parameters


def _subprogram_interface(code: str) -> tuple[list[Parameter], str]:
    """The parameters and the return type of a subprogram declaration."""
    start = code.find("(")
    name_end = DECLARATION_START.match(code)
    returns = ""
    parameters: list[Parameter] = []
    after = code
    if start != -1 and name_end is not None and code[name_end.end() : start].strip() == "":
        depth = 0
        for index in range(start, len(code)):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    inner_lines = code[start + 1 : index].split("\n")
                    parameters = _parameters_with_comments(inner_lines)
                    after = code[index + 1 :]
                    break
    match = re.search(r"\breturn\s+(?P<type>[\w.]+)", after, re.IGNORECASE)
    if match:
        returns = match["type"]
    return parameters, returns


def _statement_end(lines: list[str], start: int) -> int:
    """The index of the last line of the declaration starting at lines[start]."""
    depth = 0
    is_record = False
    for index in range(start, len(lines)):
        code = _strip_trailing_comment(lines[index])
        if re.search(r"\bis\s+record\b", code, re.IGNORECASE) or (
            index == start and re.search(r"\bis\s+protected\b", code, re.IGNORECASE)
        ):
            is_record = True
        if is_record:
            if re.search(r"\bend\s+(record|protected)\b", code, re.IGNORECASE):
                return index
            continue
        for char in code:
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            elif char == ";" and depth == 0:
                return index
    return len(lines) - 1


def _dedent(lines: list[str]) -> str:
    indents = [len(line) - len(line.lstrip()) for line in lines if line.strip()]
    indent = min(indents) if indents else 0
    return "\n".join(line[indent:].rstrip() for line in lines)


def _parse_package(unit: DesignUnit, lines: list[str]) -> None:
    comment: list[str] = []
    group_comment: list[str] | None = None
    index = 0
    while index < len(lines):
        line = lines[index]
        if BANNER.match(line):
            end = index + 1
            while end < len(lines) and not BANNER.match(lines[end]) and _comment_text(lines[end]) is not None:
                end += 1
            texts = [_comment_text(text) or "" for text in lines[index + 1 : end]]
            if end < len(lines) and BANNER.match(lines[end]) and texts and texts[0].strip():
                body = texts[1:]
                while body and not body[0].strip():
                    body.pop(0)
                unit.items.append(Section(title=texts[0].strip(), text=body))
                index = end + 1
                comment = []
                group_comment = None
                continue
        text = _comment_text(line)
        if text is not None:
            comment.append(text)
            index += 1
            continue
        if not line.strip():
            comment = []
            group_comment = None
            index += 1
            continue
        match = DECLARATION_START.match(line)
        if match is None:
            comment = []
            index += 1
            continue
        end = _statement_end(lines, index)
        code_lines = lines[index : end + 1]
        code = _dedent(code_lines)
        declaration = Declaration(
            kind=match["kind"].lower(),
            name=match["name"],
            code=code,
            comment=list(comment) if comment else [],
        )
        declaration.grouped = not comment and group_comment is not None
        if declaration.kind in ("function", "procedure"):
            declaration.parameters, declaration.returns = _subprogram_interface(code)
        unit.items.append(declaration)
        # A declaration on the next line, without a blank line, belongs to the same group
        group_comment = declaration.comment
        comment = []
        index = end + 1


def _port_clause(lines: list[str], keyword: str) -> list[str]:
    """The lines inside the parentheses of the generic or port clause of an entity."""
    for index, line in enumerate(lines):
        code = _strip_trailing_comment(line)
        match = re.match(rf"^\s*{keyword}\s*\(", code, re.IGNORECASE)
        if match is None:
            continue
        depth = 0
        collected: list[str] = []
        first = True
        for inner in lines[index:]:
            code_part = _strip_trailing_comment(inner)
            start = code_part.find("(") + 1 if first else 0
            if first:
                depth = 0
            segment_start = start
            out = inner if not first else inner[start:]
            for position, char in enumerate(code_part):
                if first and position < start - 1:
                    continue
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        tail = code_part[segment_start if first else 0 : position]
                        if tail.strip():
                            collected.append(tail)
                        return collected
            collected.append(out)
            first = False
        return collected
    return []


def parse_file(path: Path) -> list[DesignUnit]:
    """Parse the package declarations, entities and contexts of a VHDL file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    description = _header(lines)
    units: list[DesignUnit] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        package = PACKAGE_START.match(line)
        entity = ENTITY_START.match(line)
        context = CONTEXT_START.match(line)
        if package and not re.match(r"^\s*package\s+body\b", line, re.IGNORECASE):
            end = index + 1
            while end < len(lines) and not PACKAGE_END.match(lines[end]):
                end += 1
            unit = DesignUnit("package", package["name"], path, description)
            _parse_package(unit, lines[index + 1 : end])
            units.append(unit)
            index = end + 1
            continue
        if entity:
            end = index + 1
            while end < len(lines) and not re.match(r"^\s*end(\s+entity)?(\s+\w+)?\s*;", lines[end], re.IGNORECASE):
                end += 1
            body = lines[index + 1 : end]
            unit = DesignUnit("entity", entity["name"], path, description)
            unit.generics = _parameters_with_comments(_port_clause(body, "generic"))
            unit.ports = _parameters_with_comments(_port_clause(body, "port"))
            units.append(unit)
            index = end + 1
            continue
        if context:
            end = index + 1
            while end < len(lines) and not re.match(r"^\s*end(\s+context)?(\s+\w+)?\s*;", lines[end], re.IGNORECASE):
                end += 1
            unit = DesignUnit("context", context["name"], path, description)
            unit.items.append(
                Declaration(kind="context", name=context["name"], code=_dedent(lines[index : end + 1]), comment=[])
            )
            units.append(unit)
            index = end + 1
            continue
        index += 1
    return units


def undocumented(unit: DesignUnit) -> list[str]:
    """Names of package declarations without a doc comment, neither their own nor of their group."""
    return [item.name for item in unit.declarations if item.kind != "context" and not item.comment and not item.grouped]


# -- reStructuredText output --------------------------------------------------


def _rst_text(comment: list[str], indent: str = "") -> list[str]:
    """Doc comment lines as reStructuredText, indented blocks as literal blocks."""
    out: list[str] = []
    in_literal = False
    for text in comment:
        is_indented = text.startswith("  ") and text.strip()
        if is_indented and not in_literal:
            if out and out[-1].strip():
                out.append("")
            out.append(f"{indent}.. code-block:: text")
            out.append("")
            in_literal = True
        elif in_literal and text.strip() and not is_indented:
            out.append("")
            in_literal = False
        if in_literal:
            out.append(f"{indent}   {text}" if text.strip() else "")
        else:
            out.append(f"{indent}{text}".rstrip())
    return out


def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def _parameter_table(parameters: list[Parameter], *, columns: tuple[str, ...], indent: str) -> list[str]:
    if not parameters:
        return []
    out = [
        f"{indent}.. list-table::",
        f"{indent}   :header-rows: 1",
        f"{indent}   :widths: auto",
        "",
        f"{indent}   * - " + f"\n{indent}     - ".join(columns),
    ]
    for parameter in parameters:
        cells = {
            "Name": ", ".join(f"``{name}``" for name in parameter.names),
            "Mode": parameter.mode,
            "Direction": parameter.mode,
            "Type": f"``{_cell(parameter.type)}``" if parameter.type else "",
            "Default": f"``{_cell(parameter.default)}``" if parameter.default else "",
            "Description": " ".join(text.strip() for text in parameter.comment),
        }
        row = [cells[column] for column in columns]
        out.append(f"{indent}   * - {row[0]}")
        out.extend(f"{indent}     - {cell}" for cell in row[1:])
    out.append("")
    return out


def _heading(text: str, character: str) -> list[str]:
    return [text, character * len(text), ""]


def render_unit(unit: DesignUnit, source_path: str) -> list[str]:
    """One design unit as reStructuredText, headings with ``~`` and ``^``."""
    out = _heading(f"{unit.kind.capitalize()} {unit.name}", "~")
    out.extend(_rst_text(unit.description))
    out.extend(["", f"Source: ``{source_path}``", ""])
    if unit.kind == "entity":
        out.extend([f".. vhdl:: {unit.name}", ""])
        if unit.generics:
            out.extend(["**Generics**", ""])
            out.extend(_parameter_table(unit.generics, columns=("Name", "Type", "Default", "Description"), indent=""))
        if unit.ports:
            out.extend(["**Ports**", ""])
            out.extend(_parameter_table(unit.ports, columns=("Name", "Direction", "Type", "Description"), indent=""))
        return out
    seen: set[str] = set()
    for item in unit.items:
        if isinstance(item, Section):
            out.extend(_heading(item.title, "^"))
            out.extend(_rst_text(item.text))
            out.append("")
            continue
        if item.kind == "context":
            out.extend([".. code-block:: vhdl", ""])
            out.extend(f"   {line}" if line else "" for line in item.code.split("\n"))
            out.append("")
            continue
        target = f"{unit.name}.{item.name}"
        out.append(f".. vhdl:: {target}")
        if target in seen:
            out.append("   :no-index:")
        seen.add(target)
        out.append("")
        out.extend(["   .. code-block:: vhdl", ""])
        out.extend(f"      {line}" if line else "" for line in item.code.split("\n"))
        out.append("")
        if item.comment:
            out.extend(_rst_text(item.comment, indent="   "))
            out.append("")
        if item.parameters and any(parameter.default for parameter in item.parameters):
            columns = ["Name", "Type", "Default"]
            if any(parameter.mode for parameter in item.parameters):
                columns.insert(1, "Mode")
            out.extend(_parameter_table(item.parameters, columns=tuple(columns), indent="   "))
    return out


def _unit_order(path: Path, family: str) -> tuple[int, str, int, str]:
    """Group the files of a family by interface, the family itself first."""
    stem = path.stem
    group = stem.split("_")[0]
    rank = {"context": 0, "pkg": 1}.get(stem.split("_")[-1], 2)
    return (0 if group == family else 1, group, rank, stem)


def generate(vhdl_root: Path, output: Path, *, source_root: Path | None = None) -> list[Path]:
    """Write ``<output>/<family>.inc`` for every family directory. Returns the written files."""
    output.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for family_dir in sorted(path for path in vhdl_root.iterdir() if path.is_dir()):
        family = family_dir.name
        files = sorted(family_dir.glob("*.vhd"), key=lambda path: _unit_order(path, family))
        out: list[str] = [".. This file is generated by tools/vhdl_docs.py; edit the VHDL doc comments instead.", ""]
        current_group = None
        for path in files:
            group = path.stem.split("_")[0]
            if group != current_group:
                title = "Shared" if group == family else group.upper()
                out.extend(_heading(title, "-"))
                current_group = group
            relative = path.relative_to(source_root).as_posix() if source_root else path.name
            for unit in parse_file(path):
                out.extend(render_unit(unit, relative))
                out.append("")
        target = output / f"{family}.inc"
        text = "\n".join(out).rstrip() + "\n"
        if not target.exists() or target.read_text(encoding="utf-8") != text:
            target.write_text(text, encoding="utf-8")
        written.append(target)
    return written


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    for path in generate(Path(arguments[0]), Path(arguments[1])):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
