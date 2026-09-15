# awesome-vunit-vcs

[![CI](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml/badge.svg)](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml)
[![Documentation](https://readthedocs.org/projects/awesome-vunit-vcs/badge/?version=latest)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-blue)](https://github.com/ru551n/awesome-vunit-vcs/blob/main/LICENSE)
[![Python 3.10–3.14](https://img.shields.io/badge/python-3.10%E2%80%933.14-blue)](https://github.com/ru551n/awesome-vunit-vcs/blob/main/pyproject.toml)
[![Simulators: GHDL | NVC](https://img.shields.io/badge/simulators-GHDL%20%7C%20NVC-informational)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange)](https://github.com/ru551n/awesome-vunit-vcs#status)

**Verification components for [VUnit](https://vunit.github.io/) that feel like VUnit's own:
Ethernet, QSPI flash, and property-based testing with Hypothesis inside the simulation.**

Connect a component to the pins of your design and it sends, receives and checks traffic for you. Your
testbench stays in VHDL, and the components do the protocol work in Python behind the scenes.

> **VHDL handles simulation timing. Python handles verification semantics.**

📖 **Documentation:** <https://awesome-vunit-vcs.readthedocs.io>

## Highlights

- **Native VUnit components.** Handles made by `new_<component>`, `com` messages, `wait_until_idle`,
  `reset` and ordinary VUnit check failures. One context clause per family is all a testbench needs.
- **Checks you would otherwise write by hand.** Monitors check preamble, SFD, FCS, frame length, PHY
  errors, control characters, inter-frame gaps and metavalues, each check switchable.
- **Good and deliberately broken traffic.** Sources send bad FCS, short preambles, wrong SFDs, errors
  and short gaps as easily as clean frames.
- **Scoreboards, statistics and Wireshark captures** with simulation timestamps.
- **Property-based testing in VHDL.** Hypothesis draws the stimulus, your testbench runs it through the
  design, and a failure shrinks to the smallest input that still fails.
- **Python where it helps.** Build frames, model a flash device or write strategies in plain Python,
  including in `pytest` without a simulator.

## What's inside

| Family | Interfaces | Components |
|---|---|---|
| **Ethernet** | GMII (1G, 2.5G), MII (10M, 100M), RGMII (10M–1G), RMII (10M, 100M) | source, monitor, protocol checker |
| | XGMII family, 2.5G to 400G: 2.5GMII, 5GMII, XGMII, 25GMII, XLGMII, CGMII, 200GMII, 400GMII | source, monitor, protocol checker |
| | AXI-Stream MAC client, any width, with backpressure | source, sink, monitor, protocol checker |
| **Flash** | QSPI NOR flash, x1, x2 and x4 lanes | flash responder, QSPI master, QSPI protocol checker |
| **Property-based testing** | Any design | `property_pkg`: Hypothesis strategies, stateful tests, scores, lockup handling, replay |

Every component is tested with GHDL and NVC in CI.

### Property-based testing, by example

[`examples/property`](https://github.com/ru551n/awesome-vunit-vcs/tree/main/examples/property) has a small, runnable example for each common technique, many
with a planted bug you can switch on to watch Hypothesis find and shrink it:

- scalar, composite and stateful properties, and resource lifecycles with Hypothesis Bundles
- interleaved event schedules, recursive grammar-based inputs, and timing and clock ratio/phase (CDC)
- fault injection, invalid-input mutation, and lockup handling and recovery
- differential, round-trip and metamorphic properties, with hardware bit-pattern strategies
- targeting with scores, swarm testing, and a paired check that AXI4-Stream TVALID does not wait for TREADY

See [Technique examples](https://awesome-vunit-vcs.readthedocs.io/en/latest/property_testing/techniques.html)
for the full list.

## Install

Requirements: CPython 3.10–3.14, GHDL or NVC, and on Linux or macOS a C compiler with the Python
development headers. The package is not on PyPI yet, and it needs two unreleased dependencies, pinned
to tested commits: VUnit with package setup hooks and
[vunit-python-bridge](https://github.com/ru551n/vunit-python-bridge). Install them, then the package,
from GitHub:

```bash
pip install -r https://raw.githubusercontent.com/ru551n/awesome-vunit-vcs/main/tests/packaging/unreleased-requirements.txt
pip install "awesome-vunit-vcs @ git+https://github.com/ru551n/awesome-vunit-vcs"
pip install hypothesis  # only for property-based testing
```

The [installation guide](https://awesome-vunit-vcs.readthedocs.io/en/latest/getting_started/installation.html)
covers optional extras and installing from a clone.

## Get started

1. **[Quick start](https://awesome-vunit-vcs.readthedocs.io/en/latest/getting_started/quickstart.html):**
   a GMII testbench with a scoreboard and a Wireshark capture in five minutes. From a clone, run it
   with `VUNIT_SIMULATOR=nvc python examples/quickstart/run.py --output-path ../vunit_out`.
2. **[Cookbook](https://awesome-vunit-vcs.readthedocs.io/en/latest/cookbook/index.html):**
   step-by-step recipes, from a first test to error injection, flash boot and property-based testing.
3. **[`examples/`](https://github.com/ru551n/awesome-vunit-vcs/tree/main/examples):** complete, tested projects that the documentation is built from.

Add the components to a VUnit run script with `vu.add_package("vunit-python-bridge", allow_setup=True)`
and `vu.add_package("awesome-vunit-vcs")`, as the quick start shows.

## Status

Alpha: the APIs can still change before the first release. The
[roadmap](https://awesome-vunit-vcs.readthedocs.io/en/latest/roadmap.html) lists what comes next.

## For AI agents

- [llms.txt](https://awesome-vunit-vcs.readthedocs.io/en/latest/llms.txt) and
  [llms-full.txt](https://awesome-vunit-vcs.readthedocs.io/en/latest/llms-full.txt) index the
  documentation.
- `api/vhdl.json`, `api/python.json` and `api/examples.json` on Read the Docs give exact signatures and
  map each cookbook task to its example.
- [AGENTS.md](https://github.com/ru551n/awesome-vunit-vcs/blob/main/AGENTS.md) is for agents working on this repository.

## Contributing

Contributions are welcome: see [CONTRIBUTING.md](https://github.com/ru551n/awesome-vunit-vcs/blob/main/CONTRIBUTING.md), and [ARCHITECTURE.md](https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md)
for the design.

## License

[Mozilla Public License 2.0](https://github.com/ru551n/awesome-vunit-vcs/blob/main/LICENSE)
