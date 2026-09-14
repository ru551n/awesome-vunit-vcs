# Architecture

**VHDL handles simulation timing. Python handles Ethernet verification semantics.**

This document describes the boundary between the two languages, why it is where it is, and the
answers to the questions that shaped the design. Measurements are from 2026-09-14 with GHDL
7.0.0-dev (mcode), NVC 1.23-devel, CPython 3.12, VUnit `feature/package-setup-hooks` (1ecac00) and
vunit-python-bridge (28ff9b4).

## The boundary

```text
 VHDL (simulation time)                           Python (no notion of simulation time)
 ------------------------------------             -----------------------------------------------
 gmii_monitor                                     MonitorBackend (one per monitor, own session)
   sample data/dv/er on the rising edge             PHY decoder -> octet words
   metavalue -> sample word bits                    FrameAssembler -> PhyFrame
   record a sample when dv or the word changes      FrameDecoder -> EthernetFrame
   flush a batch: full, end of frame, idle   ---->    |-> ProtocolChecker   -> reports
   log the reports it returns                <----    |-> PerformanceMonitor
                                                      |-> PcapNgWriter
                                                      |-> scoreboard, user subscribers
 gmii_source                                      SourceBackend (one per source, own session)
   receive a com message                     ---->    build preamble, SFD, padding, FCS, errors
   drive one symbol per rising edge          <----    symbols as an integer_array_t
```

Python code runs only when a VHDL process calls it, and returns before simulation time advances.
It never reads or drives a signal, never waits for an edge and never schedules anything. VHDL never
interprets a frame. Every Ethernet decision (where a frame starts, whether its FCS is right,
whether a gap is too short) is made once, in Python, on the samples VHDL recorded with their exact
simulation times.

Consequences:

* **Sample once, fan out in Python.** The checker, the statistics, captures, the scoreboard and
  user callbacks all subscribe to the same frames. Adding a consumer never adds a sampler.
* **The Python core is simulator independent.** `awesome_vunit_vcs.ethernet` is plain Python,
  tested with pytest without a simulator, and usable outside VUnit.
* **A new interface is a thin frontend.** Its VHDL defines the pin timing and a sample word, its
  Python decoder turns sample words into the common octet stream. Handles, procedures, checks,
  statistics and capture are shared.
* **Tests stay in VHDL.** A testbench uses VHDL procedures only. Python-specific extras, like
  inspecting a received frame with Scapy, are additive.

### Why cocotb's simulator objects are not used

cocotb and cocotbext-eth provide mature Ethernet models (`GmiiSource`, `GmiiSink`, `RgmiiSink`,
...), but they are built on cocotb's execution model: Python coroutines scheduled by cocotb, which
owns the simulator through VPI/VHPI/FLI callbacks, and `Signal` handles, `RisingEdge` and `Timer`
triggers that suspend a coroutine until the simulator reaches an event.

The VUnit Python bridge is the opposite: a VHDL process calls Python synchronously, through a
foreign function interface, and Python returns a value. There is no scheduler, no signal handle and
no trigger on the Python side, and no way to suspend Python until an edge. Running cocotb's
simulator-facing classes through the bridge would need a second scheduler emulating cocotb inside a
function call, and pin timing would move to the language that cannot see the simulation. Keeping
timing in VHDL makes the components simulator independent through VUnit, deterministic, and fast
enough (see the benchmark below).

## Design questions

### 1. What registration mechanism does `add_package()` use?

None beyond the installed Python package. `VUnit.add_package(name)` (in `vunit/builtins.py` of the
VUnit branch with package support):

1. normalizes the name, so `-` and `.` become `_` (`awesome-vunit-vcs` → `awesome_vunit_vcs`),
2. locates the package with `importlib.util.find_spec`, which does not import it, and rejects
   namespace packages,
3. reads `vunit_pkg.toml` from the package directory and validates its `[package]` table: the keys
   `requires-vunit`, `requires-vhdl`, `library`, `sources` (each with an `include` list of glob
   patterns relative to the package directory) and `setup`,
4. checks the VUnit version and the VHDL standard, and refuses a pattern that matches no file,
5. adds the sources to the named library,
6. calls the `setup` function (`module:function`), if any, with a `PackageContext` after the sources
   are added.

There are no entry points. awesome-vunit-vcs ships `src/awesome_vunit_vcs/vunit_pkg.toml` with
library `awesome_vunit_vcs` and the pattern `vhdl/**/*.vhd`, which covers every VC family directory.
The hatchling wheel includes the whole package directory, so the TOML file and the VHDL sources are
installed next to the Python modules. `tests/packaging/check_package.py` builds the wheel, installs
it into a clean environment and checks that VUnit finds it outside the repository.

The package does not use `setup`. It needs vunit-python-bridge, but `vunit_pkg.toml` cannot declare
a dependency on another package, and `PackageContext` offers no way to add one without private
VUnit state. A run script adds both packages, in either order.

### 2. How does `vunit-json-for-vhdl` implement it?

The same way, with no code involved. Its wheel (version 0.1.0) contains
`vunit_json_for_vhdl/vunit_pkg.toml`:

```toml
[package]
requires-vunit = ">=5.0.0.dev9"
requires-vhdl = ">=2008"
library = "json"

[[package.sources]]
include=["hdl/src/*.vhdl"]
```

and its `__init__.py` holds only JSON helper functions for run scripts. There are no entry points
and nothing is registered at import time. awesome-vunit-vcs follows that example.

### 3. What bridge API initializes Python and creates sessions?

The bridge is the `vunit-python-bridge` VUnit package, compiled into the library `python_bridge`,
added with `vu.add_package("vunit-python-bridge")` and used with
`library python_bridge; context python_bridge.python_context;`. Its setup function selects the
foreign language interface for the simulator, and the interpreter is initialized on the first call.
The subprograms used are:

* `new_session(id : id_t) return python_session_t`: a namespace per identity. Two sessions with the
  same identity are the same session, and its errors are logged on `get_logger(id)`.
* `exec(code, session)`, `eval_integer`, `eval_boolean`, `eval_string` and
  `eval_integer_array(expr, session)`.
* `call(name, arg(integer_array_t), arg(integer)..., session => s)` returning `integer`, and
  `call_string`.

Only `vhdl/common/vcs_python_pkg.vhd` names these. Components call `new_vc_session(get_id(vc))`,
`create_backend`, `backend_exec`, `backend_integer`, `backend_string`, `backend_integer_array`,
`log_reports` and the sample batch subprograms, so a change in the bridge API is absorbed in one
file.

### 4. How does an installed VHDL component find its Python backend?

It never uses a path. `create_backend` runs
`from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend` in the session of the
component and creates the object `vc`. The bridge requires the embedded interpreter to use the
environment that started VUnit, so the import resolves to wherever pip installed the package, as a
wheel or editable. `examples/external_project` and `tests/vhdl/run.py` prove it on GHDL and NVC in
CI.

Each component has a session with its own identity, so two monitors never share Python state, and
Python errors are reported on the logger of the component that caused them.

### 5. Which parts of cocotbext-eth could be reused?

Inspected in cocotbext-eth 0.1.28. The frame classes (`GmiiFrame` in `gmii.py`, `XgmiiFrame` in
`xgmii.py`, `EthMacFrame` in `eth_mac.py`) are simulator independent in what they do (preamble,
SFD, padding, FCS), but they live in the modules that define the simulator-facing sources and sinks.
Only `constants.py` (preamble octets, XGMII and BASE-R control codes) and `version.py` are free of
simulator code.

### 6. Do they import the cocotb runtime transitively?

Yes. `gmii.py`, `mii.py`, `rgmii.py`, `xgmii.py`, `eth_mac.py`, `ptp.py` and `reset.py` all
`import cocotb` and import from `cocotb.triggers`, `cocotb.queue` and `cocotb.utils` at module
level. The package `__init__.py` imports all of them, and the distribution requires `cocotb>=1.6.0`
and `cocotbext-axi`. Importing `GmiiFrame` therefore imports cocotb.

Decision: cocotbext-eth is not a dependency. The Ethernet framing needed here is small: the FCS is
`zlib.crc32`, and preamble, SFD, padding and frame limits are a few lines each. A dependency that
brings in a simulator runtime for that would couple the package to cocotb for no gain. cocotbext-eth
is instead an independent reference in the test suite: the `reference` extra installs it, and
`tests/python/test_references.py` compares wire frames and FCS results against `GmiiFrame`. The
tests are skipped when it is not installed. No cocotbext-eth source is copied.

### 7. What is the bridge overhead per cycle versus batched?

`benchmarks/run.py`: a GMII source sends 200 frames of 1500 octets, about 302,600 valid samples,
observed by a monitor in each configuration. Wall clock in seconds, one configuration at a time:

| Configuration | GHDL | NVC | Monitor cost GHDL | Monitor cost NVC |
|---|---:|---:|---:|---:|
| no monitor | 1.84 | 0.81 | | |
| batched, 4096 samples per call | 2.32 | 0.96 | +0.48 (1.6 µs/sample) | +0.15 (0.5 µs/sample) |
| whole frame, one call per frame | 2.33 | 0.97 | +0.49 | +0.16 |
| one call per cycle | 16.55 | 10.32 | +14.7 (48 µs/call) | +9.5 (31 µs/call) |

One call per cycle costs 30 to 60 times as much as batching. Batched and whole-frame transfers cost
the same at this frame size. The default is therefore `batch_length => 4096` with
`flush_at_frame_end => true`: batches stay bounded for jumbo frames and long runs, and every frame
is checked as soon as it ends, so a violation is logged at a simulation time close to the frame.

### 8. What batching representation fits best?

A batch is one `integer_array_t` of 32-bit signed integers, `[word_0, delta_0, word_1, delta_1,
...]`, sent as `vc.push(samples, base_hi, base_lo, delta_unit_fs)`. The bridge hands it to Python
as a NumPy array.

* `word` is the sample word of the interface. For GMII: bits 0-7 data, bit 8 dv, bit 9 er, bit 10
  metavalue on data while dv, bit 11 metavalue on dv or er.
* `delta` is the time since the previous sample in units of `delta_unit` (1 ps by default).
  Femtosecond deltas in 32 bits would span only 2.1 µs, less than one 10 Mbit/s MII symbol.
* The base time is two integers, `hi * 2**30 + lo` femtoseconds, since VHDL integers are 32 bits.
* Idle is run-length compressed: a sample is recorded when dv is asserted, the word changes, or the
  error or metavalue bits are set. A long idle period costs one sample, and inter-frame gaps keep
  their exact timing because every sample keeps its time.
* Several words may share one time (delta 0). That is how a multi-lane interface such as XGMII
  records one word per lane.
* Metavalues (`U`, `X`, `Z`, `W`, `-`) set dedicated bits, which the checker reports as
  `ETH_METAVALUE`, instead of being mapped silently to `0`.

A per-sample dataclass or a structured record per call was rejected: the cost is in the number of
bridge calls and Python objects, and flat integer arrays keep both low. The octet stream is decoded
with NumPy.

Reports travel back as one string: records separated by ASCII RS (0x1E), severity code and message
separated by US (0x1F). Errors become check failures on the checker of the component. Failure,
warning, info and debug messages go to its logger. Backends catch their own exceptions and turn them
into failure reports with a one-line summary, so a user sees a VUnit failure rather than a Python
traceback.

### 9. What belongs in VHDL and what in Python for each interface?

| Interface | VHDL | Python |
|---|---|---|
| GMII monitor (done) | rising edge sampling, metavalue detection, idle compression, batching, flush at end of frame, `wait_until_idle`, final check at `test_runner_cleanup` | octet stream, frame assembly, preamble/SFD/FCS, runt/giant, PHY error offsets, IFG, statistics, PCAPNG, scoreboard, Scapy |
| GMII source (done) | one symbol per rising edge, frames back to back | preamble length, SFD, padding, FCS good/bad/none, error offsets, IFG, Scapy packets |
| XGMII family (in progress) | one word per lane (octet + control bit), rising or both edges, 4 or 8 lanes | control characters (Start, Terminate, Idle, Error, Sequence), Start alignment on lane 0, link fault ordered sets, octet stream |
| MII (planned) | nibble sampling on the rising edge | nibble to octet assembly, low nibble first, alignment errors |
| RGMII (planned) | both edge sampling and driving, CTL = DV on the rising edge and DV xor ER on the falling edge, reconstructed into data/dv/er words | the GMII octet stream, unchanged |
| RMII (planned) | dibit sampling on the 50 MHz reference clock | dibit to octet assembly, 10x symbol replication at 10 Mbit/s, CRS_DV toggling at end of carrier |
| AXI-Stream MAC client (planned) | tvalid/tready handshake, tkeep, tlast, tuser | frames without preamble or SFD, optional FCS |

The Python octet stream (`ethernet/phy/common.py`) is the common representation. Its words carry
data, valid, error, metavalue and alignment bits, and decoders that signal with control characters
publish `PhyEvent`s (`ETH_CONTROL`, `ETH_LINK_FAULT`) next to it.

### 10. What does the public VHDL API look like?

It follows VUnit's own verification components (`uart_pkg`, `axi_stream_pkg`, `vc_pkg`):

* Handles `ethernet_monitor_t` and `ethernet_source_t`: records with private `p_` fields around a
  `std_cfg_t` (id, actor, logger, checker, unexpected message policy).
* Constructors `new_gmii_monitor(...)` and `new_gmii_source(...)`. Ids default to
  `awesome_vunit_vcs:gmii_monitor:<n>` and `awesome_vunit_vcs:gmii_source:<n>`.
* Accessors `get_id`, `get_logger`, `get_checker` and `as_sync`, with `wait_until_idle(net,
  as_sync(vc))` from `sync_pkg`.
* Procedures that send `com` messages: `send_ethernet_frame`, `send_ethernet_packet`,
  `expect_ethernet_frame`, `set_check_enabled`, `get_check_count`, `get_frame_count`,
  `get_statistics`, `log_statistics`, `start_capture` and `stop_capture`.
* Entities `gmii_monitor` and `gmii_source` with the handle as their only generic and the ports
  `clk`, `data`, `dv` and `er`.
* One context for testbenches, `awesome_vunit_vcs.ethernet_context`.

Handles and procedures are shared by every Ethernet interface. The backend object is reachable as
`vc` in `new_session(get_id(vc))` for Python-specific extras.

## Known limitations

* The scoreboard of `expect_ethernet_frame` matches frames in order only.
* The final check of a monitor (unfinished frame, expected frames not received, closing captures)
  runs at `test_runner_cleanup` in zero simulation time. A frame still on the wire then is reported
  as `ETH_FRAME_STATE`, not waited for, so tests call `wait_until_idle` first.
* `send_ethernet_packet` evaluates a Scapy expression string in the session of the source. It is
  testbench code with testbench trust.
* Only GMII has a VHDL frontend so far.
