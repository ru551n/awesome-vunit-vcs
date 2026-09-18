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
  - [The flash responder](#the-flash-responder)
  - [The I2C family](#the-i2c-family)
  - [The AXI4 family](#the-axi4-family)
  - [The AXI4 read and write slaves](#the-axi4-read-and-write-slaves)
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
| RGMII | Done | Both clock edges combined into GMII octets (1G) or MII nibbles (10/100M) before the shared symbol interface, and split again on transmit; centered or edge aligned data | The GMII or MII stream of the rate |
| RMII | Done | Dibits on the 50 MHz reference clock, every 10th cycle at 10 Mbit/s; frames end after two samples without CRS_DV | Dibit grouping on the SFD, data during CRS_DV toggling, 00 dibits before the preamble, alignment errors |
| AXI-Stream MAC client | Done | One word per tkeep octet on every clock with tvalid high or a bus change; the source holds each beat until tready; the sink drives tready | Frames without preamble or SFD, optional FCS, the tkeep, stability and tvalid rules |

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

The AXI-Stream MAC client source holds each beat until `tready` accepts it. A reset keeps `tvalid` low
for one clock edge, so monitors see the abandoned frame end before the next one starts.

### The flash responder

The flash family is the first responder. `flash` owns the pins, the output delays, the protocol checker
it may instantiate and the simulation time; `awesome_vunit_vcs.flash` decides what every byte means.
The QSPI master and the protocol checker are VHDL only and make no bridge calls, so they cost nothing
per clock cycle beyond their own processes.

Every `flash` creates its session with `new_vc_session(get_id(flash), get_logger(flash))`, so a second
flash with the same id is a failure on the logger of that flash, and one `FlashBackend` as the object
`vc` in it:

```vhdl
create_backend(
  session, "awesome_vunit_vcs.flash.vunit_backend", "FlashBackend",
  arg_text(full_name(get_id(flash))) & kwarg("size_bytes", ...) & kwarg("addr_modes", 0) &
  kwarg("timing_enabled", true) & kwarg_time("t_pp", ...) & ... & kwarg_time("t_res2", ...)
);
```

The backend decodes the name with `decode_text` and each busy time (`t_pp`, `t_se`, `t_be32`, `t_be64`,
`t_ce`, `t_w`, `t_rst`, `t_res1`, `t_res2`) with `decode_time_fs`, builds a `FlashConfig` and delegates
to a `FlashDevice`. An invalid configuration is a failure report, and a default device keeps the calls
that follow harmless.

On the wire the flash makes three calls, all with typed arguments:

| When | Call | Returns |
|---|---|---|
| CS falls | `backend_call_integer(session, "cs_assert", arg_time(now))` | The directive for the first byte |
| After every byte | `backend_call_integer(session, "xfer", arg(byte_in))`, with `& arg_time(now)` when the previous directive was volatile | The directive for the next byte |
| CS rises | `backend_call_integer_array(session, "cs_deassert", arg(bits) & arg_time(now))` | The busy time and the number of waiting reports |

`byte_in` is -1 when the flash clocked a byte out. The procedures of `flash_pkg` call the other methods
through the flash's `com` messages: `preload` and `check_content` with `arg(data) & arg(address)`,
`load_image` with `arg_text(file) & arg_text(format) & arg(base)`, `set_timing` with
`arg_text(name) & arg_time(duration)`, `get_stat` with `arg_text(name) & arg_time(now)`, and
`set_timing_enable`, `set_protection` and `reset` with booleans. Content-sized calls cost one bridge call
whatever the size: `flash_preload_fill` sends only the length, Python opens image files itself, and
`flash_check_content` compares in Python.

The device state machine follows three rules of real parts: nothing executes until CS rises, so a CS
edge inside a data byte aborts a program or status write; refusals are silent and only counted; and WIP
is a deadline, `now < deadline`, evaluated whenever it is read. The opcode table is data in
`awesome_vunit_vcs.flash.commands`, resolved against the configuration.

`cs_assert` and `xfer` return one packed directive:

| Field | Bits | Values |
|---|---|---|
| `action` | 1..0 | 0 receive, 1 transmit, 2 ignore the rest of the transaction |
| `lanes` | 4..2 | 1, 2 or 4 |
| `pre_dummy_cycles` | 10..5 | SCK cycles with the I/Os released before the action |
| `byte_out` | 18..11 | The byte to transmit |
| `flags` | 20..19 | Bit 0, volatile: the next `xfer` passes the simulation time, because the byte depends on it |
| `n_bytes` | 29..21 | Always 1 |

`flash_pkg` has the same table written by hand and compares `flash_layout_version` with
`LAYOUT_VERSION` from the backend at time 0; a difference is a failure on the logger of the flash.

### The I2C family

I2C is the family where the split is at its sharpest: the four entities in `vhdl/i2c` know how to
drive a line open drain and when to sample it, and nothing else. `awesome_vunit_vcs.i2c` decides what
every edge means.

```text
VHDL (vhdl/i2c)                                  Python (awesome_vunit_vcs.i2c)
------------------------------------             -----------------------------------------------
i2c_monitor, i2c_protocol_checker                I2cMonitorBackend, I2cProtocolCheckerBackend
  record a sample at every SCL/SDA change  ---->   BusDecoder: START, STOP, bits, metavalues
  flush at a potential STOP and messages           TransferAssembler -> I2cTransfer, statistics
  a sample of its own after t_stuck                I2cProtocolChecker: timing and bit checks
i2c_master                                       I2cMasterBackend
  receive a com message                    ---->   compile_transfer / compile_ops -> operations
  clock the operations bit by bit          <----   one word per START, byte, bit group, STOP
  results: ACK/NACK, bytes, lost, timeout  ---->   Program.result -> status, data, reports
i2c_target                                       I2cTargetBackend
  START / 8 bits in / ACK bit sampled      ---->   I2cTarget: address, 10-bit, general call,
  drive ACK, stretch, shift a byte out     <----     NACK injection, PEC, stretch; device model
```

Lines are `std_logic` ports driven `'0'` or `'Z'`; the testbench pulls them up with `'H'` and every
component reads them with `to_x01`. This is the one family whose ports are resolved, because several
components drive the same wire.

**Samples.** The monitor and the protocol checker record the word `scl | sda << 1 | meta_scl << 2 |
meta_sda << 3` on every change of either line, event driven rather than per clock (I2C has no clock
the testbench owns). They flush when SDA rises while SCL is high, which is where a STOP ends a
transaction, and before handling a message. A line stuck low has no edges, so the protocol checker
wakes up after `t_stuck` without a change and records the unchanged word; Python then sees the time
and reports `I2C_STUCK_LOW` once per low period. When SCL and SDA change in the same sample, the
decoder puts the SDA change in the low phase of SCL, so a simultaneous change is never a START or STOP.

**The master** asks its backend for an operation list, one call per transfer, and returns one result
per operation in a second call. An operation word is `value | kind << 8 | flag << 11 | bits << 12`
(`kind` START, write, read, STOP or bit group; `flag` is "ACK this read" or "end with the STOP on a
NACK"). The results are 0/1 for the acknowledge bit of a write, the byte of a read, -1 for an
operation not executed, -2 for a lost arbitration and -3 for SCL held low longer than the stretch
timeout. The timing comes from `master_timing` once, at time 0. Clock synchronization is the
`wait until scl = '0' for t_high` of the high phase; arbitration is a 1 written that reads back as 0.
A small process follows START and STOP so a START waits for a free bus and tBUF.

**The target** calls its backend at a START, after the 8th bit of a byte it receives, after the
acknowledge bit of a byte it transmitted, and at a STOP. Each call returns `[action, ack, byte_out,
stretch_ps, num_reports]` as an `integer_array_t`, so no packed layout needs a version handshake. The
main process, which serves the messages of the testbench, waits one delta cycle after receiving a
message, so a STOP in the same time step reaches the model before a memory check that follows it.

### The AXI4 family

The AXI4 monitor and protocol checker are passive, so they follow the sample batch path of the Ethernet
monitors rather than the responder path above; they sit here next to I2C because the split is the same:
the VHDL knows when to sample and nothing else.

```text
VHDL (vhdl/axi4)                                 Python (awesome_vunit_vcs.axi4)
------------------------------------             -----------------------------------------------
axi4_monitor, axi4_protocol_checker              Axi4MonitorBackend, Axi4ProtocolCheckerBackend
  at every rising ACLK edge:                       SampleDecoder: records -> Axi4Sample, control
    control record: ARESETn or period changed      TransactionTracker: per-ID transactions,
    per channel with VALID 1, a VALID change,        W before AW, beat addresses and byte lanes
      or a metavalue on VALID/READY:        ---->  Axi4Monitor -> Axi4Transaction, scoreboards
      header word + payload words                  Axi4PerformanceMonitor: counts, latencies
  flush: batch full, messages, end of a            Axi4ProtocolChecker: channel rules, address
    transaction with subscribers/pops,               rules, WLAST/RLAST/WSTRB, timeouts
    tick every timeout_cycles (checker)
  log the reports                           <----  reports
```

**Records.** A record is a header word (channel, VALID, READY, metavalue bits for VALID, READY and the
payload, ARESETn and its metavalue bit) followed by the fields of the channel packed 32 bits to a word,
first field in the least significant bits. A wide payload is several words with the same time (delta 0),
as `vunit_bridge.py` documents for multi-lane samples: a 32-bit W beat is 3 words (header, then data,
WSTRB, WLAST, WUSER and the lane metavalue mask in 41 bits), a 1024-bit one 42. The data channels carry
one metavalue bit per byte lane, so Python can tell a metavalue on a lane that carries data from one on
an unused lane, which the protocol allows; the data bits themselves are sent with metavalues as 0.
Control records carry a change of ARESETn, a change of the clock period (measured by VHDL between rising
edges, one payload word in ps), or a tick. Idle cycles, with VALID 0 on every channel, record nothing:
their time is implied by the next record. A cycle with VALID falling is recorded, which is what
`AXI4_VALID_DROP` needs; a cycle with VALID high and READY low is recorded, which is what
`AXI4_STABLE`, `AXI4_TIMEOUT` and the backpressure statistics need.

**Batches.** The monitor flushes when 4096 words are waiting, before it handles a message, and at a B
handshake or a last R beat only while it has subscribers or pending pops, so publishing and pops are
timely without costing a bridge call per transaction otherwise. VHDL may split a record across two
batches; the decoder keeps the unfinished words. The protocol checker also records a tick and flushes
every `timeout_cycles` clock cycles: a transaction that never completes produces no records, so without
the tick it would only be reported at `test_runner_cleanup`, which a watchdog may never reach.

**Transactions.** `TransactionTracker` keeps writes waiting for data in AW order, W beats that came
before their AW in a buffer, writes waiting for B per ID, and reads per ID. W beats belong to the oldest
write without all its data (AXI4 has no WID); B and R belong to the oldest transaction of their ID. The
burst length, not WLAST or RLAST, ends a transaction, so a wrong LAST is one violation and does not
desynchronize everything after it. The tracker is shared by the monitor and the checker, which each run
their own copy on their own records.

### The AXI4 read and write slaves

The slaves are responders, but unlike the flash they know a whole burst at its address handshake: the
address, length, size and type fix which bytes every beat moves. So the bridge is called per burst, not
per beat, and the per-beat work in VHDL is copying lanes.

```text
VHDL (vhdl/axi4)                                 Python (awesome_vunit_vcs.axi4)
------------------------------------             -----------------------------------------------
axi4_memory_t: a session of its own              Axi4MemoryBackend (vc of the memory session)
  backdoor procedures ------------------------->   MemoryModel: data, permissions, expected
                                                     values (4 SparseMemory stores), buffers
axi4_read_slave (attached as a port)               Axi4Slave per port: burst lanes, permissions,
  AR handshake: read_burst ------------------->      expected data, responses, statistics
    <---- [reports, index, RRESP + lanes per beat]
  drives R beats, stalls, latency, FIFO
axi4_write_slave (attached as a port)
  AW handshake: accept_write ----------------->    checks, statistics, burst queued per port
  W beats collected in an integer_array_t
  before BVALID: write_burst(lanes) ---------->    permissions, expected data, commit
    <---- [reports, BRESP]
```

**One memory, many slaves.** Python sessions are namespaces of one interpreter, but a backend can only
be reached through the session of its VC, and there is no registry of backends (no global state). So the
memory has the session and the backend, and a slave attaches to it as a port: `attach` returns an index
that every later call passes. Each port has its own report queue, fetched with `take_reports(port)`, so
a slave's failures go to its own checker and the testbench's backdoor failures to the memory's. The
backend is created on first use rather than in `new_axi4_memory`, because Python must not run while the
design elaborates (GHDL cannot call a foreign function from a constant's initial value).

**What stays in VHDL.** The handshakes, the address and write response FIFOs, the stall draws (with
`ieee.math_real.uniform`, seeded by the handle's `seed`, one stream per process), the latency draws,
WLAST checking and VUnit's well behaved check, which needs every cycle's VALID and READY. None of them
needs Python, and a per-cycle random draw in Python would cost a bridge call per cycle.

**Order of checks.** A read burst is checked and read at its AR handshake, so its data is the memory at
that time. A write burst is accepted (counted, checked for 4 KB, burst type, width) at its AW handshake
and checked and written in one call right before BVALID, as VUnit writes right before the response.

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

### Flash content in sparse Python storage, not VUnit's memory model

VUnit's `memory_t` is dense: every byte of the address space is allocated, with per-byte permissions
and expectations. The flash content lives in Python as a sparse array with NOR semantics (programming
only clears bits, erasing sets `0xFF`) and region protection, so a 16 MiB part filled with a pattern
costs a few objects. The sparse store itself (`common/sparse_memory.py`: materialized pages plus
constant-value runs, O(1) fills) was extracted from `FlashArray` when the AXI4 slaves needed a RAM;
`FlashArray` keeps program, erase and the written regions as a layer on top. A `memory_t` view would duplicate that state and would have to follow every
program and erase. The preload, read-back and check procedures of the flash are its memory access API.

### One bridge call per byte for a responder

A monitor batches because nothing it drives depends on what it samples. A responder cannot: after an
opcode the model decides whether an address, dummy cycles, a read or nothing follows, and after an
address the next byte out is the content at that address. The flash calls its backend once per byte on
the bus and once per CS edge, never once per clock cycle, and moves bulk content through calls whose
cost does not grow with the size.

### A packed 30-bit directive and a layout version handshake

The bridge returns one value per call, and a directive is needed for every byte. Packing the fields
into one integer keeps it one call per byte instead of one per field. The layout stops at 30 bits
because a VHDL `integer` is signed 32-bit. The table is written twice, in VHDL and in Python, so the
flash checks `LAYOUT_VERSION` at time 0 instead of misreading bytes when the two halves of the package
come from different versions.

### Integer femtoseconds

Every time in the flash model is an integer number of femtoseconds, the resolution of the simulators.
Floating-point seconds would make a busy deadline and the time VHDL passes disagree by rounding, and a
WIP read exactly at the deadline would depend on it. Times cross the bridge with `arg_time`, which
handles times beyond the range of one 32-bit integer.

### Reports instead of exceptions

A backend method never raises into the bridge: an exception would stop the simulation with a Python
traceback and no VUnit log entry. `FlashBackend` turns a `ContentMismatch` into an error report, logged
as a check failure on the checker of the flash, and any other exception into a failure report on its
logger, prefixed with the name of the flash. Calls return the number of waiting reports, so VHDL
fetches them only when there are some. Standalone, `FlashDevice` raises `FlashValueError` and
`ContentMismatch` like any Python API.

### No protocol checker by default

Pin timing depends on the part a design is built for, and a DUT flash controller often fails the
datasheet minimums of a generic default in ways a test does not care about. `new_flash` and
`new_qspi_master` therefore default to `null_qspi_protocol_checker`, and a test opts in with
`protocol_checker => new_qspi_protocol_checker(...)` and the times of its part, like a monitor's
protocol checker in the Ethernet family. The metavalue checks of the flash and the master stay on,
because they are never a property of a part.

### Protocol checker ids inherited from their parent

A protocol checker passed to `new_flash` or `new_qspi_master` without an explicit id gets the id
`<parent id>:protocol_checker`, and its logger, actor and checker follow it unless they were passed.
Log messages therefore name the flash they belong to. A checker constructed without an id takes its
default id lazily, the first time it is needed, so a handle that is given to a parent uses up no
`awesome_vunit_vcs:qspi_protocol_checker:<n>` number and leaves no actor behind.

### AXI-Stream rules in the Ethernet protocol checker

VUnit's `axi_stream_protocol_checker` checks the full AMBA AXI4-Stream protocol (22 rules, including
`tid`, `tdest` and `tstrb`) with one checker per rule. The AXI-Stream MAC client protocol checker does
not instantiate it: those rules could not be enabled, counted or reset through `set_check_enabled`,
`get_check_count` and `reset`, and a stability violation would be reported twice. The three rules a MAC
client relies on (`tkeep` contiguous and partial only on the last beat, the bus stable while `tvalid`
waits for `tready`, `tvalid` held until the handshake) run in the Python decoder next to the frame
checks, so each violation is reported once on one checker. A design that needs full AXI4-Stream
coverage instantiates VUnit's checker on the same bus as well.

A monitor records every clock with `tvalid` high, not only handshakes, so the decoder sees stalls.
Frames start at the destination address: `MonitorConfig.has_preamble` turns off the preamble, SFD and
gap handling of the Python core.

### I2C: semantics in Python, a frontend in VHDL

A controller or target written in VHDL would need its own state machine for START, repeated START,
10-bit addressing, general call, acknowledge polling, PEC and malformed traffic, and a second copy of
the same knowledge in the monitor and the checker. With the semantics in Python the four entities are
edge engines, the transfer decoding and the checks are unit tested against hand-drawn waveforms, and
a user's device model is a Python class. The price is a bridge call per byte in the target, which I2C
can afford: a byte takes at least 9 µs at 1 MHz.

### I2C master: an operation list instead of a call per byte

The master knows the whole transfer before it starts, so Python compiles it once and VHDL runs it.
The only decision that depends on the bus, stopping after a NACK, is a flag on the write operation
rather than a bridge call per byte. `i2c_transfer` exposes the operation list as text (`"S 0xA0 B101
P"`) so tests can send what `compile_transfer` never would.

### I2C checks named and counted in Python

The protocol checker has no VHDL timing code: every limit is a field of `BusLimits`, taken from the
characteristics table of UM10204 per speed mode, and a violation is a report with the check ID,
measured value, limit and time. `I2cCheckId` and `i2c_check_t` list the same checks, which
`tests/python/test_docs.py` enforces. `I2C_SCOREBOARD` belongs to the monitor, and the monitor reports
`I2C_METAVALUE` itself only when it has no protocol checker, so a metavalue is reported once.

### I2C timing: what "0" means

A time of 0 in a constructor means "the value of the speed mode", so tests change only what they
need. A check that should not run is switched off with `set_check_enabled`, not given a limit of 0;
the one exception is `t_hd_dat`, whose specification minimum is 0.

### AXI4: records in VHDL, everything else in Python

The request was a thin VHDL frontend with the difficult logic in Python, and the AXI4 rules are exactly
the kind of logic that is easy to get wrong in VHDL: the address and byte lanes of every beat of FIXED,
INCR and WRAP bursts, narrow and unaligned, per-ID matching with write data that may come first,
exclusive access rules, latency percentiles. In Python each of them is a small function unit tested
against hand-computed values from the formulas of the specification (`tests/python/test_axi4_core.py`),
and the VHDL is two entities that share one recording procedure per channel.

### AXI4: a record per channel with VALID, not a word per cycle

Recording every cycle would make an idle interface as expensive as a busy one; recording only
handshakes would lose stalls, dropped VALIDs and payload changes during a stall. Recording a channel when
VALID is 1 or changed gives the checker everything it needs with the cost proportional to traffic, and
the time of the idle cycles in between is implied. The clock period travels as a control record so that
cycle counts (latencies, utilization, timeouts) need no configuration.

### AXI4: checks that are not in the list

`AXI4_ORDER` (same-ID response ordering) and `AXI4_WDATA_INTERLEAVE` were considered and left out: on
the pins of AXI4 neither can be observed. Responses with the same ID are indistinguishable, so they are
matched to the oldest transaction of their ID by definition, and without WID write data can only be
attributed in AW order. A slave that answers same-ID transactions out of order, or a master that
interleaves write data, shows up as `AXI4_RLAST`, `AXI4_WLAST` or `AXI4_WSTRB` violations or as shadow
memory differences. AXI4-Lite needs no check of its own: its interface has no length, size, burst, lock
or ID signals, which the decoder forces to their AXI4-Lite values, and an EXOKAY response is an
`AXI4_EXCL` violation since a Lite access is never exclusive. Data widths other than 32 and 64 bits are
rejected by `new_axi4_bus` for AXI4-Lite.

### AXI4: the shadow memory takes writes at B and allows overlap

A write takes effect at its B handshake, only for the bytes WSTRB selects, and only when it succeeded
(OKAY for a normal write, EXOKAY for an exclusive one; a failed exclusive write leaves memory unchanged).
A read may return, per byte, the value at its AR handshake or any value written while it was
outstanding, because the specification does not order a read and a write that overlap unless the master
waits for the response. Bytes never written through the interface are not checked, so a memory
initialized behind the bus causes no false reports. The memory keeps 16 values per byte for this.

### AXI4 slaves: VUnit's memory features on the sparse store

The slaves' memory has VUnit's `memory_t` API (buffers, permissions, expected data, words, integer
arrays) so tests port with renames, but its state is four `SparseMemory` stores: content, permission,
expected value and a has-expected flag. A permission for a gigabyte buffer is one run; checking expected
data walks only the pages and runs that differ from the default (`SparseMemory.touched`). Unallocated
bytes take `default_permissions`, so the same memory is a strict VUnit-like memory (`no_access`) or a
plain RAM for image preload at any 64-bit address (`read_and_write`, the default). Failures are messages
worded like VUnit's, one per access and rule rather than per byte, reported as check failures instead of
VUnit's `failure` on the memory logger, so negative tests count them.

### AXI4 slaves: SLVERR for what failed

VUnit's slaves always respond OKAY. These respond SLVERR for a beat or write with a byte the
permissions forbid and for bursts they do not serve (reserved AxBURST, a beat wider than the bus, an
illegal WRAP), so a design under test sees the error it would see from a real slave. The check failure
is reported either way.

### AXI4: the monitor gives its checker its bus

A protocol checker passed to a monitor is instantiated on the monitor's ports, so its widths can only be
the monitor's. `new_axi4_protocol_checker` therefore takes a bus with a default, and the monitor replaces
it with its own, as it replaces the id. A standalone checker gets its bus explicitly.

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

### Flash responder

A QSPI master reads 262,144 bytes (256 KiB) at a 20 ns SCK period, once with the flash answering and
once from a constant bus. The cost per byte is (flash - constant bus) / 262,144. Wall clock time per
test, VUnit `-p 1`, two identical runs.

Measured on 2026-09-14, with the typed bridge arguments of `vc_python_pkg`, with GHDL 7.0.0-dev
(6.0.0.r418.g753dfcf0b, mcode backend), NVC 1.23-devel (1.22.0.r66.gef5084a94, LLVM 21.1.8), CPython 3.12,
VUnit (1ecac00) and vunit-python-bridge (28ff9b4). Both runs gave the same times to 0.1 s, except the NVC
x1 read without a flash, 3.6 s and 3.7 s.

| Read | NVC, constant bus (s) | NVC, flash (s) | NVC, per byte | GHDL, constant bus (s) | GHDL, flash (s) | GHDL, per byte |
|---|---|---|---|---|---|---|
| x1 (`0x03`) | 3.65 | 7.6 | 15 µs | 7.5 | 15.5 | 31 µs |
| x4 (`0xEB`) | 1.0 | 4.6 | 14 µs | 2.1 | 8.5 | 24 µs |

- **The x4 row is closest to the cost of the bridge call itself.** An x1 read also pays for four times
  the VHDL clock edges.
- **Image-sized content goes through the preload and check procedures.** `flash_preload_fill` and
  `flash_load_image` cost one bridge call regardless of size, `flash_preload` and `flash_check_content`
  one array transfer.

### I2C target and monitor

A master reads 16 × 2048 bytes in Fast-mode Plus (32,768 bytes, 295 ms of simulated time), from an
empty bus that reads 0xFF, from an `i2c_target` with the `"device"` model, and from that target with an
`i2c_monitor` on the bus. The cost of the target per byte is (target - empty bus) / 32,768; it
includes the VHDL process of the target following every edge as well as the bridge call. Wall clock
time per test, VUnit `-p 1`, two runs each, which agreed to 0.1 s.

Measured on 2026-09-18 with GHDL 7.0.0-dev (6.0.0.r418.g753dfcf0b, mcode backend), NVC 1.23-devel
(1.22.0.r66.gef5084a94, LLVM 21.1.8) and CPython 3.12 on a Linux workstation.

| Configuration | NVC (s) | GHDL (s) |
|---|---|---|
| Empty bus (master only) | 0.7 | 1.6 |
| Target | 1.45 | 2.85 |
| Target and monitor | 2.2 | 3.9 |
| **Target, per byte** | **23 µs** | **38 µs** |
| **Monitor, per byte** (about 27 samples) | 23 µs | 32 µs |

The per-byte cost of the target is close to the flash responder's (14 to 31 µs), as expected for one
bridge call per byte. It is 3 to 4 times the 9 µs a byte takes on a 1 MHz bus in simulated time, so
the bridge never dominates a test that also simulates a design. Rerun it with:

```bash
VUNIT_SIMULATOR=nvc python benchmarks/run.py -p 1 --output-path ../vunit_out "*i2c*"
```

### AXI4 monitor and protocol checker

`benchmarks/tb_axi4_benchmark.vhd` drives both sides of an AXI4 interface at full throughput: 5000
writes and 5000 reads of 16 beats each (160,000 data beats in 170,000 clock cycles), observed by
nothing, by a monitor, or by a monitor with its protocol checker. A 32-bit data beat is a record of 3
words; a 512-bit one of 22. The cost per beat is (with - without) / 160,000. Wall clock time per test,
VUnit `-p 1`, two runs each, which agreed to 0.1 s.

Measured on 2026-09-18 with GHDL 7.0.0-dev (6.0.0.r418.g753dfcf0b, mcode backend), NVC 1.23-devel
(1.22.0.r66.gef5084a94, LLVM 21.1.8) and CPython 3.12 on a Linux workstation.

| Configuration | NVC (s) | GHDL (s) |
|---|---|---|
| 32-bit, nothing observing | 0.1 | 0.45 |
| 32-bit, monitor | 1.5 | 2.7 |
| 32-bit, monitor and protocol checker | 2.5 | 4.5 |
| 512-bit, nothing observing | 0.1 | 0.9 |
| 512-bit, monitor | 3.1 | 8.35 |
| **Monitor, per 32-bit beat** | **9 µs** | **14 µs** |
| Protocol checker, per 32-bit beat | 6 µs | 11 µs |
| Monitor, per 512-bit beat | 19 µs | 47 µs |

Per recorded word the monitor costs about 3 µs on NVC, several times the 0.5 µs per sample of the GMII
monitor. The bridge is not what dominates: the batches are the same 4096 words, one call each. The
difference is the Python work per record (decoding the fields, burst arithmetic, the tracker and the
statistics) and, on GHDL, the VHDL loop that packs the payload bit by bit, which grows with the data
width. A monitor on a busy 32-bit interface costs about as much as simulating a small design for the
same cycles; the protocol checker, which runs its own tracker on its own records, costs two thirds of
that again. Rerun it with:

```bash
VUNIT_SIMULATOR=nvc python benchmarks/run.py -p 1 --output-path ../vunit_out "*axi4*"
```

### AXI4 read and write slaves

`benchmarks/tb_axi4_slave_benchmark.vhd` writes 20,000 bursts at full throughput and reads each back,
from VUnit's `axi_write_slave` and `axi_read_slave` on a `memory_t` and from `axi4_write_slave` and
`axi4_read_slave` on an `axi4_memory_t`, with bursts of 1 and 16 beats of 32 bits. A write and a read
cost three bridge calls (`accept_write`, `write_burst`, `read_burst`). Wall clock time per test, VUnit
`-p 1`, two runs each, which agreed to 0.2 s.

Measured on 2026-09-18 with GHDL 7.0.0-dev (6.0.0.r418.g753dfcf0b, mcode backend), NVC 1.23-devel
(1.22.0.r66.gef5084a94, LLVM 21.1.8) and CPython 3.12 on a Linux workstation.

| Configuration | NVC (s) | GHDL (s) |
|---|---|---|
| VUnit's slaves, 1 beat | 0.6 | 2.5 |
| These slaves, 1 beat | 4.3 | 8.3 |
| VUnit's slaves, 16 beats | 1.3 | (crashes: GHDL stack, `memory_t` of 1.3 MB) |
| These slaves, 16 beats | 5.75 | 11.8 |
| **Per write and read, 1 beat** | **185 µs** more | **290 µs** more |
| Per additional beat | about 1 µs | about 2 µs |

Of the 185 µs on NVC about 75 µs are Python (`Axi4Slave` and the memory, measured with `timeit` without
a simulator: NumPy calls on arrays of a few elements dominate) and the rest the three bridge calls, about
35 µs each. The cost is per burst: a 16-beat burst costs little more than a single beat, which is the
point of fetching and committing whole bursts. With 2000 bursts NVC took 0.8 s instead of 0.2 s. Rerun it
with:

```bash
VUNIT_SIMULATOR=nvc python benchmarks/run.py -p 1 --output-path ../vunit_out "*slave_benchmark*"
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

### RGMII

- In-band status on RXD between frames (link, speed, duplex) is neither decoded nor generated.
- Carrier extend and false carrier encodings between frames are reported like any error outside a
  frame (`ETH_CARRIER`).
- The data timing is either centered or edge aligned with a fixed quarter-period sampling delay; board
  skew beyond that is not modeled.
- At 10 and 100 Mbit/s only the rising edge nibble is used; a different nibble on the falling edge is
  not reported.

### RMII

- RMII has no TX_ER; the source drives `er` for errored octets, which emulates RX_ER of a PHY.
- False carrier (RXD `10` for the whole carrier event) and the RX_ER-driven data replacement are
  decoded as ordinary dibits, which the checks report as a missing SFD or a bad FCS.
- The monitor samples every 10th reference clock cycle at 10 Mbit/s from its first cycle; a source that
  changes a dibit mid-group is not detected.

### XGMII family

- The source never starts a frame on lane 4 and has no lane-4 deficit alignment.
- The IEEE 802.3 link fault state machine, with its column counters, is not modeled.
- Low power idle (0x06) is accepted like Idle; LPI sequencing is not checked.
- Signal ordered sets (0x5C) are reported as unknown control characters.
- With `deficit_idle`, a single gap may be up to `lanes - 1` octets shorter than requested.

### AXI-Stream MAC client

- `tuser(0)` with `tlast` marks the whole frame errored; the error position inside the frame is not kept.
- After `reset(net, monitor)` a monitor ignores beats until `tlast` or a clock with `tvalid` low, so a
  source is reset before the monitors when a frame is in progress.
- `tid`, `tdest` and `tstrb` are not modeled, and the full AXI4-Stream rule set is not checked.
- The source's `tvalid` stall pattern is fixed when it is created; the sink's backpressure changes at
  run time with `set_ready_pattern`.

### Property-based testing

- Saved failures and pins apply to strategies; a stateful property replays through its seed.
- A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.
- Hypothesis's example database is disabled by `@seed`, so the runner saves failures itself.

### QSPI NOR flash

- One bridge call per byte on the bus, plus one at each CS edge (see
  [Flash responder](#flash-responder)).
- One device per bus: `s2m` is an unresolved record with one driver, and the flash selects itself with
  `m2s.cs_n`. Two devices need two buses.
- The BP bits count 4 KiB (`SEC` set) or 64 KiB units whatever `sector_bytes` and `block_bytes` are, in
  a generic decode rather than the density table of a particular part.
- No hardware write protection: SRP and SRL can be written but have no effect, there is no WP# pin, and
  the one-time-programmable lock bits cannot be written.
- The fixed 4-byte address commands are `0x13`, `0x0C`, `0x12` and `0xDC`; dual and quad 4-byte
  commands such as `0x3C`, `0x6C`, `0xBC`, `0xEC` and `0x34` are unknown opcodes. Addressing is switched
  with `0xB7` and `0xE9` only, not through a status register bit.
- No program or erase suspend: `0x75` and `0x7A` are unknown opcodes.
- The dummy cycle count of each command is fixed by the opcode table; parts that configure it through a
  register are not modeled.
- Only the deep power-down release times `tRES1` and `tRES2` are modeled; entering deep power-down
  takes no time.
- The flash reads `Z` on a lane it samples for data in as a metavalue. A transfer that clocks SCK with
  the controller's I/Os released while the flash expects data in, such as trailing clocks after a
  program to end it in a partial byte, is reported as one metavalue per sampled beat, with or without a
  protocol checker.

### QSPI master

- SPI mode 0 only, with CS setup and hold fixed at half an SCK period.
- The command layer takes addresses as a `natural`, so up to 2 GiB.

### QSPI protocol checker

- Minimum times of the master only: no maximum times are checked, and `s2m` is unused by the current
  rules, so the output timing of the device (tCLQV, tSHQZ) and bus contention are not checked.
- Times in messages are truncated to whole picoseconds.

### I2C master

- It stops driving at the bit where it loses arbitration instead of clocking out the rest of the byte.
- Operation strings are limited by the simulator's stack for the text sent to Python: about 32,000
  characters on GHDL (128 KiB `--max-stack-alloc`).
- `reset` does not abort a transfer in progress; a transfer stuck on SCL ends after `stretch_timeout`.
- High-speed mode (3.4 MHz), Ultra Fast-mode and SMBus timeouts are not modeled.
- A write-read with 10-bit addressing repeats only the first address byte after the repeated START,
  as the specification allows; a target that needs the full address again is not supported.

### I2C target

- One bridge call per byte and per START or STOP (see [I2C target and monitor](#i2c-target-and-monitor)).
- It stretches SCL only before acknowledge bits, not before transmitting a byte.
- With PEC, a read sends a fixed number of data bytes (`pec_read_bytes`) before the PEC, since the
  target cannot know the length of the read; SMBus block reads with a count byte are not modeled.
- A NACK injected into a byte of a write still hands the byte to the device model.
- The general call is answered as a plain write to the model; its second byte (software reset,
  address programming) is not interpreted.

### I2C monitor

- `stretch_time` is an estimate from the bus alone: low periods longer than 1.5 times their median.
- A START or STOP right after the 8 bits of a byte takes the SCL edge of the condition as the
  acknowledge bit; the protocol checker reports the byte as `I2C_ACK_SLOT`.
- It keeps the last 1024 transfers for pops; older ones are dropped.
- `wait_until_idle` does not wait for the end of a transaction.

### I2C protocol checker

- Only minimum times are checked. Rise and fall times, the data valid times tVD;DAT and tVD;ACK, spike
  suppression and bus capacitance need analog edges, which the simulated lines do not have.
- Sample times are rounded down to 1 ps.
- `I2C_F_SCL` leaves out SCL periods across a START or STOP; tSU;STA and tHD;STA cover them.

### AXI4 monitor

- Latencies, utilization and timeouts count cycles as time / the latest measured clock period, so a
  stopped or changing clock distorts them.
- A write takes effect in the shadow memory at its B handshake: a slave that makes write data visible to
  an overlapping read before the read's AR handshake but sends B after the read completes is reported.
- The VHDL `axi4_transaction_t` has no USER signals and limits IDs to 31 bits and addresses to 64 bits.
- It keeps the last 1024 transactions for pops; older ones are dropped.
- `wait_until_idle` does not wait for outstanding transactions to complete.
- Without a protocol checker it reports metavalues on VALID, READY, ARESETn and non-data payload fields,
  but not on data byte lanes, which need the burst of the beat.

### AXI4 protocol checker

- Same-ID ordering and write data interleaving are not observable on AXI4 pins (see the design decision
  above).
- Violations are reported when records reach Python: at the latest after `timeout_cycles` cycles, before
  a message, or when a batch is full. The message has the time of the violation.
- The exclusive access monitor rules beyond the transaction itself (an exclusive write matching an
  earlier exclusive read of the same ID) are not checked.
- Recommendations that are not rules of the specification, such as READY within a fixed number of
  cycles, are only covered by `timeout_cycles`.
- AXI3 (WID, 16-beat INCR limit, locked transfers) and the AXI5/ACE extensions are not modeled.

### AXI4 read and write slaves

- A read burst reads the memory at its AR handshake; a write completing between that handshake and the
  read data is not seen, and permission failures of the whole burst are reported at the handshake.
- A write burst is checked when its response is given, not beat by beat, and a later beat of a FIXED
  burst to the same address wins, so only its value is checked against expected data.
- No exclusive access monitor; AxLOCK, AxCACHE, AxPROT, AxQOS, AxREGION and the USER signals are not
  ports. AXI3 WID is not supported (AXI3 slaves need in-order write data).
- Each slave entity needs its own handle; attaching the same handle twice gives two ports with one actor.
- The read slave has no read data interleaving and returns bursts in order, as VUnit's does.
- Addresses in messages are decimal like VUnit's; `base_address` of a buffer beyond 2 GiB needs
  `wide_base_address`.
- About 185 µs of host time per burst on NVC; see [Performance](#axi4-read-and-write-slaves).

## Specification references

- **I2C:** NXP UM10204, I2C-bus specification and user manual, Rev. 7.0 (2021-10-01): 3.1.4 (START and
  STOP), 3.1.6 (acknowledge), 3.1.7 and 3.1.8 (clock synchronization and arbitration), 3.1.9 (clock
  stretching), 3.1.10 and 3.1.11 (7-bit addressing, general call), 3.1.12 (reserved addresses, Table 4),
  3.1.13 (10-bit addressing), and Table 10 (characteristics of the SDA and SCL bus lines for
  Standard-mode, Fast-mode and Fast-mode Plus), from which `awesome_vunit_vcs.i2c.timing` takes its
  limits.
- **SMBus:** System Management Bus Specification 3.2, 6.4 (Packet Error Checking): CRC-8 with the
  polynomial x^8 + x^2 + x + 1 over every byte of the transaction, address bytes included. The check
  value of CRC-8/SMBUS over "123456789" is 0xF4.
- **AXI4:** AMBA AXI and ACE Protocol Specification, ARM IHI 0022, AXI4 and AXI4-Lite. The chapters
  on single interface requirements (clock and reset, the handshake process, transaction structure: burst
  length, size and type, the transfer address and byte lane formulas, write strobes), transaction
  attributes (AxCACHE), transaction identifiers and ordering, atomic accesses (exclusive access
  restrictions and the EXOKAY response), and AXI4-Lite. `awesome_vunit_vcs.axi4.burst` implements the
  address and byte lane formulas as the specification writes them (Start_Address, Aligned_Address,
  Wrap_Boundary, Lower_Byte_Lane, Upper_Byte_Lane).
- **24Cxx EEPROMs:** page writes that wrap within the page, a self-timed write cycle started by the STOP,
  and acknowledge polling, as in the data sheets of the 24C02/24C04/24C16 families.

- **MII:** IEEE 802.3 Clause 22 (nibble order, 2.5/25 MHz clocks); the trailing half octet as alignment
  error follows 4.2.4.2.1.
- **RGMII:** RGMII Version 2.0 (Hewlett-Packard et al., 2002-04-01): Table 1 (bits 3:0 on the rising
  and 7:4 on the falling edge), 3.4 (TXERR/RXERR as TX_ER/RX_ER xor TX_EN/RX_DV), Table 2 note 4
  (RGMII-ID internal delay), Table 4 and 3.4.1 (optional in-band status), 5.0 (10/100 operation).
- **RMII:** RMII Specification Rev. 1.2 (RMII Consortium, 1998-03-20): 5.1 (50 MHz REF_CLK), 5.2
  (CRS_DV toggling on nibble boundaries after carrier loss), 5.3 and 5.3.1 (RXD `00` before the
  preamble, false carrier `10`), 5.3.2 and 5.5.2 (sampling every 10th cycle at 10 Mb/s), 6.0 (di-bit
  order, D0 first).
- **XGMII:** control characters from IEEE 802.3 Table 46-3 and Table 46-5 (Idle 0x07, Start 0xFB,
  Terminate 0xFD, Error 0xFE, Sequence 0x9C; local fault `00 00 01`, remote fault `00 00 02`), as
  reproduced in Xilinx XAPP687 Table 2 and the UNH-IOL Clause 49 PCS test suite. The 5-octet minimum
  receive gap is IEEE 802.3 interpretation 1-11/09 of 4.4.2; deficit idle follows 46.3.1.4.
- **200GMII/400GMII:** IEEE 802.3bs 119.2.3.3 to 119.2.3.8 use the control characters and ordered sets
  of CGMII (Table 82-1, 82.2.3.6 to 82.2.3.9). Checked against draft P802.3bs/D3.1.
- **Serial NOR flash:** SFDP follows JESD216: the `SFDP` signature, one parameter header for the JEDEC
  Basic Flash Parameter Table and a 9-DWORD basic table whose density, erase types and fast-read fields
  are computed from the configuration and the opcode table. RDSFDP (`0x5A`) always takes 3 address
  bytes, also in 4-byte mode. The opcodes are the common JEDEC set of W25Q-style parts, and the BP
  decode is a generic W25Q-style one.
- cocotbext-eth's `XgmiiCtrl` uses the same control codes.
