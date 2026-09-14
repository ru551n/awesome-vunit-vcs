-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active GMII source: drives one direction of a GMII interface. Python decides
-- what is transmitted (preamble, SFD, padding, FCS, errors, IFG) and returns
-- one sample word per clock cycle; this entity decides when the pins change,
-- which is on the rising edge of the clock.

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

entity gmii_source is
  generic (
    source : ethernet_source_t
  );
  port (
    -- GTX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : out std_ulogic_vector(7 downto 0) := (others => '0');
    -- TX_EN or RX_DV
    dv : out std_ulogic := '0';
    -- TX_ER or RX_ER
    er : out std_ulogic := '0'
  );
end entity;

architecture a of gmii_source is
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id(source));
    constant actor : actor_t := as_sync(source);

    variable msg : msg_t;
    variable msg_type : msg_type_t;

    procedure drive(symbols : integer_array_t) is
      variable word : natural range 0 to 2 ** 10 - 1;
    begin
      for idx in 0 to length(symbols) - 1 loop
        wait until rising_edge(clk);
        word := get(symbols, idx);
        data <= std_ulogic_vector(to_unsigned(word mod 2 ** 8, data'length));
        dv <= '1' when word / 2 ** 8 mod 2 = 1 else '0';
        er <= '1' when word / 2 ** 9 mod 2 = 1 else '0';
      end loop;

      -- A frame without IFG is followed by the next frame if there is one
      if dv = '1' and not has_message(actor) then
        wait until rising_edge(clk);
        data <= (others => '0');
        dv <= '0';
        er <= '0';
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
  begin
    assert source.p_phy = gmii
      report "gmii_source needs a source created by new_gmii_source" severity failure;
    create_backend(session, ethernet_backend_module, ethernet_source_backend_class, backend_arguments(source));

    loop
      receive(net, actor, msg);
      msg_type := message_type(msg);

      handle_sync_message(net, msg_type, msg);

      if msg_type = ethernet_send_frame_msg or msg_type = ethernet_send_packet_msg then
        transmit(transmit_expression(msg_type, msg));
      else
        unexpected_msg_type(msg_type, source.p_std_cfg);
      end if;
    end loop;
  end process;
end architecture;
