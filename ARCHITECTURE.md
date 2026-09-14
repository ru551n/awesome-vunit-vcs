# Architecture

Technical notes for contributors: how a verification component (VC) is split between VHDL and Python,
the decisions behind that split, performance measurements, known limitations and the specifications
the models follow. User documentation lives at <https://awesome-vunit-vcs.readthedocs.io>.

**VHDL handles simulation timing. Python handles verification semantics.**

## Contents

- [The boundary](#the-boundary)
- [Anatomy of a component](#anatomy-of-a-component)
- [Sessions and identity](#sessions-and-identity)
- [How a component finds its Python backend](#how-a-component-finds-its-python-backend)
- [Sample batches](#sample-batches)
- [Reports](#reports)
- [What belongs where, per interface](#what-belongs-where-per-interface)
- [Active sources and responders](#active-sources-and-responders)
- [Design decisions](#design-decisions)
- [Performance](#performance)
- [Known limitations](#known-limitations)
- [Specification references](#specification-references)

## The boundary

```text
VHDL (simulation time)                           Python (no notion of simulation time)
------------------------------------             -----------------------------------------------
<interface>_monitor                              MonitorBackend (one per monitor, own session)
  sample the pins at the right edges               PHY decoder -> octet words (+ PHY events)
  metavalue -> sample word bits                    FrameAssembler -> PhyFrame
  record a sample when something changes           FrameDecoder -> EthernetFrame
  flush a batch: full, end of frame, idle   ---->    |-> scoreboard, statistics, captures
  log the reports it returns                <----    |-> user subscribers
<interface>_protocol_checker                     protocol checker backend (own session)
  same sampling as a monitor                ---->    ProtocolChecker -> reports
<interface>_source                               SourceBackend (one per source, own session)
  receive a com message                     ---->    build preamble, SFD, padding, FCS, errors
  drive one symbol or column per edge       <----    symbols as an integer_array_t
```

Python code runs only when a VHDL process calls it, and returns before simulation time advances. It
never reads or drives a signal, never waits for an edge and never schedules anything. VHDL never
interprets a frame. Every Ethernet decision (where a frame starts, whether its FCS is right, whether a
gap is too short) is made once, in Python, on the samples VHDL recorded with their exact simulation
times.

Consequences:

- **Sample once, fan out in Python.** Statistics, captures, the scoreboard and user callbacks all
  subscribe to the same frames. Adding a consumer never adds a sampler.
- **The Python core is simulator independent.** `awesome_vunit_vcs.ethernet` is plain Python, tested
  with pytest without a simulator, and usable outside VUnit.
- **A new interface is a thin frontend.** Its VHDL defines the pin timing and a sample word, and its
  Python decoder turns sample words into the common octet stream.
- **Tests stay in VHDL.** A testbench uses VHDL procedures only; Python-specific extras are additive.

## Anatomy of a component

| Layer | Role |
|---|---|
| `ethernet_pkg` | The interface independent Ethernet VCIs, `com` message types and the procedures a testbench calls. |
| `<interface>_pkg` | Handle types, constructors with the interface options, accessors, and overloads of the Ethernet procedures. |
| `<interface>_source`, `_monitor`, `_protocol_checker` | Entities with the handle as their only generic. They own the pin timing; a monitor instantiates a protocol checker when its handle has one. |
| `ethernet_vc_pkg` | The PHY-independent part of every entity: message handling, end-of-frame flushes, `wait_until_idle` replies, final checks, and the one-symbol-per-cycle sampling and driving shared by GMII and MII. |
| `vc_python_pkg` | The only VHDL file that calls the Python bridge: sessions, backend creation, sample batches and report logging. |
| `ethernet.vunit_backend` | The Python objects the entities create. |
| `ethernet` core | Frames, PHY decoders and encoders, checker, statistics, PCAPNG writer and Scapy adapter. |

The handles follow VUnit's own verification components (`axi_stream_pkg`, `vc_pkg`); the rules are in
[the contributing conventions](https://awesome-vunit-vcs.readthedocs.io/en/latest/contributing/conventions.html).

## Sessions and identity

Each component creates a Python session with its own identity, `new_vc_session(get_id(vc))`, and a
backend object named `vc` inside it. Two components therefore never share Python state, and a Python
error is reported on the logger of the component that caused it. `new_vc_session` fails when a second
session is created for the same id.

## How a component finds its Python backend

It never uses a path. `create_backend` imports, for example,
`awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend` in the session of the component. The bridge
requires the embedded interpreter to use the environment that started VUnit (`sys.prefix` must match
the interpreter of the run script), so the import resolves to wherever pip installed the package, as a
wheel or editable. `examples/external_project` and `tests/vhdl/run.py` prove this on GHDL and NVC in CI.

The VHDL side is found the same way: `vu.add_package("awesome-vunit-vcs")` locates the installed
package and compiles every `vhdl/**/*.vhd` file into the library `awesome_vunit_vcs`.

## Sample batches

A monitor sends what it sampled as one `integer_array_t` of 32-bit signed integers,
`[word_0, delta_0, word_1, delta_1, ...]`, with `vc.push(samples, base_time, delta_unit)`. The bridge hands the array to Python as a NumPy array.

- **word** is the sample word of the interface. For GMII: bits 0-7 data, bit 8 dv, bit 9 er, bit 10
  metavalue on data while dv, bit 11 metavalue on dv or er. XGMII records one word per lane with the
  octet, the control bit and metavalue bits.
- **delta** is the time since the previous sample in units of `delta_unit` (1 ps by default).
  Femtosecond deltas in 32 bits would span only 2.1 µs, less than one 10 Mbit/s MII symbol.
- **The base time** travels as a typed time argument; the shared time helper hides the split of a
  VHDL time into 32-bit integers.
- **Idle is run-length compressed.** A sample is recorded when data is valid, the word changes, or
  error or metavalue bits are set. A long idle period costs one sample, and gaps keep their timing.
- **Several words may share one time** (delta 0): a multi-lane interface records one word per lane.
- **Metavalues are never hidden.** `U`, `X`, `Z`, `W` and `-` set dedicated bits, reported as
  `ETH_METAVALUE`, instead of being mapped silently to `0`.

A batch is flushed when it is full (`batch_length`, 4096 samples), at the end of every frame
(`flush_at_frame_end`), before replying to `wait_until_idle` and at `test_runner_cleanup`.

Each PHY decoder in `awesome_vunit_vcs.ethernet.phy` turns sample words into *octet words*, one per
received octet with the time of its first symbol, carrying data, valid, error, metavalue and alignment
bits. Decoders that signal with control characters (XGMII) also publish `PhyEvent` objects
(`ETH_CONTROL`, `ETH_TERMINATION`, `ETH_LINK_FAULT`) for violations octet words cannot express.

- **MII** pairs nibbles into octets aligned on the SFD nibbles `0x5 0xD`, low nibble first. Unpaired
  nibbles carry over between batches. A trailing unpaired nibble is an alignment error.
- **XGMII** samples one column per clock edge and records one word per lane, skipping an Idle column
  equal to the previous one. Start becomes the first preamble octet, Error inside a frame an octet with
  the error flag, and Terminate ends the frame. Octet `k` of a column is timed `k` octet periods after
  the column.

## Reports

Violations and messages travel back to VHDL as one string per fetch: records separated by ASCII RS
(0x1E), with the severity code and the message separated by US (0x1F). A backend call returns the
number of reports waiting, so VHDL only fetches them when there are some. Errors become check failures
on the checker of the component; other levels go to its logger. Backends catch their own exceptions and
turn them into failure reports with a one-line summary.

## What belongs where, per interface

| Interface | Status | VHDL | Python |
|---|---|---|---|
| GMII | Done | Rising edge sampling and driving, metavalue detection, idle compression, batching | Octet stream, frames, checks, statistics, PCAPNG, scoreboard, Scapy |
| XGMII family | Done | One word per lane, rising or both edges, 4 or 8 lanes | Control characters, Start alignment, link fault ordered sets, deficit idle on transmit |
| MII | Done | One nibble per rising edge, shared with GMII | Nibble pairing on the SFD, alignment errors |
| RGMII | Planned | Both-edge sampling and driving; CTL is DV on the rising edge and DV xor ER on the falling edge | The GMII octet stream |
| RMII | Planned | Dibit sampling on the 50 MHz reference clock | Dibit assembly, 10x replication at 10 Mbit/s, CRS_DV toggling |
| AXI-Stream MAC client | Planned | tvalid/tready, tkeep, tlast, tuser | Frames without preamble or SFD, optional FCS |

## Active sources and responders

A source works the other way round: Python decides what is transmitted, VHDL decides when pins change.
`push_ethernet_frame` sends a `com` message to the source entity, which asks its backend for the
symbols of the frame (preamble, SFD, padding, FCS, errors and the following gap) as one
`integer_array_t` and drives one symbol or column per clock edge.

The XGMII source starts frames on lane 0 and rounds gaps to whole columns. With `deficit_idle` a gap is
rounded down while the accumulated deficit stays within `lanes - 1` octets, otherwise up, so the average
gap equals the requested one. After columns that do not end in Idle it drives Idle when nothing else is
queued, so `wait_until_idle` returns only after monitors sampled the last column.

Components that must answer a bus, such as a memory model responding to an opcode, cannot batch in
advance. They may call their backend once per transfer unit (octet or word), never once per clock cycle.

## Design decisions

Investigated on 2026-09-14 against VUnit `feature/package-setup-hooks` (1ecac00),
vunit-python-bridge (28ff9b4), vunit-json-for-vhdl 0.1.0 and cocotbext-eth 0.1.28.

### A VUnit package, found through the installed Python package

The package ships `vunit_pkg.toml` next to its Python modules, with no entry points or registration
code. `VUnit.add_package(name)` normalizes the name (`-` and `.` become `_`), locates the package with
`importlib.util.find_spec` (without importing it; namespace packages are rejected), validates the
`[package]` table (`requires-vunit`, `requires-vhdl`, `library`, `sources` with `include` globs, `setup`),
checks the VUnit version and VHDL standard, refuses a pattern that matches no file, adds the sources and
calls the `setup` function with a `PackageContext`. vunit-json-for-vhdl does exactly the same.

The package needs vunit-python-bridge, but `vunit_pkg.toml` cannot declare a dependency on another VUnit
package, and `PackageContext` cannot add one without private VUnit state. A run script therefore adds
both packages, in either order.

### Timing in VHDL, not cocotb's simulator objects

cocotb's Ethernet models run as coroutines scheduled by cocotb through VPI/VHPI/FLI callbacks, with
`Signal` handles and `RisingEdge`/`Timer` triggers. The VUnit Python bridge is the opposite: a VHDL
process calls Python synchronously and gets a value back, with no scheduler and no way to suspend Python
until an edge. Running cocotb's classes through the bridge would need a second scheduler inside a
function call, and pin timing would move to the language that cannot see the simulation.

### cocotbext-eth is not a dependency

Its frame classes (`GmiiFrame`, `XgmiiFrame`, `EthMacFrame`) live in modules that `import cocotb` at
module level, the package `__init__` imports all of them, and the distribution requires
`cocotb>=1.6.0`. The framing needed here is small (`zlib.crc32`, preamble, SFD, padding, limits). The
`reference` extra installs cocotbext-eth, and `tests/python/test_references.py` compares against it.

### Batched samples in flat integer arrays

The alternatives were one bridge call per clock cycle, one call per frame, and structured records. One
call per cycle costs 30 to 60 times as much as batching (see [Performance](#performance)); batches and
whole frames cost the same, and bounded batches keep memory in check for jumbo frames.

### One VHDL file talks to the bridge

Only `vhdl/common/vc_python_pkg.vhd` names subprograms of vunit-python-bridge. Components call
`new_vc_session`, `create_backend`, `backend_call` and its typed variants, `log_reports` and the sample
batch subprograms, with typed argument lists rather than Python source text, so a change in the bridge
API is absorbed in one file.

### Unresolved port types

Ports are `std_ulogic`: unresolved types catch multiple drivers at elaboration. VUnit's own VCs use
`std_logic`, which connects without conversion.

### Seeded Python generators, not Hypothesis, for traffic sequences

Sequences inside a simulation use seeded `random` generators that draw from the same `LIMITS` as a
Hypothesis strategy. Hypothesis's public API draws examples only inside `@given` tests, and
`strategy.example()` is documented as unsuitable outside interactive exploration. The in-simulation
property runner therefore drives `@given` from a thread instead.

### Protocol checks in their own entity

Like VUnit's `axi_stream_protocol_checker`, protocol checks run in a separate entity that a monitor
instantiates when its handle has one. The line is sampled twice when both are used (see
[Performance](#performance)).

## Performance

### Bridge benchmark

A GMII source sends 200 frames of 1500 octets (about 302,600 valid samples), observed by a monitor in
each configuration. Measured on 2026-09-14 with GHDL 7.0.0-dev (mcode), NVC 1.23-devel, CPython 3.12,
on a Linux workstation. The ratios matter more than the absolute numbers.

| Configuration | GHDL (s) | NVC (s) | Monitor cost, GHDL | Monitor cost, NVC |
|---|---|---|---|---|
| No monitor | 1.84 | 0.81 | | |
| Batched, 4096 samples per call | 2.32 | 0.96 | +0.48 (1.6 µs per sample) | +0.15 (0.5 µs per sample) |
| Whole frame, one call per frame | 2.33 | 0.97 | +0.49 | +0.16 |
| One call per clock cycle | 16.55 | 10.32 | +14.7 (48 µs per call) | +9.5 (31 µs per call) |

Adding a protocol checker to a monitor for the same traffic took 0.98 s → 1.18 s on NVC and
2.33 s → 2.78 s on GHDL.

Property getters cost about 20 µs per call on NVC: reading 50 fields per example added 0.2 s to 200
examples that took 0.6 s without reads. A getter cache was not worth the complexity.

Rerun the bridge benchmark one configuration at a time:

```bash
VUNIT_SIMULATOR=ghdl python benchmarks/run.py -p 1 -v | grep BENCHMARK
VUNIT_SIMULATOR=nvc python benchmarks/run.py -p 1 -v | grep BENCHMARK
```

## Known limitations

### All Ethernet components

- The scoreboard matches first in, first out only.
- The final check of a monitor runs at `test_runner_cleanup` in zero simulation time; a frame still on
  the wire is reported as `ETH_FRAME_STATE`, not waited for.
- Packet and sequence functions receive VHDL values as arguments, but run with testbench trust in the
  session of the VC.
- `reset(net, monitor)` cancels pending pops; a non-blocking pop pending at a reset must not be awaited.
- Utilization, and for XGMII the octet period used for gaps, come from `link_rate_mbps`, not the clock.
- Questa/ModelSim, Riviera-PRO and Active-HDL are supported by the bridge but untested here.

### MII

- `CRS` and `COL` (half duplex) are neither monitored nor driven.
- A leading unpaired preamble nibble is dropped, so 15 preamble nibbles count as 7 octets.
- The source cannot transmit an odd number of nibbles.
- `RX_ER` without `RX_DV` is reported like any error outside a frame.

### XGMII family

- The source never starts a frame on lane 4 and has no lane-4 deficit alignment.
- The IEEE 802.3 link fault state machine, with its column counters, is not modeled.
- Low power idle (0x06) is accepted like Idle; LPI sequencing is not checked.
- Signal ordered sets (0x5C) are reported as unknown control characters.
- With `deficit_idle`, a single gap may be up to `lanes - 1` octets shorter than requested.

### Frames without a PHY

The Python core expects a preamble and SFD; frontends without a PHY layer, such as the planned
AXI-Stream MAC client, need a switch for frames starting at the destination address.

### Property-based testing

- Saved failures and pins apply to strategies; a stateful property replays through its seed.
- A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.
- Hypothesis's example database is disabled by `@seed`, so the runner saves failures itself.

## Specification references

- **MII:** IEEE 802.3 Clause 22 (nibble order, 2.5/25 MHz clocks); the trailing half octet as alignment
  error follows 4.2.4.2.1.
- **XGMII:** control characters from IEEE 802.3 Table 46-3 and Table 46-5 (Idle 0x07, Start 0xFB,
  Terminate 0xFD, Error 0xFE, Sequence 0x9C; local fault `00 00 01`, remote fault `00 00 02`), as
  reproduced in Xilinx XAPP687 Table 2 and the UNH-IOL Clause 49 PCS test suite. The 5-octet minimum
  receive gap is IEEE 802.3 interpretation 1-11/09 of 4.4.2; deficit idle follows 46.3.1.4.
- **200GMII/400GMII:** IEEE 802.3bs 119.2.3.3 to 119.2.3.8 use the control characters and ordered sets
  of CGMII (Table 82-1, 82.2.3.6 to 82.2.3.9). Checked against draft P802.3bs/D3.1.
- cocotbext-eth's `XgmiiCtrl` uses the same control codes.
