-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Constructors and procedures of the XGMII verification components. One pair
-- of components covers the whole XGMII family, which differs in lane count,
-- clocking and link rate only:
--
--   interface              lanes  both_edges  link_rate_mbps
--   XGMII (Clause 46)      4      true        10000
--   32-bit SDR XGMII       4      false       10000
--   64-bit XGMII           8      false       10000
--   2.5GMII / 5GMII        4 / 8  false       2500 / 5000
--   25GMII                 8      false       25000
--   XLGMII / CGMII         8      false       40000 / 100000
--
-- Frames use the handles and procedures of ethernet_pkg. Control characters
-- (Start, Terminate, Error, Sequence ordered sets) are decoded and checked in
-- the Python backend.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.vc_pkg.all;

use work.ethernet_pkg.all;

package xgmii_pkg is
  type xgmii_link_fault_t is (local_fault, remote_fault);

  -- A passive monitor for xgmii_monitor, see new_ethernet_monitor.
  --
  -- lanes is 4 or 8; both_edges samples a column on both clock edges (4-lane
  -- XGMII). allow_lane4_start accepts frames starting on lane 4 of 8 lanes.
  -- The Start character counts as a preamble octet. min_ifg_octets is 5, the
  -- minimum gap at an XGMII receiver; Terminate counts as a gap octet.
  impure function new_xgmii_monitor(
    id : id_t := null_id;
    lanes : positive := 4;
    both_edges : boolean := false;
    link_rate_mbps : positive := 10000;
    allow_lane4_start : boolean := false;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 5;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t;

  -- An active source for xgmii_source, see new_ethernet_source.
  --
  -- Frames start on lane 0, so the IFG after a frame is rounded to whole
  -- columns: with deficit_idle it is rounded down when the idle deficit of
  -- earlier frames allows it, keeping the average IFG at the requested one,
  -- otherwise up. An error offset transmits the Error character.
  impure function new_xgmii_source(
    id : id_t := null_id;
    lanes : positive := 4;
    both_edges : boolean := false;
    link_rate_mbps : positive := 10000;
    deficit_idle : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t;

  -- Transmit columns exactly as given: data is one octet per lane and control
  -- one bit per lane, lane 0 of the first column leftmost. For traffic the
  -- frame procedures cannot describe, such as a Start on the wrong lane.
  procedure send_xgmii_columns(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    control : std_ulogic_vector
  );

  -- Transmit columns carrying the Sequence ordered set of a link fault
  procedure send_xgmii_link_fault(
    signal net : inout network_t;
    source : ethernet_source_t;
    fault : xgmii_link_fault_t;
    columns : positive := 1
  );

  -- Message types
  constant xgmii_send_columns_msg : msg_type_t := new_msg_type("xgmii send columns");
  constant xgmii_send_link_fault_msg : msg_type_t := new_msg_type("xgmii send link fault");
end package;

package body xgmii_pkg is
  procedure check_lanes(lanes : positive; both_edges : boolean) is
  begin
    assert lanes = 4 or lanes = 8
      report "An XGMII interface has 4 or 8 lanes, got " & integer'image(lanes) severity failure;
    assert lanes = 4 or not both_edges
      report "Only 4-lane XGMII transfers columns on both clock edges" severity failure;
  end;

  impure function new_xgmii_monitor(
    id : id_t := null_id;
    lanes : positive := 4;
    both_edges : boolean := false;
    link_rate_mbps : positive := 10000;
    allow_lane4_start : boolean := false;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 5;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t is
  begin
    check_lanes(lanes, both_edges);
    assert lanes = 8 or not allow_lane4_start
      report "allow_lane4_start needs 8 lanes" severity failure;
    return new_ethernet_monitor(
      phy => xgmii,
      id => id,
      link_rate_mbps => link_rate_mbps,
      lanes => lanes,
      both_edges => both_edges,
      allow_lane4_start => allow_lane4_start,
      min_preamble_octets => min_preamble_octets,
      max_preamble_octets => max_preamble_octets,
      min_frame_octets => min_frame_octets,
      max_frame_octets => max_frame_octets,
      min_ifg_octets => min_ifg_octets,
      has_fcs => has_fcs,
      batch_length => batch_length,
      flush_at_frame_end => flush_at_frame_end,
      delta_unit => delta_unit,
      log_frames => log_frames,
      unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  end;

  impure function new_xgmii_source(
    id : id_t := null_id;
    lanes : positive := 4;
    both_edges : boolean := false;
    link_rate_mbps : positive := 10000;
    deficit_idle : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t is
  begin
    check_lanes(lanes, both_edges);
    return new_ethernet_source(
      phy => xgmii,
      id => id,
      link_rate_mbps => link_rate_mbps,
      lanes => lanes,
      both_edges => both_edges,
      deficit_idle => deficit_idle,
      unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  end;

  procedure send_xgmii_columns(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    control : std_ulogic_vector
  ) is
    variable msg : msg_t := new_msg(xgmii_send_columns_msg);
  begin
    check(
      get_checker(source.p_std_cfg),
      data'length = 8 * control'length and control'length mod source.p_lanes = 0,
      "XGMII columns need one data octet and one control bit per lane, whole columns of " &
      integer'image(source.p_lanes) & " lanes; got " & integer'image(data'length) & " data bits and " &
      integer'image(control'length) & " control bits"
    );
    push(msg, data);
    push(msg, control);
    send(net, get_actor(source.p_std_cfg), msg);
  end;

  procedure send_xgmii_link_fault(
    signal net : inout network_t;
    source : ethernet_source_t;
    fault : xgmii_link_fault_t;
    columns : positive := 1
  ) is
    variable msg : msg_t := new_msg(xgmii_send_link_fault_msg);
  begin
    push(msg, xgmii_link_fault_t'pos(fault));
    push(msg, columns);
    send(net, get_actor(source.p_std_cfg), msg);
  end;
end package body;
