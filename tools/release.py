# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The version of the package, as the release workflow needs it.

A release is made by tagging the commit bumping the version in pyproject.toml, so the
tag and that version must agree. Checking it here keeps a mistyped tag from reaching
PyPI, where a version cannot be taken back.

    python tools/release.py version           print the version of pyproject.toml
    python tools/release.py prerelease        print true for a pre-release or dev version
    python tools/release.py validate          check that the version is a release version
    python tools/release.py validate --tag v1.2.3
                                              check the tag against it as well
    python tools/release.py rehearse --run-number 42
                                              give the checkout a unique dev version for a
                                              TestPyPI rehearsal and print it
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PYPROJECT = REPO / "pyproject.toml"
INIT = REPO / "src" / "awesome_vunit_vcs" / "__init__.py"
# A tagged release needs docs/release_notes/<version>.rst, which is not empty
RELEASE_NOTES = REPO / "docs" / "release_notes"

# Final releases are refused until the dependencies can be installed from PyPI: the
# package needs vunit_hdl>=5.0.0.dev12 with package setup hooks (VUnit PR #1221, PyPI
# stops at 5.0.0.dev9) and vunit-python-bridge, which is not published. A final release
# would be uninstallable. Set this to True once both are on PyPI and
# tests/packaging/unreleased-requirements.txt is gone.
ALLOW_FINAL_RELEASES = False

# The versions a release may have: MAJOR.MINOR.PATCH, optionally a pre-release of it,
# optionally a development release of that.
RELEASE_VERSION = re.compile(r"(?P<base>\d+\.\d+\.\d+)(?P<pre>a\d+|b\d+|rc\d+)?(?P<dev>\.dev\d+)?")

PYPROJECT_VERSION = re.compile(r'^version = "(?P<version>[^"]+)"$', re.MULTILINE)
INIT_VERSION = re.compile(r'^__version__ = "(?P<version>[^"]+)"$', re.MULTILINE)


class ReleaseError(Exception):
    pass


def _read_version(path: Path, pattern: re.Pattern[str]) -> str:
    match = pattern.search(path.read_text(encoding="utf-8"))
    if match is None:
        raise ReleaseError(f"{path} has no version matching {pattern.pattern!r}")
    return match["version"]


def version(pyproject: Path = PYPROJECT) -> str:
    """The version in pyproject.toml."""
    return _read_version(pyproject, PYPROJECT_VERSION)


def is_prerelease(project_version: str) -> bool:
    match = RELEASE_VERSION.fullmatch(project_version)
    return match is not None and (match["pre"] is not None or match["dev"] is not None)


def validate(
    tag: str | None,
    *,
    pyproject: Path = PYPROJECT,
    init: Path = INIT,
    allow_final: bool = ALLOW_FINAL_RELEASES,
    release_notes: Path = RELEASE_NOTES,
) -> str:
    """
    Fail unless the version, and the tag naming it when there is one, are what a release
    is made of. Returns the version.
    """
    project_version = version(pyproject)
    if not RELEASE_VERSION.fullmatch(project_version):
        raise ReleaseError(
            f"{pyproject.name} has version {project_version!r}, which is not a version to release. "
            "Releases are made of MAJOR.MINOR.PATCH, optionally aN, bN or rcN, optionally .devN."
        )

    package_version = _read_version(init, INIT_VERSION)
    if package_version != project_version:
        raise ReleaseError(
            f"{init.name} has __version__ {package_version!r} but {pyproject.name} has {project_version!r}."
        )

    if not allow_final and not is_prerelease(project_version):
        raise ReleaseError(
            f"Version {project_version!r} is a final release, and final releases are not allowed yet: "
            "vunit_hdl>=5.0.0.dev12 with package setup hooks and vunit-python-bridge are not on PyPI, "
            "so the release could not be installed. Release a pre-release (aN, bN, rcN or .devN) "
            "or set ALLOW_FINAL_RELEASES in tools/release.py once both are published."
        )

    if tag is not None and tag != f"v{project_version}":
        raise ReleaseError(
            f"The tag {tag!r} does not name the version of {pyproject.name}, which is {project_version!r}. "
            f"Expected the tag v{project_version}."
        )

    if tag is not None:
        notes = release_notes / f"{project_version}.rst"
        if not notes.is_file() or not notes.read_text(encoding="utf-8").strip():
            raise ReleaseError(
                f"A release needs its release notes in {notes.relative_to(release_notes.parent.parent)}. "
                "Rename docs/release_notes/unreleased.rst to it, start a new empty unreleased.rst and "
                "include the new file in docs/release_notes/index.rst."
            )

    return project_version


def rehearsal_version(project_version: str, run_number: int) -> str:
    """
    A version unique to a workflow run, for uploads to TestPyPI: the development release
    number is the run number, replacing the one the version already has.
    """
    match = RELEASE_VERSION.fullmatch(project_version)
    if match is None:
        raise ReleaseError(f"Cannot make a rehearsal version of {project_version!r}")
    if run_number < 0:
        raise ReleaseError(f"Negative run number {run_number}")
    return f"{match['base']}{match['pre'] or ''}.dev{run_number}"


def rehearse(run_number: int, *, pyproject: Path = PYPROJECT, init: Path = INIT) -> str:
    """Write the rehearsal version into pyproject.toml and __init__.py and return it."""
    new_version = rehearsal_version(version(pyproject), run_number)
    for path, pattern, template in (
        (pyproject, PYPROJECT_VERSION, 'version = "{}"'),
        (init, INIT_VERSION, '__version__ = "{}"'),
    ):
        text = path.read_text(encoding="utf-8")
        new_text, count = pattern.subn(template.format(new_version), text, count=1)
        if count != 1:
            raise ReleaseError(f"{path} has no version to replace")
        path.write_text(new_text, encoding="utf-8")
    return new_version


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version", help="Print the version of pyproject.toml")
    commands.add_parser("prerelease", help="Print true for a pre-release or development version, else false")
    validate_parser = commands.add_parser("validate", help="Check the version, and a tag naming it")
    validate_parser.add_argument("--tag", help="The tag the release is made from, for example v1.2.3")
    rehearse_parser = commands.add_parser("rehearse", help="Give the checkout a unique dev version")
    rehearse_parser.add_argument("--run-number", type=int, required=True, help="GITHUB_RUN_NUMBER")

    args = parser.parse_args(argv)
    try:
        if args.command == "version":
            print(version())
        elif args.command == "prerelease":
            print(str(is_prerelease(version())).lower())
        elif args.command == "validate":
            project_version = validate(args.tag)
            print(f"Version {project_version}" + ("" if args.tag is None else f", tagged {args.tag}"))
        else:
            print(rehearse(args.run_number))
    except ReleaseError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
