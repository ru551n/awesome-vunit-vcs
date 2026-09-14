-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Constructors of the MII verification components. The handles and
-- procedures are those of ethernet_pkg; MII (IEEE 802.3 Clause 22) carries one
-- nibble per clock cycle, least significant nibble first, at 10 Mbit/s
-- (2.5 MHz clock) or 100 Mbit/s (25 MHz clock).

library vunit_lib;
context vunit_lib.vunit_context;
use vunit_lib.vc_pkg.all;

use work.ethernet_pkg.all;

package mii_pkg is
  -- A passive monitor for mii_monitor, see new_ethernet_monitor. link_rate_mbps
  -- is 10 or 100.
  impure function new_mii_monitor(
    id : id_t := null_id;
    link_rate_mbps : positive := 100;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t;

  -- An active source for mii_source, see new_ethernet_source. link_rate_mbps
  -- is 10 or 100.
  impure function new_mii_source(
    id : id_t := null_id;
    link_rate_mbps : positive := 100;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t;
end package;

package body mii_pkg is
  procedure check_link_rate(link_rate_mbps : positive) is
  begin
    assert link_rate_mbps = 10 or link_rate_mbps = 100
      report "MII link_rate_mbps is 10 or 100, got " & integer'image(link_rate_mbps) severity failure;
  end;

  impure function new_mii_monitor(
    id : id_t := null_id;
    link_rate_mbps : positive := 100;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t is
  begin
    check_link_rate(link_rate_mbps);
    return new_ethernet_monitor(
      phy => mii,
      id => id,
      link_rate_mbps => link_rate_mbps,
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

  impure function new_mii_source(
    id : id_t := null_id;
    link_rate_mbps : positive := 100;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t is
  begin
    check_link_rate(link_rate_mbps);
    return new_ethernet_source(
      phy => mii,
      id => id,
      link_rate_mbps => link_rate_mbps,
      unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  end;
end package body;
