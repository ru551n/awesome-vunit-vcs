# Contributing to awesome-vunit-vcs

Contributions are welcome: new verification component (VC) families, new interfaces for an existing
family, bug fixes and documentation.

The full guide is in the
[documentation](https://awesome-vunit-vcs.readthedocs.io/en/latest/contributing/index.html): how a
new family or interface fits in, the VHDL, Python and documentation conventions, the test
requirements and the release process. Its source is in [`docs/contributing`](docs/contributing).

**VHDL handles simulation timing. Python handles verification semantics.**

## Development setup

The package depends on two unreleased packages, a VUnit with package setup hooks and
vunit-python-bridge. `tests/packaging/unreleased-requirements.txt` pins both to tested commits.

```bash
git clone https://github.com/ru551n/awesome-vunit-vcs.git
cd awesome-vunit-vcs
python -m venv .venv
source .venv/bin/activate
pip install -r tests/packaging/unreleased-requirements.txt
pip install -e ".[dev,reference]"
```

On Linux and macOS the bridge compiles its simulator library on first use, so a C compiler and the
Python development headers (for example `python3-dev`) are needed. Install GHDL, NVC or both for the
HDL tests.

## Checks

These are the checks CI runs. A pull request must pass all of them.

```bash
ruff check .                                   # lint
ruff format --check .                          # formatting
mypy                                           # strict type checking
pytest                                         # Python unit tests
VUNIT_SIMULATOR=ghdl python tests/vhdl/run.py -p 2
VUNIT_SIMULATOR=nvc python tests/vhdl/run.py -p 2
pytest tests/packaging                         # slow: builds and installs the wheel
pip install -r docs/requirements.txt
sphinx-build -W --keep-going -b html docs docs/_build
```

## Pull requests

Keep commits atomic, each with a message that says what changed and why. Every commit on `main`
passes the checks above. A new component or interface comes with its documentation; see the
[documentation checklist](https://awesome-vunit-vcs.readthedocs.io/en/latest/contributing/new_family.html#documentation-checklist).
