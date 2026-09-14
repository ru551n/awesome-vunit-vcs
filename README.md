# awesome-vunit-vcs

[![CI](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml/badge.svg)](https://github.com/ru551n/awesome-vunit-vcs/actions/workflows/ci.yml)
[![Documentation](https://readthedocs.org/projects/awesome-vunit-vcs/badge/?version=latest)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)
[![Python 3.10–3.14](https://img.shields.io/badge/python-3.10%E2%80%933.14-blue)](pyproject.toml)
[![Simulators: GHDL | NVC](https://img.shields.io/badge/simulators-GHDL%20%7C%20NVC-informational)](https://awesome-vunit-vcs.readthedocs.io/en/latest/)

Verification components for [VUnit](https://vunit.github.io/) that work like VUnit's own.

**VHDL handles simulation timing. Python handles verification semantics.**

Connect the components to the pins of your design, and they send, receive and check traffic for you.
Your testbench stays in VHDL.

**Documentation: <https://awesome-vunit-vcs.readthedocs.io>**

## What you get

* **Monitors** that check every frame: preamble, SFD, FCS, runts, oversized frames, PHY errors,
  control characters, inter-frame gaps and metavalues. Each check can be switched off.
* **Sources** for good and deliberately broken traffic: bad FCS, short preambles, wrong SFDs, errors
  and short gaps.
* **A scoreboard, statistics and Wireshark captures** with simulation timestamps.
* **Property-based testing** with Hypothesis inside the simulation, down to the smallest failing input.
* **Native VUnit components**: handles, `com` messages, `wait_until_idle` and VUnit check failures.

## Status

Alpha: the APIs can still change, and the package is not on PyPI yet.

| Family | Interface | Status |
|---|---|---|
| Ethernet | GMII (1G, 2.5G) | Available |
| Ethernet | XGMII family: 2.5GMII, 5GMII, XGMII, 25GMII, XLGMII, CGMII, 200GMII, 400GMII | Available |
| Ethernet | MII (10M, 100M) | Available |
| Ethernet | RGMII (10M, 100M, 1G) | Available |
| Ethernet | RMII (10M, 100M) | Available |
| Ethernet | AXI-Stream MAC client (any width, with backpressure) | Available |
| Flash | QSPI NOR flash, QSPI master and QSPI protocol checker | Available |

GHDL and NVC are tested in CI. See the [roadmap](https://awesome-vunit-vcs.readthedocs.io/en/latest/roadmap.html).

## Install

```bash
pip install awesome-vunit-vcs
```

Until the first release, install from the repository as the
[installation guide](https://awesome-vunit-vcs.readthedocs.io/en/latest/getting_started/installation.html)
describes.

## Next steps

* [Quick start](https://awesome-vunit-vcs.readthedocs.io/en/latest/getting_started/quickstart.html):
  your first testbench in five minutes.
* [Cookbook](https://awesome-vunit-vcs.readthedocs.io/en/latest/cookbook/index.html): recipes for
  common tasks.
* [`examples/`](examples): complete, tested example projects.
* [Contributing](CONTRIBUTING.md) and [Architecture](ARCHITECTURE.md) for developers.

## License

[Mozilla Public License 2.0](LICENSE).
