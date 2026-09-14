# awesome-vunit-vcs

[![CI](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml/badge.svg)](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml)
[![Documentation](https://readthedocs.org/projects/awesome-vunit-vcs/badge/?version=latest)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)
[![Python 3.10–3.14](https://img.shields.io/badge/python-3.10%E2%80%933.14-blue)](pyproject.toml)
[![Simulators: GHDL | NVC](https://img.shields.io/badge/simulators-GHDL%20%7C%20NVC-informational)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)

Third-party verification components for [VUnit](https://vunit.github.io/), starting with Ethernet.

**VHDL handles simulation timing. Python handles verification semantics.**

The VHDL components sample and drive the pins of your design at the right simulation edges. Python
reconstructs frames, checks the protocol, collects statistics, writes Wireshark captures and builds
packets, optionally with Scapy. Your testbench stays in VHDL and never needs to write Python.

**Documentation: <https://awesome-vunit-vcs.readthedocs.io>**

## Highlights

* Monitors that check every frame on their own: preamble, SFD, FCS, runts, oversized frames, PHY
  errors, control characters, inter-frame gaps and metavalues, each check individually switchable.
* Sources for good and deliberately malformed traffic: bad FCS, short preambles, wrong SFDs, injected
  errors and short gaps.
* A frame scoreboard, link statistics and PCAPNG captures with simulation timestamps.
* Native VUnit components: handles, `com` messages, `wait_until_idle` and VUnit check failures.
* A simulator independent Python core, unit tested and usable without a simulator.

## Status

Alpha: the APIs can still change, and the first release on PyPI is pending.

| Family | Interface | Status |
|---|---|---|
| Ethernet | GMII (1G, 2.5G) | Available |
| Ethernet | XGMII family: 2.5GMII, 5GMII, XGMII, 25GMII, XLGMII, CGMII, 200GMII, 400GMII | Available |
| Ethernet | MII (10M, 100M) | Available |
| Ethernet | RGMII, RMII, AXI-Stream MAC client | Planned |
| Flash | QSPI NOR flash model | In progress |

GHDL and NVC are tested in CI. See the [roadmap](https://awesome-vunit-vcs.readthedocs.io/en/latest/roadmap.html).

## Getting started

```bash
pip install awesome-vunit-vcs
```

Until the first release, and while its dependencies vunit-python-bridge and a VUnit with package setup
hooks are unreleased, install from the repository as the
[documentation](https://awesome-vunit-vcs.readthedocs.io) describes. Then add both packages to your
VUnit run script with `vu.add_package("vunit-python-bridge")` and `vu.add_package("awesome-vunit-vcs")`.

* [`examples/gmii`](examples/gmii): a complete testbench around a small DUT, with a source, monitors,
  the scoreboard, statistics, a capture and Scapy.
* [`examples/python`](examples/python): the Python core without a simulator, as used in the
  [Python guide](https://awesome-vunit-vcs.readthedocs.io/en/latest/python_guide.html).

## Learn more

* [Documentation](https://awesome-vunit-vcs.readthedocs.io): installation, user guides, Python and
  VHDL API reference.
* [Architecture](https://awesome-vunit-vcs.readthedocs.io/en/latest/explanation/architecture.html):
  how VHDL and Python share the work.
* [Contributing](CONTRIBUTING.md): development setup, checks and how a new component family fits in.

## License

[Mozilla Public License 2.0](LICENSE).
