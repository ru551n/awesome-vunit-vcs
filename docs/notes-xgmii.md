# XGMII implementation notes

Facts for README.md, ARCHITECTURE.md and the docs, recorded while the XGMII family was built.

## One component for the family

`xgmii_monitor` and `xgmii_source` cover every interface with XGMII framing. They differ in lane
count, clocking and link rate only:

| Interface | `lanes` | `both_edges` | `link_rate_mbps` |
|---|---|---|---|
| XGMII (IEEE 802.3 Clause 46) | 4 | true | 10000 |
| 32-bit single edge XGMII | 4 | false | 10000 |
| 64-bit XGMII (10G/25G MAC cores) | 8 | false | 10000 |
| 2.5GMII / 5GMII | 4 or 8 | false | 2500 / 5000 |
| 25GMII | 8 | false | 25000 |
| XLGMII / CGMII | 8 | false | 40000 / 100000 |
| 200GMII / 400GMII (IEEE 802.3bs) | 8 | false | 200000 / 400000 |

Ports: `clk`, `data(8 * lanes - 1 downto 0)` with lane 0 in the low octet, `ctrl(lanes - 1 downto 0)`
with lane 0 in the low bit. Handles are the `ethernet_monitor_t`/`ethernet_source_t` of
`ethernet_pkg`; every frame, check, statistics and capture procedure works unchanged.

## Public VHDL API (xgmii_pkg)

* `new_xgmii_monitor(id, lanes => 4, both_edges => false, link_rate_mbps => 10000,
  allow_lane4_start => false, min/max_preamble_octets => 7, min/max_frame_octets, min_ifg_octets => 5,
  has_fcs, batch_length, flush_at_frame_end, delta_unit, log_frames, unexpected_msg_type_policy)`
* `new_xgmii_source(id, lanes => 4, both_edges => false, link_rate_mbps => 10000,
  deficit_idle => true, unexpected_msg_type_policy)`
* `send_xgmii_columns(net, source, data, control)`: raw columns, one octet and one control bit per
  lane, lane 0 of the first column leftmost. For traffic the frame procedures cannot describe.
* `send_xgmii_link_fault(net, source, local_fault | remote_fault, columns)`

## Control characters and their sources

IEEE 802.3 Table 46-3, as reproduced in Xilinx XAPP687 Table 2: Idle 0x07, Start 0xFB, Terminate
0xFD, Error 0xFE, Sequence 0x9C. Start and Sequence are placed on lane 0 (lane 0 or 4 in the 64-bit
10GBASE-R variant, hence `allow_lane4_start`). Link fault ordered sets (Table 46-5, used as test
vectors by the UNH-IOL Clause 49 PCS test suite): 0x9C 0x00 0x00 0x01 local fault, 0x9C 0x00 0x00 0x02
remote fault. Minimum IPG at an XGMII receiver is 5 octets (IEEE 802.3 interpretation 1-11/09 of
4.4.2); a deficit idle count bounded to 0..3 keeps the transmit average at 12. cocotbext-eth's
`XgmiiCtrl` uses the same values.

## Boundary

* VHDL samples a column per clock edge (rising, or both), records one sample word per lane
  (data, control bit, metavalue bits) and skips an Idle column equal to the previous one.
* Python (`ethernet/phy/xgmii.py`) decodes lanes into the common octet words: Start becomes the first
  preamble octet (it replaces it on the wire, so 7 preamble octets are expected, Start included),
  Error inside a frame is an octet with the error bit, Terminate ends the frame. Octet `k` of a
  column is timed `k` octet periods (8 / link rate) after the column, so IFG is counted in octets
  whatever the clocking; Terminate and the Idles count as gap octets.
* Violations the octet words cannot express are `PhyEvent`s: `ETH_CONTROL` (Start or Sequence on a
  wrong lane, unknown or reserved control character, Terminate outside a frame, data outside a frame,
  incomplete or reserved ordered set), `ETH_TERMINATION` (a frame ended without Terminate),
  `ETH_LINK_FAULT` (local or remote fault; reported when it starts, cleared by an Idle on lane 0 or a
  frame). Error outside a frame is `ETH_CARRIER`, like GMII's error signal outside a frame.

## Source behavior

* Frames start on lane 0. The gap after a frame is rounded to whole columns; with `deficit_idle` it is
  rounded down while the accumulated deficit stays within `lanes - 1` octets, otherwise up, so the
  average gap equals the requested one and a single gap may be `lanes - 1` octets shorter.
* Error offsets transmit the Error character in place of the octet.
* After columns that do not end in Idle, the source drives Idle when nothing else is queued, and
  before handling a request that is not a transmit request (such as `wait_until_idle`), so a wait
  returns only after the monitors sampled the last column.

## Shared code

`ethernet_vc_pkg` holds what monitor and source entities of every Ethernet PHY share: monitor message
handling, end-of-frame flush and `wait_until_idle` replies, the final checks, and the backend expression
of frame and packet requests. `gmii_monitor` and `gmii_source` use it too. `vcs_python_pkg` and
`common/` were not changed.

## Simplifications and limitations

* The source never starts a frame on lane 4 and has no lane-4 deficit alignment.
* Link fault state is reported when it starts; the 802.3 fault state machine (column counters for
  clearing) is not modeled.
* LPI (0x06) is accepted like Idle outside a frame; LPI assert/deassert sequencing is not checked.
* Signal ordered sets (0x5C) are reported as unknown control characters.
* The link rate must match the clock: the octet period used for IFG comes from `link_rate_mbps`.

## Tests

* Python: `tests/python/test_xgmii.py` builds columns lane by lane from the standard's codes
  (`helpers.XgmiiLine`), independent of the encoder.
* HDL: `tests/vhdl/tb_xgmii.vhd`, run for 4 lanes single edge, 4 lanes both edges and 8 lanes.
