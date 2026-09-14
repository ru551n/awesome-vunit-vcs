-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Constructors of the GMII verification components. The handles and
-- procedures are those of ethernet_pkg; GMII carries one octet per clock
-- cycle, at 1000 Mbit/s or overclocked at 2500 Mbit/s.

library vunit_lib;
context vunit_lib.vunit_context;
use vunit_lib.vc_pkg.all;

use work.ethernet_pkg.all;

package gmii_pkg is
  -- A passive monitor for gmii_monitor, see new_ethernet_monitor
  impure function new_gmii_monitor(
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
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

  -- An active source for gmii_source, see new_ethernet_source
  impure function new_gmii_source(
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t;
end package;

package body gmii_pkg is
  impure function new_gmii_monitor(
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
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
    return new_ethernet_monitor(
      phy => gmii,
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

  impure function new_gmii_source(
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t is
  begin
    return new_ethernet_source(
      phy => gmii,
      id => id,
      link_rate_mbps => link_rate_mbps,
      unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  end;
end package body;
