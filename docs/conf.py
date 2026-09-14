# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Sphinx configuration of the awesome-vunit-vcs documentation.

Build with: sphinx-build -W --keep-going -b html docs docs/_build
"""

from __future__ import annotations

from os import environ
from pathlib import Path
from sys import path as sys_path
from typing import Any

# The documentation is built from the source tree rather than an installed
# package: two of the package dependencies, vunit_hdl with the package setup
# hooks and vunit-python-bridge, are not on PyPI yet, so "pip install ." fails
# on Read the Docs. The documented modules only need NumPy, which
# requirements.txt installs.
DOCS = Path(__file__).resolve().parent
ROOT = DOCS.parent
sys_path.insert(0, str(ROOT / "src"))
sys_path.insert(0, str(ROOT / "tools"))

import vhdl_docs  # noqa: E402

from awesome_vunit_vcs import __version__  # noqa: E402

# -- Project information ------------------------------------------------------

project = "awesome-vunit-vcs"
copyright = "2026, Sebastian Hellgren"
author = "Sebastian Hellgren"
release = __version__
version = __version__

# -- Sphinx Options -----------------------------------------------------------

needs_sphinx = "7.3"

extensions = [
    "sphinx_rtd_theme",
    "sphinx_copybutton",
    "sphinx_design",
    "sphinx_sitemap",
    "sphinx.ext.autodoc",
    "sphinx.ext.extlinks",
    "sphinx.ext.intersphinx",
    "sphinx.ext.napoleon",
    "sphinxext.opengraph",
    "myst_parser",
]

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

exclude_patterns = [
    "_build",
    "_generated",
    "requirements.txt",
    # Release notes are included by release_notes/index.rst
    "release_notes/[!i]*.rst",
]

autodoc_default_options = {
    "members": True,
}
autodoc_member_order = "bysource"
autodoc_typehints = "description"
# Aliases of NumPy array types are shown by name instead of being expanded
autodoc_type_aliases = {
    "Int32Array": "awesome_vunit_vcs.ethernet.phy.common.Int32Array",
    "Int64Array": "awesome_vunit_vcs.ethernet.phy.common.Int64Array",
    "PhyInterface": "awesome_vunit_vcs.ethernet.phy.common.PhyInterface",
}

# Every cross-reference must resolve. The exceptions are names without
# documentation of their own: private NumPy typing names, type variables, and
# the array aliases until their docstrings document them.
nitpicky = True
nitpick_ignore_regex = [
    (r"py:class", r"numpy\._typing\..*"),
    (r"py:class", r"numpy\.(int32|int64|uint8)"),
    (r"py:class", r"TypeAliasForwardRef"),
    # autodoc renders the aliases quoted where a module uses them as forward references
    (r"py:class", r"'awesome_vunit_vcs\.ethernet\.phy\.common\.Int(32|64)Array'"),
]

myst_heading_anchors = 3

# Shorthand links, :issue:`12` and :vunit-pr:`1220`
extlinks = {
    "issue": ("https://github.com/ru551n/awesome-vunit-vcs/issues/%s", "#%s"),
    "vunit-pr": ("https://github.com/VUnit/vunit/pull/%s", "VUnit PR #%s"),
    # A file in the repository, :repo-file:`examples/cookbook/tb_cookbook.vhd`
    "repo-file": ("https://github.com/ru551n/awesome-vunit-vcs/blob/main/%s", "%s"),
}

copybutton_prompt_text = r"\$ |>>> |\.\.\. "
copybutton_prompt_is_regexp = True
copybutton_exclude = ".linenos, .gp, .go"

# -- Options for HTML output --------------------------------------------------

# The Read the Docs theme, configured like the tsfpga documentation
html_theme = "sphinx_rtd_theme"
html_title = "awesome-vunit-vcs"
html_logo = "_static/logo.svg"
html_favicon = "_static/favicon.svg"
html_static_path = ["_static"]

html_theme_options = {
    "logo_only": True,
    "prev_next_buttons_location": "both",
    "style_external_links": True,
    "navigation_depth": 3,
}

# "Edit on GitHub" links to the version being built
html_context = {
    "display_github": True,
    "github_user": "ru551n",
    "github_repo": "awesome-vunit-vcs",
    "github_version": environ.get("READTHEDOCS_GIT_IDENTIFIER", "main"),
    "conf_py_path": "/docs/",
}

WEBSITE_URL = "https://awesome-vunit-vcs.readthedocs.io"

# The canonical URL of the version being built on Read the Docs, which includes
# the language and the version, for example .../en/latest/
html_baseurl = environ.get("READTHEDOCS_CANONICAL_URL", f"{WEBSITE_URL}/en/latest/")
# html_baseurl already has the language and the version
sitemap_url_scheme = "{link}"

# Open Graph metadata for link previews
ogp_site_url = html_baseurl
ogp_image = f"{WEBSITE_URL}/en/latest/_static/social_preview.png"
ogp_social_cards = {"enable": False}

# -- Intersphinx --------------------------------------------------------------

intersphinx_mapping = {
    "python": ("https://docs.python.org/3", None),
    "numpy": ("https://numpy.org/doc/stable/", None),
    "vunit": ("https://vunit.github.io/", None),
    "scapy": ("https://scapy.readthedocs.io/en/latest/", None),
}

# -- Linkcheck (weekly job in .github/workflows/docs.yml) --------------------

linkcheck_anchors_ignore_for_url = [r"https://github\.com/.*"]
linkcheck_timeout = 30
linkcheck_retries = 2


# -- VHDL API reference -------------------------------------------------------


def _generate_vhdl_reference(_app: Any) -> None:
    """Generate the VHDL reference include files from the doc comments of the sources."""
    vhdl_docs.generate(
        ROOT / "src" / "awesome_vunit_vcs" / "vhdl",
        DOCS / "_generated" / "vhdl",
        source_root=ROOT,
    )


def setup(app: Any) -> None:
    # A generic object type for VHDL declarations: ".. vhdl::" targets, the
    # :vhdl: role and index entries, since Sphinx has no VHDL domain
    app.add_object_type("vhdl", "vhdl", indextemplate="pair: %s; VHDL")
    app.connect("builder-inited", _generate_vhdl_reference)
