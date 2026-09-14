# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Sphinx configuration of the awesome-vunit-vcs documentation.

Build with: sphinx-build -W --keep-going -b html docs docs/_build
"""

from os import environ
from pathlib import Path
from sys import path as sys_path

# The documentation is built from the source tree rather than an installed
# package: two of the package dependencies, vunit_hdl with the package setup
# hooks and vunit-python-bridge, are not on PyPI yet, so "pip install ." fails
# on Read the Docs. The documented modules only need NumPy, which
# requirements.txt installs.
ROOT = Path(__file__).resolve().parent.parent
sys_path.insert(0, str(ROOT / "src"))

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
    "sphinx.ext.autodoc",
    "sphinx.ext.intersphinx",
    "sphinx.ext.todo",
    "myst_parser",
]

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

# notes-gmii.md is working material for ARCHITECTURE.md, not a page
exclude_patterns = ["_build", "notes-*.md", "requirements.txt"]

autodoc_default_options = {
    "members": True,
}
autodoc_member_order = "bysource"
autodoc_typehints = "description"
# Aliases of NumPy array types are shown by name instead of being expanded
autodoc_type_aliases = {
    "Int32Array": "awesome_vunit_vcs.ethernet.phy.common.Int32Array",
    "Int64Array": "awesome_vunit_vcs.ethernet.phy.common.Int64Array",
}
# Type hints refer to third-party and private names that have no documentation
# of their own; they are rendered as text instead of failing the -W build
nitpicky = False

myst_heading_anchors = 3

# -- Options for HTML output --------------------------------------------------

html_theme = "furo"
html_title = "awesome-vunit-vcs"

html_theme_options = {
    "source_repository": "https://github.com/ru551n/awesome-vunit-vcs",
    "source_branch": environ.get("GITHUB_REF_NAME", "main"),
    "source_directory": "docs",
}

# -- Intersphinx --------------------------------------------------------------

intersphinx_mapping = {
    "python": ("https://docs.python.org/3/", None),
    "numpy": ("https://numpy.org/doc/stable/", None),
    "vunit": ("https://vunit.github.io/", None),
}
