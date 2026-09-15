# AGENTS.md

Instructions for AI coding agents working on awesome-vunit-vcs, a VUnit package of verification
components: Ethernet (GMII, MII, RGMII, RMII, XGMII, AXI-Stream MAC client), a QSPI NOR flash with a
QSPI master and protocol checker, and property-based testing with Hypothesis inside a simulation.
VHDL handles simulation timing; Python handles verification semantics.

## Environment

The package depends on two unreleased packages, pinned in `tests/packaging/unreleased-requirements.txt`:
VUnit with package setup hooks and vunit-python-bridge. Install them from that file, never from a
local VUnit checkout.

```bash
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python -r tests/packaging/unreleased-requirements.txt
uv pip install --python .venv/bin/python -e ".[dev,reference]"
uv pip install --python .venv/bin/python -r docs/requirements.txt
source .venv/bin/activate
```

- Simulators: GHDL and NVC, selected with `VUNIT_SIMULATOR=ghdl` or `VUNIT_SIMULATOR=nvc`. On Linux and
  macOS the bridge compiles its simulator library on first use, so a C compiler and the Python
  development headers are needed.
- Working in a git worktree while the environment has an editable install of another checkout: set
  `PYTHONPATH=$PWD/src`, or the tests import the other checkout's sources.
- Run `tests/packaging/check_package.py` without `PYTHONPATH`: it checks that VUnit finds the installed
  wheel, not a source tree.
- Write simulation output with `--output-path` to a directory you delete afterwards. Delete temporary
  directories by exact path, never with a glob.

## Checks

CI (`.github/workflows/ci.yml`, `docs.yml`) runs all of these; every commit on `main` passes them.

```bash
ruff check .
ruff format --check .
mypy                                              # strict, src/awesome_vunit_vcs
pytest                                            # Python unit tests
VUNIT_SIMULATOR=nvc python tests/vhdl/run.py -p 2 --output-path out/tests   # and ghdl
VUNIT_SIMULATOR=nvc python examples/quickstart/run.py -p 2 --output-path out/quickstart
VUNIT_SIMULATOR=nvc python examples/gmii/run.py -p 2 --output-path out/gmii
VUNIT_SIMULATOR=nvc python examples/cookbook/run.py -p 2 --output-path out/cookbook
VUNIT_SIMULATOR=nvc python examples/flash/run.py -p 2 --output-path out/flash
VUNIT_SIMULATOR=nvc python examples/property/run.py -p 2 --output-path out/property
sphinx-build -W -n --keep-going -b html docs docs/_build
pytest tests/python/test_agent_docs.py tests/python/test_docs.py   # docs guardrails, need docs requirements
VUNIT_SIMULATOR=nvc python tests/packaging/check_package.py --run-example  # slow: wheel, install, external project
```

Run every HDL suite on both GHDL and NVC before pushing HDL changes. The nightly workflow runs the
property examples with `AWESOME_VUNIT_VCS_PROPERTY_PROFILE=long`.

## Layout

- `src/awesome_vunit_vcs/`: the package. `vhdl/<family>/` holds the VHDL (`common`, `ethernet`,
  `flash`); `common/`, `ethernet/`, `flash/`, `records.py` and `gen_vhdl.py` hold the Python.
  `vunit_pkg.toml` tells VUnit which sources to compile.
- `tests/python/`: pytest, including the docs guardrails (`test_docs.py`, `test_agent_docs.py`).
- `tests/vhdl/`: VUnit testbenches (`run.py`), including one `tb_<component>_vci.vhd` conformance
  testbench per component.
- `tests/packaging/`: the wheel/install check and the pinned unreleased requirements.
- `examples/`: tested example projects; the documentation includes code only from here.
- `docs/`: Sphinx. One section per family (`ethernet/`, `property_testing/`, `flash/`, `common/`), each
  with usage pages, `vhdl_api.rst` and `python_api.rst`; `cookbook/` holds the step-by-step articles.
- `tools/`: `vhdl_docs.py` (VHDL reference from doc comments), `api_index.py` (api/*.json),
  `llms_docs.py` (llms.txt), `release.py`.
- `ARCHITECTURE.md`: design decisions, benchmarks and limitations. `CONTRIBUTING.md`: human guide.

## Rules for code

- Verification components follow VUnit's conventions: the handle is the entity's only generic; one
  handle type per component, created by `new_<component>`; constructor parameters end with `id`,
  `logger`, `actor`, `checker`, `unexpected_msg_type_policy`; port widths come from accessor functions,
  never `p_` fields; every component supports `wait_until_idle`, `wait_for_time` and `reset`; protocol
  checks live in a separate `<interface>_protocol_checker`. Details: `docs/contributing/conventions.rst`.
- One context clause per family (`ethernet_context`, `flash_context`, `property_context`) must be all
  a testbench needs.
- VHDL calls Python only through `vc_python_pkg` (`create_backend`, `backend_call*`) with typed
  arguments (`arg`/`kwarg`, `arg_text`/`kwarg_text`, `arg_time`/`kwarg_time`). Never build Python
  source text from VHDL values or call `exec`/`eval` from a family package; a guardrail test enforces it.
- Adding the bridge in a run script is `vu.add_package("vunit-python-bridge", allow_setup=True)`.
- VHDL style: `lower_snake_case` without prefixes, `std_ulogic` ports, rst doc comments directly above
  every public declaration (they generate the VHDL reference).
- Python: typed (`mypy --strict`), frozen value types, errors derive from
  `awesome_vunit_vcs.errors.AwesomeVunitVcsError`; the package must not import Hypothesis.
- Add a line to `docs/release_notes/unreleased.rst` for user-visible changes, under "Breaking changes"
  when behaviour changes.

## Rules for documentation

- Rendered docs explain how and when to use things. Design rationale, benchmarks and limitations
  lists belong in `ARCHITECTURE.md`.
- Show code only with `literalinclude` from tested files in `examples/`, selected with
  `-- docs-start: <name>` / `-- docs-end: <name>` markers (unique per file). Never `:lines:`, never
  from `tests/`. Every code block has a `:caption:` naming its file.
- Say in every step whether code goes in VHDL (the testbench) or Python (your module). Build from the
  simplest working example to advanced use.
- Every public VHDL declaration and every `__all__` name must appear in the family's API page.

## Commits and CI

- Small commits, each passing the checks above; imperative subject lines that say what changed.
- Push to `main` only when green; never force-push. After pushing, wait for the CI and Docs
  workflows and check the Read the Docs build.

## Using this package from an agent

- Documentation for agents: https://awesome-vunit-vcs.readthedocs.io/en/latest/llms.txt (index) and
  https://awesome-vunit-vcs.readthedocs.io/en/latest/llms-full.txt (all pages); every page also has
  a `.md` version next to its `.html`.
- Exact signatures: https://awesome-vunit-vcs.readthedocs.io/en/latest/api/vhdl.json and
  `api/python.json`; `api/examples.json` maps each cookbook task to its example, test case and run
  command. Schemas are in `api/schema/`.
