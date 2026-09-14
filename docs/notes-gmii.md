# GMII implementation notes

Facts for ARCHITECTURE.md from the GMII reference implementation, measured
2026-09-14 with GHDL 7.0.0-dev (mcode), NVC 1.23-devel, CPython 3.12,
VUnit `feature/package-setup-hooks` (1ecac00) and `vunit-python-bridge`
(28ff9b4).

## 3. Python bridge API used to create sessions and call Python

The bridge is the `vunit-python-bridge` VUnit package, compiled into the
library `python_bridge`. It is added with
`vu.add_package("vunit-python-bridge")` (there is no `add_python()`) and
reached with `library python_bridge; context python_bridge.python_context;`.
The subprograms used, verified in its `vhdl/src/python_ffi_pkg_bridge.vhd` and
`python_pkg.vhd`:

- `new_session(id : id_t) return python_session_t`: a namespace per identity.
  Two sessions with the same identity are the same session, and its errors are
  logged on `get_logger(id)`.
- `exec(code, session)`, `eval_integer`, `eval_boolean`, `eval_string`,
  `eval_integer_array(expr, session)`.
- `call(name, arg(integer_array_t), arg(integer)..., session => s)` returning
  `integer`, plus `call_string`.

Only `vhdl/common/vcs_python_pkg.vhd` names these. A VC calls
`new_vc_session(get_id(vc))`, `create_backend`, `backend_exec`,
`backend_integer`, `backend_string`, `backend_integer_array`, `log_reports` and
the sample batch subprograms.

## 4. How an installed VHDL component finds its Python backend

It never uses a path. `create_backend` runs
`from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend` in the
session. The bridge checks that the embedded interpreter uses the environment
that started VUnit (`sys.prefix` must equal the prefix of the run script's
interpreter), so the backend is imported from wherever pip installed the
package, editable or wheel. The external example project and
`tests/vhdl/run.py` prove this on GHDL and NVC.

## 7. Bridge overhead: per cycle vs batched vs whole frame

`benchmarks/run.py`: a GMII source sends 200 frames of 1500 octets, about
302,600 valid samples. Wall clock is measured in Python around the traffic, in
seconds, one configuration at a time (`-p 1`).

| Configuration | GHDL | NVC | Monitor cost GHDL | Monitor cost NVC |
|---|---:|---:|---:|---:|
| no monitor | 1.84 | 0.81 | — | — |
| batched, 4096 samples per call | 2.32 | 0.96 | +0.48 (1.6 µs/sample) | +0.15 (0.5 µs/sample) |
| whole frame, one call per frame | 2.33 | 0.97 | +0.49 | +0.16 |
| one call per cycle | 16.55 | 10.32 | +14.7 (48 µs/call) | +9.5 (31 µs/call) |

One call per cycle costs 30 to 60 times as much as batching. Batched and
whole-frame transfers cost the same at this frame size, so the default is
`batch_length => 4096` with `flush_at_frame_end => true`. Batches are bounded
for jumbo frames and long runs, and each frame is checked as soon as it ends,
so a violation is logged at a simulation time close to the frame.

## 8. Batching representation

A batch is one `integer_array_t` of 32-bit signed words laid out as
`[word_0, delta_0, word_1, delta_1, ...]`, sent as
`vc.push(samples, base_hi, base_lo, delta_unit_fs)`:

- `word` is the sample word of the interface. For GMII: bits 0-7 data, 8 dv,
  9 er, 10 metavalue on data while dv, 11 metavalue on dv/er.
- `delta` is the time since the previous sample in units of `delta_unit`
  (default 1 ps). 32-bit femtosecond deltas would span only 2.1 µs, less than
  one 10 Mbit/s MII symbol.
- The base time is two integers (`hi * 2**30 + lo` fs), since VHDL integers
  are 32 bits.
- Idle is run-length compressed: a sample is recorded when dv is asserted, the
  word changes, or er/metavalue bits are set. A long idle costs one sample, and
  IFG timing survives because every sample keeps its time.
- Several words may share one time (delta 0), which is how a multi-lane
  interface records one word per lane.
- X/U/Z/W/-: `is_x` sets the metavalue bits, which the checker reports as
  ETH_METAVALUE instead of silently mapping them to 0.

Reports travel back as one string: records separated by ASCII RS, with the
severity code and message separated by US. Errors become `check_failed` on the
VC checker; failure, warning, info and debug go to the VC logger.

## 9. VHDL vs Python per interface

| | VHDL | Python |
|---|---|---|
| GMII monitor | rising edge sampling, metavalue detection, idle compression, batching, end of frame flush, wait_until_idle, final check at test_runner_cleanup | octet stream, frame assembly, preamble/SFD/FCS, runt/giant, PHY error offsets, IFG, statistics, PCAPNG, scoreboard, Scapy |
| GMII source | when pins change: one word per rising edge, back to back frames | what is sent: preamble length, SFD, padding, FCS good/bad/none, error offsets, IFG, Scapy packets |

The VHDL frontend of a new PHY only defines its sample word and pin timing.
The rest reuses `ethernet_pkg` (handles, messages, procedures), `vcs_python_pkg`
(sessions, batches, reports) and the Python core.

## 10. Public VHDL API

It follows the VUnit VCs (`uart_pkg`, `axi_stream_pkg`, `vc_pkg`):

- Handles are `ethernet_monitor_t` and `ethernet_source_t`, records with
  private `p_` fields around a `std_cfg_t` (id, actor, logger, checker,
  unexpected message policy). Constructors are `new_gmii_monitor(...)` and
  `new_gmii_source(...)`, and the ids default to
  `awesome_vunit_vcs:gmii_monitor:<n>`.
- Accessors are `get_id`, `get_logger`, `get_checker` and `as_sync`, and
  `wait_until_idle(net, as_sync(vc))` comes from `sync_pkg`.
- Procedures send `com` messages: `send_ethernet_frame`,
  `send_ethernet_packet`, `expect_ethernet_frame`, `set_check_enabled`,
  `get_check_count`, `get_frame_count`, `get_statistics`, `log_statistics`,
  `start_capture` and `stop_capture`.
- Entities are `gmii_monitor` and `gmii_source`, with the handle as a generic
  and ports `clk`, `data`, `dv`, `er`.
- Testbenches pull everything in with
  `context awesome_vunit_vcs.ethernet_context`.
- A test never writes Python. The backend object is reachable as `vc` in
  `new_session(get_id(monitor))` for Python-specific extras.

## Readiness for later interfaces

In place now:

- **Link rate:** `link_rate_mbps` on both constructors (1000 default, 2500 for
  overclocked GMII) reaches the Python PHY as `link_rate_bps` for utilization
  statistics. Clock period and rate are hardcoded nowhere, since sample times
  come from the simulation.
- **Samples wider than 32 bits:** one word per lane at the same time (delta 0).
  The layout is chosen per PHY, and the batching and bridge code in
  `vcs_python_pkg` are PHY independent.
- **Delta unit:** covers slow MII (400 ns symbols) and fast XGMII (100G ~
  0.16 ns period at 1 fs...1 ps resolution).
- **PHY events:** `PhyEvent` in `phy/common.py`, published by the monitor
  (`phy_events`) to the checker as `ETH_CONTROL` / `ETH_LINK_FAULT`. A
  control-character decoder can report Start not on lane 0, a missing
  Terminate, an unknown control character, data inside idle and local/remote
  fault ordered sets. `OctetBatch.events` defaults to empty, so GMII is
  unchanged. There are unit tests.
- **Shared VHDL layer:** `ethernet_phy_t` names the PHY, and its image selects
  the Python decoder. Handles, messages and procedures are PHY independent.

What XGMII needs:

- `xgmii` in `ethernet_phy_t` and a `new_xgmii_monitor/source` with
  `lanes : positive` (4 or 8), clocking (rising or both edges) and
  `link_rate_mbps` from 2500 to 100000. One entity covers
  2.5GMII/5GMII/25GMII/XLGMII/CGMII.
- An `xgmii_monitor` recording `lanes` words per clock (8-bit octet + control
  bit, plus metavalue bits) and an `xgmii_source` driving `lanes` words per
  edge.
- A Python `XgmiiPhy.decode` mapping Start/Terminate/Idle/Error control
  characters to octet words (valid/error), with the others as `PhyEvent`s. For
  encoding, Start replaces the first preamble octet, and IFG includes
  Terminate and the lane alignment.

What the AXI-Stream MAC client frontend needs:

- A `FrameDecoder`/`EthernetConfig` switch for frames that start at the
  destination address with no preamble/SFD. **Not present yet**: today a
  missing SFD is an `ETH_SFD` violation. `has_fcs` is already configurable.
- A frontend decoder that maps tdata/tkeep/tlast/tuser to octet words: tkeep
  selects octets, tlast ends the frame, tuser maps to the error bit. It fits the
  word layout, since tlast becomes the valid deassertion.
- Statistics on wire octets and IFG are meaningless without a PHY.
  `link_rate_bps = 0` already disables utilization.

## Known limitations

- The per-frame scoreboard (`expect_ethernet_frame`) is FIFO order only.
- The monitor's final check (unfinished frame, unreceived expected frames,
  closing captures) runs inside the `test_runner_cleanup` gates in zero
  simulation time (§8.2 phase transition event). It does not lock the gate,
  so a frame still on the wire at cleanup is reported as ETH_FRAME_STATE, not
  waited for. Tests call `wait_until_idle` first.
- `send_ethernet_packet` evaluates a Scapy expression string in the source's
  session. It is testbench code with testbench trust.
- Only GMII has a VHDL frontend. MII, RGMII and RMII are on the roadmap.
