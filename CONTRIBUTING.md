# Contributing to awesome-vunit-vcs

Contributions are welcome: new verification component (VC) families, new interfaces for an existing
family, bug fixes and documentation. This document describes how the repository is organized and
what a change needs before it can be merged.

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
Python development headers (for example `python3-dev`) are needed. Install GHDL and/or NVC for the
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
```

The documentation is built with warnings as errors:

```bash
pip install -r docs/requirements.txt
sphinx-build -W --keep-going -b html docs docs/_build
```

The bridge benchmark is not part of CI:

```bash
python benchmarks/run.py -p 1 -v | grep BENCHMARK
```

## The rule every component follows

**VHDL handles simulation timing. Python handles verification semantics.**

VHDL samples and drives pins at the right simulation edges and exchanges batched observations with
a Python backend object. Python never accesses simulator signals and never schedules simulation
time. A VHDL user controls a component through VHDL procedures only; Python-specific features are
additive. See [ARCHITECTURE.md](ARCHITECTURE.md) for the reasoning.

## Adding a VC family

A family (for example `i2c`, `axi` or `mdio`) is a Python subpackage plus a VHDL directory. Ethernet
is the reference:

```text
src/awesome_vunit_vcs/
├── common/                     shared infrastructure, reused by every family
│   ├── events.py               Publisher: sample once, fan out to subscribers
│   ├── reports.py              reports from a backend to the VHDL logger/checker
│   └── vunit_bridge.py         sample batch encoding (Python side)
├── ethernet/                   simulator independent core + backends
│   ├── frame.py, checker.py, metrics.py, pcap.py, source.py, ...
│   ├── phy/                    one decoder/encoder per interface
│   └── vunit_backend.py        the objects the VHDL components create
├── vhdl/
│   ├── common/vcs_python_pkg.vhd   the only VHDL file that uses the bridge
│   └── ethernet/
│       ├── ethernet_pkg.vhd        handles, procedures, message types
│       ├── gmii_pkg.vhd            constructors of one interface
│       ├── gmii_monitor.vhd        pin timing of one interface
│       ├── gmii_source.vhd
│       └── ethernet_context.vhd    what a testbench uses
└── vunit_pkg.toml
```

For a new family `<family>`:

1. **Python core** in `src/awesome_vunit_vcs/<family>/`. It must be usable from plain Python and
   fully unit tested without a simulator. Prefer dataclasses and explicit types, keep public APIs
   small and avoid global mutable state, since several VC instances run in one interpreter.
2. **Backend** in `src/awesome_vunit_vcs/<family>/vunit_backend.py`: one class per VC kind. VHDL
   creates one instance per VC, as the object `vc` in a Python session with the identity of the VC.
   Backend methods:
   * take and return what the bridge transfers efficiently: integers, strings, booleans and
     `integer_array_t` (NumPy arrays),
   * never let an exception escape into the bridge. Catch it and add a report, as
     `ethernet/vunit_backend.py` does, so that the failure is logged on the VC logger with a useful
     message instead of a traceback,
   * queue protocol violations as reports (`common/reports.py`) and return the number of reports
     waiting, so VHDL only fetches them when there are some.
3. **VHDL** in `src/awesome_vunit_vcs/vhdl/<family>/`. `vunit_pkg.toml` includes
   `vhdl/**/*.vhd`, so new files are compiled into the `awesome_vunit_vcs` library without changing
   it. Reuse `vcs_python_pkg`: `new_vc_session`, `create_backend`, `backend_exec`/`backend_*`,
   `log_reports`, and for passive components `new_sample_batch`, `record_sample` and
   `flush_samples`. Never call the bridge from a family package directly; `vcs_python_pkg` is where
   bridge API changes are absorbed.
4. **Batching.** Do not make one bridge call per clock cycle. Record samples only when something
   changes or data is valid, and flush at batch end or when the backend must be up to date (end of
   a transfer, `wait_until_idle`). The GMII benchmark in ARCHITECTURE.md shows why.
5. **Metavalues.** Map `X`/`U`/`Z`/`W`/`-` on sampled pins to dedicated bits of the sample word
   and report them. Never silently convert them to `0`.
6. **Shared infrastructure.** Extract something into `common/` only when a second family actually
   needs it.

Adding an interface to the Ethernet family (MII, RGMII, ...) needs a PHY decoder/encoder in
`ethernet/phy/`, registered in `ethernet/phy/__init__.py`, a value of `ethernet_phy_t`, constructors
in a `<interface>_pkg.vhd`, the monitor and source entities, and tests. Handles, procedures and the
Python core are shared. If the common model cannot express the interface, fix the model first
rather than working around it in the frontend.

## VHDL conventions

Components should feel like VUnit's own verification components:

* A handle record with private `p_` fields around a `std_cfg_t`, created by a `new_*` function with
  `id`, the component options and `unexpected_msg_type_policy`.
* Accessors `get_id`, `get_logger`, `get_checker` and `as_sync`. `wait_until_idle(net,
  as_sync(vc))` from `sync_pkg` is supported.
* Procedures taking `signal net : inout network_t` that send `com` messages, and message types
  created with `new_msg_type`.
* A `<family>_pkg` with the handles and procedures, and a `<family>_context` a testbench uses.
* Errors a VC detects go to its checker, everything else to its logger.
* The MPL-2.0 license header at the top of every file.

The repository also applies these style rules:

* Names are `lower_snake_case` without prefixes: no `g_`, `c_`, `C_`, `v_` or `p_` on generics,
  constants, variables or processes. Types and subtypes end in `_t`, enumeration literals are
  lowercase. The private `p_` record fields above are VUnit's convention and the only exception.
* Architectures are named `a` for components and `tb` for testbenches. The main process is `main`,
  instance labels end in `_inst`.
* Declarations, generic maps and port maps are not column aligned.
* Non-obvious generics and ports have a `--` comment directly above them.
* Ports are `std_ulogic`/`std_ulogic_vector`. VUnit's own VCs use `std_logic`, which is compatible
  when a testbench connects them to resolved signals. Unresolved types catch multiple drivers at
  elaboration.
* Integer counts in simulation-only code may be unconstrained `natural`; range constraints matter
  for synthesizable code.
* Code is VHDL-2008. No unfinished `--@` markers in merged code.

Python code is formatted and linted with ruff (line length 120), type checked with mypy in strict
mode and stays compatible with Python 3.10.

## Tests

* **Python unit tests** (`tests/python`) for all simulator independent logic. Compare against
  independent references, never against the code under test: `tests/python/helpers.py` builds wire
  frames octet by octet with a bitwise CRC-32, and `test_references.py` cross-checks against
  cocotbext-eth when it is installed.
* **HDL tests** (`tests/vhdl`) for the bridge and pin behavior, passing on both GHDL and NVC. Use
  VUnit test cases named `test_*`, `test_runner_watchdog` at architecture level and a random
  generator seeded with `get_string_seed(runner_cfg)` where stimulus is random.
* **Negative tests** assert violations instead of failing: `disable_stop(get_logger(vc), error)`,
  then check the violation counts and `get_log_count`, and `reset_log_count` afterwards. An error
  that is not counted still fails the test at `test_runner_cleanup`.
* **Packaging.** When a change affects what is installed, `pytest tests/packaging` must pass: it
  builds the wheel, installs it into a clean environment and runs `examples/external_project`.

## Releasing

Releases are published to PyPI by `.github/workflows/release.yml` with
[trusted publishing](https://docs.pypi.org/trusted-publishers/), so no API token is stored in the
repository. The version lives in `pyproject.toml` and `src/awesome_vunit_vcs/__init__.py`, and a
release is made by tagging the commit that sets it:

```bash
# 1. Set the same version in pyproject.toml and src/awesome_vunit_vcs/__init__.py
python tools/release.py validate --tag v0.1.0a1   # same check the workflow makes
git commit -am "Release 0.1.0a1"
git push
# 2. Tag with the release notes as the tag message, then push the tag
git tag -a v0.1.0a1 -m "Release notes..."
git push origin v0.1.0a1
```

The tag starts the workflow: check the version against the tag, build the wheel and sdist, check
their content, install the built wheel into a clean environment and run `examples/external_project`
against it with NVC, publish to PyPI, and create the GitHub release with the tag message as its
body. Pre-release versions become GitHub pre-releases.

**Only pre-releases for now.** `ALLOW_FINAL_RELEASES` in `tools/release.py` is `False`, so only
`aN`, `bN`, `rcN` and `.devN` versions can be released. The package needs `vunit_hdl>=5.0.0.dev12`
with package setup hooks and `vunit-python-bridge`, and neither is on PyPI, so a final release
could not be installed. Flip the switch once both are published.

**Rehearsal.** Running the workflow manually from the Actions tab does everything except publishing
to PyPI and creating the release. It gives the checkout a unique development version,
`<version>.dev<run number>` (replacing an existing `.devN`), and uploads that to
[TestPyPI](https://test.pypi.org/project/awesome-vunit-vcs/), since an index never accepts the same
version twice.

The `pypi` and `testpypi` GitHub environments hold the deployments. PyPI and TestPyPI each trust
this repository, the workflow `release.yml` and the environment of the same name.

## Commits and pull requests

Keep commits atomic, each with a message saying what changed and why. Every commit on `main` should
pass the checks above.
