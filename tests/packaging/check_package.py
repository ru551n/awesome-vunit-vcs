"""
Packaging check: build the distributions, install them into clean virtual
environments and prove that VUnit finds the package there.

    python tests/packaging/check_package.py [--requirements PIP_ARGUMENTS] [--run-example]

Steps:

1. Build a wheel and an sdist and check that both carry every VHDL file,
   ``vunit_pkg.toml`` and ``py.typed``.
2. Install the wheel into a fresh virtual environment, then ask VUnit to
   ``add_package("awesome-vunit-vcs")`` from a directory outside the repository
   and check that the library has every VHDL file of the package, taken from
   the installed copy.
3. Do the same with an editable install, which must resolve to the repository.
4. With ``--run-example``, copy ``examples/external_project`` outside the
   repository and run it with the wheel environment (needs a simulator).

The unreleased dependencies, VUnit with package setup hooks and
vunit-python-bridge, are installed first from ``--requirements`` (pip
arguments, for example ``-e ~/git/vunit -e ~/git/vunit-python-bridge``),
default ``-r`` :data:`UNRELEASED_REQUIREMENTS`.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PACKAGE_DIR = REPO / "src" / "awesome_vunit_vcs"

#: The pins of the unreleased dependencies, shared with CI
UNRELEASED_REQUIREMENTS = Path(__file__).resolve().parent / "unreleased-requirements.txt"

PROBE = """
import importlib.util, json, sys
from vunit import VUnit
vu = VUnit.from_argv(argv=["--output-path", sys.argv[1]])
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge")
vu.add_package("awesome-vunit-vcs")
spec = importlib.util.find_spec("awesome_vunit_vcs")
print(json.dumps({
    "package_dir": str(__import__("pathlib").Path(spec.origin).parent.resolve()),
    "library_files": sorted(
        str(__import__("pathlib").Path(f.name).resolve())
        for f in vu.library("awesome_vunit_vcs").get_source_files()
    ),
}))
"""


class CheckError(Exception):
    pass


@dataclass
class Environment:
    root: Path

    @property
    def python(self) -> Path:
        return self.root / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def run(command: list[str | Path], **kwargs: object) -> str:
    shown = ["<probe script>" if part == PROBE else str(part) for part in command]
    print("$", shlex.join(shown), flush=True)
    result = subprocess.run(
        [str(part) for part in command],
        check=False,
        capture_output=True,
        text=True,
        **kwargs,  # type: ignore[call-overload]
    )
    if result.returncode != 0:
        raise CheckError(f"Command failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return str(result.stdout)


def expected_package_files() -> set[str]:
    """Package relative paths of the files that must be in every distribution."""
    return {
        path.relative_to(PACKAGE_DIR.parent).as_posix()
        for path in PACKAGE_DIR.rglob("*")
        if path.is_file()
        and (path.suffix in {".vhd", ".py", ".toml"} or path.name == "py.typed")
        and "__pycache__" not in path.parts
    }


def build(out_dir: Path) -> tuple[Path, Path]:
    if shutil.which("uv"):
        run(["uv", "build", "--out-dir", out_dir, REPO])
    else:
        run([sys.executable, "-m", "build", "--outdir", out_dir, REPO])
    (wheel,) = out_dir.glob("*.whl")
    (sdist,) = out_dir.glob("*.tar.gz")
    return wheel, sdist


def check_archives(wheel: Path, sdist: Path) -> None:
    expected = expected_package_files()
    with zipfile.ZipFile(wheel) as archive:
        missing = expected - set(archive.namelist())
    if missing:
        raise CheckError(f"Wheel lacks {sorted(missing)}")
    with tarfile.open(sdist) as archive:
        names = {name.split("/", 1)[1] for name in archive.getnames() if "/" in name}
    missing = {f"src/{name}" for name in expected} - names
    if missing:
        raise CheckError(f"Sdist lacks {sorted(missing)}")
    print(f"Wheel and sdist carry all {len(expected)} package files")


def create_environment(root: Path, requirements: str, package: list[str]) -> Environment:
    env = Environment(root)
    if shutil.which("uv"):
        run(["uv", "venv", "--python", sys.executable, root])
        install = ["uv", "pip", "install", "--python", env.python]
    else:
        run([sys.executable, "-m", "venv", root])
        install = [env.python, "-m", "pip", "install", "--progress-bar", "off"]
    run([*install, *shlex.split(requirements)])
    run([*install, *package])
    return env


def probe(env: Environment, work_dir: Path) -> dict[str, object]:
    output = run([env.python, "-c", PROBE, work_dir / "vunit_out"], cwd=work_dir)
    return dict(json.loads(output.strip().splitlines()[-1]))


def check_probe(result: dict[str, object], *, editable: bool) -> None:
    package_dir = Path(str(result["package_dir"]))
    inside_repo = package_dir.is_relative_to(REPO)
    if editable != inside_repo:
        where = "the repository" if editable else "the environment"
        raise CheckError(f"Expected the package in {where}, VUnit found it in {package_dir}")
    library_files = [Path(name) for name in result["library_files"]]  # type: ignore[attr-defined]
    outside = [path for path in library_files if not path.is_relative_to(package_dir)]
    if outside:
        raise CheckError(f"Library awesome_vunit_vcs has files outside {package_dir}: {outside}")
    found = sorted(path.relative_to(package_dir).as_posix() for path in library_files)
    expected = sorted(path.relative_to(PACKAGE_DIR).as_posix() for path in PACKAGE_DIR.rglob("*.vhd"))
    if found != expected:
        raise CheckError(f"Library awesome_vunit_vcs has {found}, expected {expected}")
    kind = "Editable install" if editable else "Wheel install"
    print(f"{kind}: VUnit added {len(expected)} files from {package_dir}")


def run_example(env: Environment, work_dir: Path) -> None:
    project = work_dir / "external_project"
    shutil.copytree(REPO / "examples" / "external_project", project)
    print(run([env.python, project / "run.py", "--output-path", project / "vunit_out"], cwd=work_dir))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--requirements",
        default=os.environ.get("AWESOME_VUNIT_VCS_REQUIREMENTS", shlex.join(["-r", str(UNRELEASED_REQUIREMENTS)])),
        help="pip arguments installing the unreleased dependencies",
    )
    parser.add_argument("--work-dir", type=Path, help="Keep the environments here instead of a temporary directory")
    parser.add_argument("--skip-editable", action="store_true")
    parser.add_argument("--run-example", action="store_true", help="Run examples/external_project (needs a simulator)")
    args = parser.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="awesome_vunit_vcs_packaging_") as temporary:
        work_dir = (args.work_dir or Path(temporary)).resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
        try:
            wheel, sdist = build(work_dir / "dist")
            check_archives(wheel, sdist)

            wheel_env = create_environment(work_dir / "wheel_env", args.requirements, [str(wheel)])
            check_probe(probe(wheel_env, work_dir), editable=False)

            if not args.skip_editable:
                editable_env = create_environment(work_dir / "editable_env", args.requirements, ["-e", str(REPO)])
                check_probe(probe(editable_env, work_dir), editable=True)

            if args.run_example:
                run_example(wheel_env, work_dir)
        except CheckError as exc:
            print(f"FAILED: {exc}", file=sys.stderr)
            return 1
    print("Packaging check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
