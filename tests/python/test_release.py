"""Tests of tools/release.py, the version checks of the release workflow."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

RELEASE_SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "release.py"


def _load_release() -> ModuleType:
    spec = importlib.util.spec_from_file_location("release", RELEASE_SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = _load_release()


def _project(tmp_path: Path, project_version: str, package_version: str | None = None) -> tuple[Path, Path]:
    pyproject = tmp_path / "pyproject.toml"
    pyproject.write_text(
        f'[project]\nname = "awesome-vunit-vcs"\nversion = "{project_version}"\n'
        '\n[tool.ruff]\ntarget-version = "py310"\n',
        encoding="utf-8",
    )
    init = tmp_path / "__init__.py"
    init.write_text(f'"""Docs."""\n\n__version__ = "{package_version or project_version}"\n', encoding="utf-8")
    notes = tmp_path / "docs" / "release_notes"
    notes.mkdir(parents=True)
    (notes / f"{project_version}.rst").write_text("* A change.\n", encoding="utf-8")
    return pyproject, init


def test_repository_version_is_consistent_and_releasable() -> None:
    assert release.validate(None) == release.version()


@pytest.mark.parametrize(
    ("project_version", "expected"),
    [
        ("0.1.0", False),
        ("1.2.3a1", True),
        ("1.2.3b2", True),
        ("1.2.3rc1", True),
        ("0.1.0.dev0", True),
        ("1.0.0rc1.dev4", True),
        ("1.0", False),
    ],
)
def test_is_prerelease(project_version: str, expected: bool) -> None:
    assert release.is_prerelease(project_version) is expected


@pytest.mark.parametrize("project_version", ["0.1.0a1", "0.1.0rc2", "0.1.0.dev3"])
def test_validate_accepts_prereleases_with_matching_tag(tmp_path: Path, project_version: str) -> None:
    pyproject, init = _project(tmp_path, project_version)
    assert (
        release.validate(
            f"v{project_version}", pyproject=pyproject, init=init, release_notes=tmp_path / "docs" / "release_notes"
        )
        == project_version
    )


def test_validate_refuses_final_release_while_gated(tmp_path: Path) -> None:
    pyproject, init = _project(tmp_path, "0.1.0")
    with pytest.raises(release.ReleaseError, match="final releases are not allowed yet"):
        release.validate("v0.1.0", pyproject=pyproject, init=init, allow_final=False)
    assert (
        release.validate(
            "v0.1.0",
            pyproject=pyproject,
            init=init,
            allow_final=True,
            release_notes=tmp_path / "docs" / "release_notes",
        )
        == "0.1.0"
    )


def test_validate_refuses_wrong_tag(tmp_path: Path) -> None:
    pyproject, init = _project(tmp_path, "0.1.0a1")
    with pytest.raises(release.ReleaseError, match=r"Expected the tag v0\.1\.0a1"):
        release.validate("v0.1.0a2", pyproject=pyproject, init=init)
    with pytest.raises(release.ReleaseError, match="Expected the tag"):
        release.validate("0.1.0a1", pyproject=pyproject, init=init)


@pytest.mark.parametrize("project_version", ["0.1", "v0.1.0", "0.1.0-alpha", "0.1.0.post1", "0.1.0+local"])
def test_validate_refuses_non_release_versions(tmp_path: Path, project_version: str) -> None:
    pyproject, init = _project(tmp_path, project_version)
    with pytest.raises(release.ReleaseError, match="not a version to release"):
        release.validate(None, pyproject=pyproject, init=init)


def test_validate_refuses_package_version_mismatch(tmp_path: Path) -> None:
    pyproject, init = _project(tmp_path, "0.1.0a1", package_version="0.1.0a0")
    with pytest.raises(release.ReleaseError, match="__version__"):
        release.validate(None, pyproject=pyproject, init=init)


@pytest.mark.parametrize(
    ("project_version", "run_number", "expected"),
    [
        ("0.1.0.dev0", 42, "0.1.0.dev42"),
        ("0.1.0a1", 7, "0.1.0a1.dev7"),
        ("0.1.0rc1.dev3", 9, "0.1.0rc1.dev9"),
        ("0.1.0", 1, "0.1.0.dev1"),
    ],
)
def test_rehearsal_version(project_version: str, run_number: int, expected: str) -> None:
    assert release.rehearsal_version(project_version, run_number) == expected


def test_rehearse_rewrites_both_versions_and_stays_valid(tmp_path: Path) -> None:
    pyproject, init = _project(tmp_path, "0.1.0")
    assert release.rehearse(12, pyproject=pyproject, init=init) == "0.1.0.dev12"
    assert release.version(pyproject) == "0.1.0.dev12"
    assert '__version__ = "0.1.0.dev12"' in init.read_text(encoding="utf-8")
    assert 'target-version = "py310"' in pyproject.read_text(encoding="utf-8")
    assert release.validate(None, pyproject=pyproject, init=init, allow_final=False) == "0.1.0.dev12"


def test_main_reports_errors_without_traceback(capsys: pytest.CaptureFixture[str]) -> None:
    assert release.main(["version"]) == 0
    assert capsys.readouterr().out.strip() == release.version()
    assert release.main(["validate", "--tag", "v0.0.0-wrong"]) == 1
    assert "error:" in capsys.readouterr().err


def test_validate_requires_release_notes_for_a_tag(tmp_path: Path) -> None:
    pyproject, init = _project(tmp_path, "0.1.0a1")
    notes = tmp_path / "docs" / "release_notes"
    (notes / "0.1.0a1.rst").write_text("\n", encoding="utf-8")
    with pytest.raises(release.ReleaseError, match="release notes"):
        release.validate("v0.1.0a1", pyproject=pyproject, init=init, release_notes=notes)
    (notes / "0.1.0a1.rst").unlink()
    with pytest.raises(release.ReleaseError, match="release notes"):
        release.validate("v0.1.0a1", pyproject=pyproject, init=init, release_notes=notes)
    # Without a tag, as in a rehearsal, no release notes are needed
    assert release.validate(None, pyproject=pyproject, init=init, release_notes=notes) == "0.1.0a1"
