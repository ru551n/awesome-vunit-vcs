# awesome-vunit-vcs

Third-party verification components for [VUnit](https://vunit.github.io/), starting with Ethernet.

**VHDL handles simulation timing. Python handles Ethernet verification semantics.**

The VHDL components sample and drive PHY pins at the right simulation edges and exchange batched
observations with Python through the VUnit Python bridge. Python reconstructs frames, checks the
protocol, collects statistics, writes Wireshark captures and builds packets, optionally with Scapy.
A testbench controls everything from VHDL and never needs to write Python.

Documentation: <https://awesome-vunit-vcs.readthedocs.io> (intended URL, being set up).

## Status

Alpha. The APIs can still change.

* GMII monitor and source: complete, 16 HDL tests passing on GHDL and NVC.
* The simulator independent Python core (frames, checker, statistics, PCAPNG, sources): complete,
  unit tested.
* XGMII family: in progress. MII, RGMII, RMII and an AXI-Stream MAC client: planned.
* Not released on PyPI yet, and it depends on two unreleased packages (see [Installation](#installation)).

## Architecture

```text
                              awesome-vunit-vcs
                                      |
               +----------------------+----------------------+
               |                                             |
      VHDL interface frontends                         Python backend
    (pin timing, sampling, driving)             (Ethernet verification semantics)
               |                                             |
   +------+----+----+-------+------+          +-----------+--+--------+------------+
   |      |         |       |      |          |           |           |            |
  GMII  XGMII      MII    RGMII   RMII    frame core   protocol   statistics   integrations
                                          (preamble,   checker                (PCAPNG, Scapy)
                                           SFD, FCS)
               |                                             ^
               +--- batches of samples (integer_array_t) ---+
               <--- symbols to drive, reports to log --------
```

A monitor samples its interface once and sends the samples in batches. In Python the frames fan
out to the protocol checker, the statistics, captures and any user subscriber. Violations come
back to VHDL as VUnit check failures on the logger of the component. A source works the other way:
Python decides *what* is transmitted, VHDL decides *when* pins change.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design, the bridge benchmark and why cocotb's
simulator objects are not used.

## Installation

Requirements:

* CPython 3.10 or later with a shared `libpython` (distribution Pythons, `actions/setup-python`,
  `uv` and `pyenv` builds have one).
* [vunit-python-bridge](https://github.com/ru551n/vunit-python-bridge), the VUnit package that lets
  VHDL call Python. It is a dependency and installed with awesome-vunit-vcs.
* A VUnit with package setup hooks ([VUnit/vunit#1221](https://github.com/VUnit/vunit/pull/1221)).
* On Linux and macOS a C compiler and the Python development headers (for example `python3-dev`):
  the bridge compiles its simulator library on first use.
* A simulator, see [Simulators](#simulators).

Once released:

```bash
pip install awesome-vunit-vcs            # add [scapy] for the Scapy integration
```

Until then, install the unreleased dependencies pinned in
`tests/packaging/unreleased-requirements.txt`, then the package:

```bash
git clone https://github.com/ru551n/awesome-vunit-vcs.git
cd awesome-vunit-vcs
pip install -r tests/packaging/unreleased-requirements.txt
pip install ".[scapy]"                   # or pip install -e ".[dev]" to develop it
```

## VUnit package integration

awesome-vunit-vcs is a VUnit package: `add_package` finds the installed Python package and compiles
its VHDL into the library `awesome_vunit_vcs`. Nothing refers to where it is installed.

```python
from pathlib import Path

from vunit import VUnit

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge")
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(Path(__file__).parent / "*.vhd")

vu.main()
```

The two packages can be added in either order. There is no `add_python()` call: the bridge is the
`vunit-python-bridge` package. A testbench uses the components through one context:

```vhdl
library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
```

## Examples

The VHDL examples are taken from `examples/external_project/tb_gmii_monitor.vhd` and
`tests/vhdl/tb_gmii.vhd`, which run in CI. `frame` is a `std_ulogic_vector` with the octets from the
destination address up to the FCS, leftmost octet first.

### GMII monitor

```vhdl
architecture tb of tb_gmii_monitor is
  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant monitor : ethernet_monitor_t := new_gmii_monitor;
  constant frame : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5" & x"48656C6C6F";
begin
  main : process
  begin
    test_runner_setup(runner, runner_cfg);
    -- The next frame must carry these octets; a mismatch is a check failure
    expect_ethernet_frame(net, monitor, frame);
    -- ... the DUT transmits ...
    wait_until_idle(net, as_sync(monitor));
    test_runner_cleanup(runner);
  end process;

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => data,
      dv => dv,
      er => er
    );
end architecture;
```

The monitor checks every frame on its own: preamble, SFD, FCS, runts, oversized frames, PHY errors,
inter-frame gaps and metavalues. Several monitors in one testbench have independent Python state.

### GMII source

```vhdl
constant source : ethernet_source_t := new_gmii_source;
...
send_ethernet_frame(net, source, frame);                   -- padded, with a correct FCS
send_ethernet_frame(net, source, frame, fcs => fcs_bad);   -- deliberately malformed traffic:
send_ethernet_frame(net, source, frame, pad => false);     -- fcs_bad, runts, short preambles,
send_ethernet_frame(net, source, frame, sfd => x"D4");     -- wrong SFDs, PHY errors, short IFGs
send_ethernet_frame(net, source, frame, error_offsets => (0 => 20), ifg_octets => 8);
wait_until_idle(net, as_sync(source));
...
source_inst : entity awesome_vunit_vcs.gmii_source
  generic map (
    source => source
  )
  port map (
    clk => clk,
    data => data,
    dv => dv,
    er => er
  );
```

### Protocol checker

Checks can be disabled per monitor and their violations counted. To test that a violation is
detected, count the errors instead of stopping at the first one:

```vhdl
set_check_enabled(net, second_monitor, eth_fcs, false);

disable_stop(get_logger(monitor), error);
send_ethernet_frame(net, source, frame, fcs => fcs_bad);
wait_until_idle(net, as_sync(source));
wait_until_idle(net, as_sync(monitor));
get_check_count(net, monitor, eth_fcs, count);
check_equal(count, 1);
check_equal(get_log_count(get_logger(monitor), error), 1);
reset_log_count(get_logger(monitor), error);
```

A violation reads like this in the simulation log:

```text
ETH_FCS: bad FCS on frame 1
expected=0x2D992829
received=0xD266D7D6
SFD time=760000000 fs
length=64 bytes
```

### Performance monitor

```vhdl
get_statistics(net, monitor, statistics);   -- ethernet_statistics_t
check_equal(statistics.good_frames, 200);
log_statistics(net, monitor);               -- a summary on the logger of the monitor
```

The summary is only logged when asked for:

```text
gmii_rx statistics
frames: total=2 good=1 bad=1
octets: wire=144 frame=128 payload=92
errors: fcs=1 phy_frames=0 phy_symbols=0 idle=0 runt=0 giant=0 preamble=0 sfd=0 alignment=0
frame size: min=64 max=64 mean=64.0 octets
inter-frame gap: min=12 max=12 mean=12.0 octets
window: 1248000000 fs, 1602564.1 frames/s, bit rate 820.513 Mbit/s
utilization: link 92.31 %, payload 58.97 %
size histogram: <64=0 64=2 65-127=0 128-255=0 256-511=0 512-1023=0 1024-1518=0 >1518=0
```

### PCAP/Wireshark

```vhdl
start_capture(net, monitor, output_path(runner_cfg) & "gmii.pcapng");
-- ... traffic ...
wait_until_idle(net, as_sync(monitor));
stop_capture(net, monitor);
```

Open the file in Wireshark, which is found in the test output directory under `vunit_out`. The
capture is PCAPNG with nanosecond timestamps taken from the simulation time of each frame. It holds
the frames without preamble and SFD, with the FCS unless `include_fcs => false`, and bad frames
unless `include_errored => false`. Captures still open at the end of the simulation are closed.

### Scapy (optional)

With the `scapy` extra installed, a source can transmit a packet a Scapy expression builds:

```vhdl
send_ethernet_packet(
  net, source, "Ether(dst='02:00:00:00:00:01')/IP(dst='192.168.1.10')/UDP(dport=1234)/Raw(b'hello')"
);
```

and received frames can be inspected as Scapy packets. The backend of a monitor is the object `vc`
in the Python session with the identity of the monitor:

```vhdl
library python_bridge;
context python_bridge.python_context;
...
check_equal(eval_integer("vc.last_packet()['UDP'].dport", new_session(get_id(monitor))), 1234);
```

### Python only

The Ethernet core does not need a simulator. The frames a monitor reconstructs are delivered to
any subscriber:

```python
import numpy as np

from awesome_vunit_vcs.ethernet import EthernetMonitor, build_wire_frame
from awesome_vunit_vcs.ethernet.phy import GmiiPhy
from awesome_vunit_vcs.ethernet.scapy_adapter import to_scapy

phy = GmiiPhy()
payload = bytes.fromhex("020000000001" "020000000002" "88b5") + b"hello"
words = np.concatenate([phy.encode(build_wire_frame(payload)), phy.encode(build_wire_frame(payload, fcs="bad"))])
times_fs = np.arange(words.size, dtype=np.int64) * 8_000_000  # 125 MHz

monitor = EthernetMonitor(phy, name="gmii_rx")
monitor.frames.subscribe(lambda frame: print(frame.index, frame.fcs_ok, frame.timestamp_sfd_fs))
monitor.checker.violations.subscribe(lambda violation: print(violation.message))
monitor.feed(words.astype(np.int64), times_fs)

print(monitor.statistics.snapshot().summary("gmii_rx"))
print(to_scapy(monitor.history[0]).dst)  # needs Scapy
```

## Interfaces

| Interface | Link rates | Data / control per clock | Status |
|---|---|---|---|
| GMII | 1G, 2.5G (overclocked) | 8-bit data, EN/DV, ER | Done |
| XGMII family (2.5GMII, 5GMII, XGMII, 25GMII, XLGMII, CGMII) | 2.5G to 100G | 32-bit data + 4 control, or 64-bit data + 8 control | In progress |
| MII | 10M, 100M | 4-bit data, DV, ER | Planned |
| RGMII | 10M, 100M, 1G | 4-bit data, CTL on both clock edges | Planned |
| RMII | 10M, 100M | 2-bit data, TX_EN, CRS_DV | Planned |
| AXI-Stream MAC client | any | tdata, tkeep, tlast, tuser | Planned |

Serial and PCS-level interfaces are not planned for now. See [docs/roadmap.md](docs/roadmap.md).

## Simulators

| Simulator | Status |
|---|---|
| GHDL | Tested in CI |
| NVC | Tested in CI |
| Questa/ModelSim | Supported by vunit-python-bridge, untested with these components |
| Riviera-PRO, Active-HDL | vunit-python-bridge supports a subset of its API; untested with these components |

## Roadmap

1. XGMII family with 4 or 8 lanes and link rates from 2.5G to 100G.
2. MII, RGMII and RMII frontends on the same Python core.
3. An AXI-Stream MAC client frontend.
4. Correlation of transmitted and received streams for latency metrics.

The details are in [docs/roadmap.md](docs/roadmap.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, the checks and how a new
component family fits in.

## License

[Mozilla Public License 2.0](LICENSE).
