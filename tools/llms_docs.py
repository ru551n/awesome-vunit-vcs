# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Write the documentation for AI agents and other tools that read plain text.

Following the llms.txt convention (https://llmstxt.org), the HTML build gets:

* ``llms.txt``: the project, a summary and one link per page, grouped like the navigation.
* ``llms-full.txt``: every page as Markdown in reading order, basic before advanced, with the
  API reference last.
* ``<page>.md`` next to every ``<page>.html``: the same Markdown, one file per page.

The Markdown comes from a second Sphinx build with the markdown builder of
sphinx-markdown-builder, so included example code is resolved and the docs markers of the
examples are dropped like in the HTML. docs/conf.py runs :func:`build` when the HTML build finishes.

Run standalone to write the files into a directory::

    python tools/llms_docs.py <docs directory> <output directory> [<base url>]
"""

from __future__ import annotations

import io
import os
import posixpath
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

#: Set while the Markdown build runs, so docs/conf.py does not start another one
NESTED_BUILD = "AWESOME_VUNIT_VCS_MARKDOWN_BUILD"

#: Machine-readable files published next to llms.txt, see tools/api_index.py
API_FILES = (
    ("api/vhdl.json", "Every VHDL package, type, procedure, function and entity with its parameters"),
    ("api/python.json", "The public Python API with signatures and docstrings"),
    ("api/examples.json", "Every cookbook task with its example file, test case and run command"),
)

_OPTIONAL_CAPTIONS = {"Help and project"}
_LINK = re.compile(r"\]\((?!https?:|mailto:|#)([^)\s]+)\)")


def install_translator(app: Any) -> None:
    """Keep code-block captions (file names) and abbreviations in the Markdown output."""
    from docutils import nodes
    from sphinx_markdown_builder.translator import MarkdownTranslator

    class CaptionedMarkdownTranslator(MarkdownTranslator):  # type: ignore[misc]
        def visit_caption(self, node: Any) -> None:
            self.add(f"**{node.astext()}**", prefix_eol=2, suffix_eol=1)
            raise nodes.SkipNode

        def visit_abbreviation(self, node: Any) -> None:
            self.add(node.astext())
            raise nodes.SkipNode

    app.registry.add_translator("markdown", CaptionedMarkdownTranslator, override=True)


@dataclass
class Page:
    docname: str
    title: str
    summary: str
    markdown: str


@dataclass
class Section:
    caption: str
    docnames: list[str] = field(default_factory=list)


def _first_sentence(doctree: Any) -> str:
    from docutils import nodes

    # The first paragraph directly in a section, not in a list, table or admonition
    for paragraph in doctree.findall(nodes.paragraph):
        if not isinstance(paragraph.parent, nodes.section):
            continue
        text = " ".join(paragraph.astext().split())
        if text:
            sentence = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0]
            return sentence if len(sentence) <= 200 else sentence[:197] + "..."
    return ""


def _descendants(env: Any, docname: str, seen: set[str]) -> list[str]:
    if docname in seen:
        return []
    seen.add(docname)
    order = [docname]
    for child in env.toctree_includes.get(docname, []):
        order.extend(_descendants(env, child, seen))
    return order


def _markdown_build(docs: Path, work: Path) -> tuple[dict[str, Page], list[Section], str, str]:
    from docutils import nodes
    from sphinx import addnodes
    from sphinx.application import Sphinx
    from sphinx.util.docutils import docutils_namespace, patch_docutils

    previous = os.environ.get(NESTED_BUILD)
    os.environ[NESTED_BUILD] = "1"
    try:
        with patch_docutils(docs), docutils_namespace():
            app = Sphinx(
                srcdir=str(docs),
                confdir=str(docs),
                outdir=str(work / "markdown"),
                doctreedir=str(work / "doctrees"),
                buildername="markdown",
                status=None,
                warning=io.StringIO(),
                freshenv=True,
            )
            app.build()
    finally:
        if previous is None:
            os.environ.pop(NESTED_BUILD, None)
        else:
            os.environ[NESTED_BUILD] = previous

    env = app.env
    root = env.config.root_doc
    root_tree = env.get_doctree(root)
    sections: list[Section] = []
    seen: set[str] = {root}
    for toctree in root_tree.findall(addnodes.toctree):
        section = Section(toctree.get("caption") or "Documentation")
        for _title, docname in toctree["entries"]:
            section.docnames.extend(_descendants(env, docname, seen))
        sections.append(section)

    pages: dict[str, Page] = {}
    for docname in [root, *(name for section in sections for name in section.docnames)]:
        source = work / "markdown" / f"{docname}.md"
        if not source.exists():
            continue
        title = env.titles[docname].astext() if docname in env.titles else docname
        pages[docname] = Page(docname, title, _first_sentence(env.get_doctree(docname)), source.read_text("utf-8"))

    summary_paragraphs = [" ".join(p.astext().split()) for p in root_tree.findall(nodes.paragraph)][:2]
    return pages, sections, " ".join(summary_paragraphs), env.config.project


def _absolute_links(markdown: str, docname: str, base_url: str) -> str:
    directory = posixpath.dirname(docname)

    def replace(match: re.Match[str]) -> str:
        target, _, anchor = match.group(1).partition("#")
        path = posixpath.normpath(posixpath.join(directory, target))
        if path.endswith(".md"):
            path = path[: -len(".md")] + ".html"
        url = base_url + path + (f"#{anchor}" if anchor else "")
        return f"]({url})"

    return _LINK.sub(replace, markdown)


def build(docs: Path, output: Path, base_url: str) -> list[Path]:
    """Write llms.txt, llms-full.txt and one Markdown file per page into ``output``."""
    base_url = base_url if base_url.endswith("/") else base_url + "/"
    with tempfile.TemporaryDirectory(prefix="llms-docs-") as temporary:
        pages, sections, summary, project = _markdown_build(docs, Path(temporary))

    output.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for page in pages.values():
        target = output / f"{page.docname}.md"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page.markdown, encoding="utf-8")
        written.append(target)

    api_docs = [name for name in pages if posixpath.basename(name) in ("vhdl_api", "python_api")]

    lines = [f"# {project}", "", f"> {summary}", ""]
    lines += [
        "Verification components for VUnit testbenches: Ethernet (GMII, MII, RGMII, RMII, XGMII, "
        "AXI-Stream), a QSPI NOR flash with QSPI master and protocol checker, I2C (master, target, "
        "monitor, protocol checker), and property-based testing with Hypothesis inside a simulation. "
        "Testbenches are VHDL; Python builds frames and "
        "strategies. Every link below is a Markdown version of a documentation page; llms-full.txt has "
        "all of them in reading order.",
        "",
    ]
    optional: list[str] = []
    for section in sections:
        entries = [
            f"- [{pages[name].title}]({base_url}{name}.md)"
            + (f": {pages[name].summary}" if pages[name].summary else "")
            for name in section.docnames
            if name in pages and name not in api_docs
        ]
        if not entries:
            continue
        caption = "Optional" if section.caption in _OPTIONAL_CAPTIONS else section.caption
        block = [f"## {caption}", "", *entries, ""]
        if caption == "Optional":
            optional = block
        else:
            lines += block
    lines += ["## API reference", ""]
    lines += [f"- [{pages[name].title} ({name.split('/')[0]})]({base_url}{name}.md)" for name in api_docs]
    lines += [f"- [{name}]({base_url}{name}): {description}" for name, description in API_FILES]
    lines += ["", *optional]
    written.append(_write(output / "llms.txt", lines))

    reading_order = [
        name for section in sections if section.caption not in _OPTIONAL_CAPTIONS for name in section.docnames
    ]
    reading_order = [name for name in reading_order if name not in api_docs] + api_docs
    reading_order += [
        name for section in sections if section.caption in _OPTIONAL_CAPTIONS for name in section.docnames
    ]
    full = [f"# {project}", "", f"> {summary}", ""]
    for name in reading_order:
        if name not in pages:
            continue
        full += ["", "---", "", f"Source: {base_url}{name}.html", ""]
        full.append(_absolute_links(pages[name].markdown, name, base_url).strip())
    written.append(_write(output / "llms-full.txt", full))
    return written


def _write(target: Path, lines: list[str]) -> Path:
    target.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return target


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    base_url = arguments[2] if len(arguments) == 3 else "https://awesome-vunit-vcs.readthedocs.io/en/latest/"
    output = Path(arguments[1])
    for path in build(Path(arguments[0]).resolve(), output, base_url):
        if path.parent == output:
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
