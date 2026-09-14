-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive XGMII monitor: samples one direction of an XGMII-family interface
-- on the rising edge of its clock, or on both edges, and never drives it.
-- Control characters, frames, protocol checks, statistics and capture are
-- handled in the Python backend.
--
-- A column (the lanes of one clock edge) is recorded as one sample word per
-- lane, lane 0 first, unless it is an Idle column like the one before it, so
-- a long idle period costs one column. Sample words (see
-- awesome_vunit_vcs/ethernet/phy/xgmii.py):
--
--   bit 0-7  lane data
--   bit 8    lane control
--   bit 10   metavalue on the lane data
--   bit 11   metavalue on the lane control

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.ethernet_pkg.all;
use work.ethernet_vc_pkg.all;
use work.vcs_python_pkg.all;

entity xgmii_monitor is
  generic (
    monitor : ethernet_monitor_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD, lane 0 in the low octet
    data : in std_ulogic_vector(8 * monitor.p_lanes - 1 downto 0);
    -- TXC or RXC, lane 0 in the low bit
    ctrl : in std_ulogic_vector(monitor.p_lanes - 1 downto 0)
  );
end entity;

architecture a of xgmii_monitor is
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id(monitor));
    constant actor : actor_t := as_sync(monitor);
    -- wait_until_idle requests waiting for the end of a frame
    constant idle_requests : queue_t := new_queue;

    subtype sample_word_t is natural range 0 to 2 ** 12 - 1;
    type column_t is array (0 to monitor.p_lanes - 1) of sample_word_t;
    constant control_bit : sample_word_t := 2 ** 8;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;
    constant idle_column : column_t := (others => control_bit + 16#07#);

    variable batch : sample_batch_t;
    variable column : column_t;
    variable previous_column : column_t := idle_column;
    variable in_frame : boolean := false;
    variable finished : boolean := false;
    variable msg : msg_t;

    impure function sample_column return column_t is
      variable lane_data : std_ulogic_vector(7 downto 0);
      variable result : column_t;
    begin
      for lane in result'range loop
        lane_data := data(8 * lane + 7 downto 8 * lane);
        result(lane) := to_integer(to_01(unsigned(lane_data)));
        if to_x01(ctrl(lane)) = '1' then
          result(lane) := result(lane) + control_bit;
        end if;
        if is_x(lane_data) then
          result(lane) := result(lane) + data_metavalue_bit;
        end if;
        if is_x(ctrl(lane)) then
          result(lane) := result(lane) + control_metavalue_bit;
        end if;
      end loop;
      return result;
    end;
  begin
    assert monitor.p_phy = xgmii
      report "xgmii_monitor needs a monitor created by new_xgmii_monitor" severity failure;
    create_backend(session, ethernet_backend_module, ethernet_monitor_backend_class, backend_arguments(monitor));
    batch := new_sample_batch(
      session, get_logger(monitor), get_checker(monitor), monitor.p_batch_length, monitor.p_delta_unit
    );

    while not finished loop
      wait on clk, net, runner;

      if rising_edge(clk) or (monitor.p_both_edges and falling_edge(clk)) then
        column := sample_column;
        if column /= idle_column or column /= previous_column then
          for lane in column'range loop
            record_sample(batch, column(lane));
          end loop;
        end if;

        -- Anything but an Idle column is traffic: a frame, an ordered set or
        -- a violation the backend reports
        if in_frame and column = idle_column then
          end_monitor_frame(net, monitor, batch, idle_requests);
        end if;

        in_frame := column /= idle_column;
        previous_column := column;
      end if;

      while has_message(actor) loop
        receive(net, actor, msg);
        handle_monitor_message(net, monitor, session, batch, idle_requests, in_frame, msg);
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        finish_monitor(monitor, session, batch);
        finished := true;
      end if;
    end loop;

    wait;
  end process;
end architecture;
