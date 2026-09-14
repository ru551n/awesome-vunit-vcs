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

## Calling Python from VHDL

`src/awesome_vunit_vcs/vhdl/common/vc_python_pkg.vhd` is the only VHDL file that uses the Python
bridge. A VC reaches its backend, the object `vc` in its session, through it:

* Create the backend with `create_backend(session, "module", "Class", args)` and call it with
  `backend_call(session, "method", args)` or a typed variant (`backend_call_integer`, `_boolean`,
  `_string`, `_integer_array`).
* Build `args` with the bridge's `arg` and `kwarg`, combined with `&`, for integers, reals, booleans,
  identifier-like strings and vectors. The bridge does not escape strings, so use `arg_text`/`kwarg_text`
  for any other text (messages, file names, seeds, paths); they arrive as character codes. Use
  `arg_time`/`kwarg_time` for times; they arrive as `[hi, lo]` since VHDL integers are 32 bits. The
  backend decodes them with `decode_text` and `decode_time_fs` from `awesome_vunit_vcs.common.vunit_bridge`.
* Never build Python source text from VHDL values (`"method(" & value & ")"`), and never call the
  bridge's `exec` or `eval` from a family package. `tests/python/test_python_call_guardrail.py`
  enforces both.
* Arguments a user gives to a procedure travel to the VC process with `push_arg`/`pop_arg`; `arg_t` is
  two strings, so it is safe in a message. Give them to the backend in a call of their own (the
  Ethernet backends' `set_arguments`, `PropertyRunner.start`) so they never collide with the
  backend method's own keyword arguments.

## Pull requests

Keep commits atomic, each with a message that says what changed and why. Every commit on `main`
passes the checks above. A new component or interface comes with its documentation; see the
[documentation checklist](https://awesome-vunit-vcs.readthedocs.io/en/latest/contributing/new_family.html#documentation-checklist).
