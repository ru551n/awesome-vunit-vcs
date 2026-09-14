-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active XGMII source: drives one direction of an XGMII-family interface.
-- Python decides what is transmitted (Start, preamble, frame, FCS, Error,
-- Terminate, Idle, ordered sets) and returns one sample word per lane; this
-- entity drives a column on every rising clock edge, or on both edges, and
-- Idle columns when there is nothing to transmit.

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
use work.xgmii_pkg.all;

entity xgmii_source is
  generic (
    source : ethernet_source_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD, lane 0 in the low octet
    data : out std_ulogic_vector(8 * source.p_lanes - 1 downto 0) := (others => '0');
    -- TXC or RXC, lane 0 in the low bit
    ctrl : out std_ulogic_vector(source.p_lanes - 1 downto 0) := (others => '1')
  );
end entity;

architecture a of xgmii_source is
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id(source));
    constant actor : actor_t := as_sync(source);
    constant lanes : positive := source.p_lanes;
    constant idle_character : std_ulogic_vector(7 downto 0) := x"07";

    variable msg : msg_t;
    variable msg_type : msg_type_t;
    variable idle : boolean := true;

    procedure wait_for_edge is
    begin
      wait until rising_edge(clk) or (source.p_both_edges and falling_edge(clk));
    end;

    procedure drive_idle is
    begin
      for lane in 0 to lanes - 1 loop
        data(8 * lane + 7 downto 8 * lane) <= idle_character;
      end loop;
      ctrl <= (others => '1');
      idle := true;
    end;

    procedure drive(symbols : integer_array_t) is
      variable word : natural range 0 to 2 ** 9 - 1;
    begin
      for column in 0 to length(symbols) / lanes - 1 loop
        wait_for_edge;
        idle := true;
        for lane in 0 to lanes - 1 loop
          word := get(symbols, column * lanes + lane);
          data(8 * lane + 7 downto 8 * lane) <= std_ulogic_vector(to_unsigned(word mod 2 ** 8, 8));
          ctrl(lane) <= '1' when word / 2 ** 8 = 1 else '0';
          if word /= 2 ** 8 + 16#07# then
            idle := false;
          end if;
        end loop;
      end loop;

      -- Columns that do not end in Idle are followed by the next transmit
      -- request, or by Idle when there is none
      if not idle and not has_message(actor) then
        wait_for_edge;
        drive_idle;
      end if;
    end;

    -- Transmit what vc.<expression> returns
    procedure transmit(expression : string) is
      variable symbols : integer_array_t;
    begin
      symbols := backend_integer_array(session, expression);
      drive(symbols);
      deallocate(symbols);
    end;

    impure function columns_expression(request_msg : msg_t) return string is
      constant column_data : std_ulogic_vector := pop_std_ulogic_vector(request_msg);
      constant column_control : std_ulogic_vector := pop_std_ulogic_vector(request_msg);
      alias control_bits : std_ulogic_vector(0 to column_control'length - 1) is column_control;
      variable control_values : integer_vector(control_bits'range);
    begin
      for idx in control_bits'range loop
        control_values(idx) := 1 when to_x01(control_bits(idx)) = '1' else 0;
      end loop;
      return "column_symbols(" & py_int_list(to_octets(column_data)) & ", " & py_int_list(control_values) & ")";
    end;

    impure function link_fault_expression(request_msg : msg_t) return string is
      -- The ordered set value of local fault is 1, of remote fault 2
      constant fault : xgmii_link_fault_t := xgmii_link_fault_t'val(integer'(pop(request_msg)));
      constant columns : positive := pop(request_msg);
    begin
      return
        "ordered_set_symbols(" & integer'image(xgmii_link_fault_t'pos(fault) + 1) &
        ", " & integer'image(columns) & ")";
    end;
  begin
    assert source.p_phy = xgmii
      report "xgmii_source needs a source created by new_xgmii_source" severity failure;
    create_backend(session, ethernet_backend_module, ethernet_source_backend_class, backend_arguments(source));
    drive_idle;

    loop
      receive(net, actor, msg);
      msg_type := message_type(msg);

      -- Any other request, such as wait_until_idle, finds the line Idle, and
      -- monitors have sampled the last transmitted column when it is handled
      if not idle and msg_type /= ethernet_send_frame_msg and msg_type /= ethernet_send_packet_msg and
        msg_type /= xgmii_send_columns_msg and msg_type /= xgmii_send_link_fault_msg then
        wait_for_edge;
        drive_idle;
      end if;

      handle_sync_message(net, msg_type, msg);

      if msg_type = ethernet_send_frame_msg or msg_type = ethernet_send_packet_msg then
        transmit(transmit_expression(msg_type, msg));
      elsif msg_type = xgmii_send_columns_msg then
        transmit(columns_expression(msg));
      elsif msg_type = xgmii_send_link_fault_msg then
        transmit(link_fault_expression(msg));
      else
        unexpected_msg_type(msg_type, source.p_std_cfg);
      end if;
    end loop;
  end process;
end architecture;
