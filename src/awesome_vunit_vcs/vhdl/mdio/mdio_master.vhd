-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- MDIO master verification component: drives MDC and sends frames bit by bit.
--
-- A bit takes one MDC period: MDC is low for the first half, and MDIO changes
-- when MDC falls, so it is set up half a period before MDC rises. MDIO is
-- sampled at the rising edge, before a PHY with no clock-to-output delay
-- changes it. MDC stays low and MDIO released between frames.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;

use work.mdio_pkg.all;
use work.mdio_master_pkg.all;

entity mdio_master is
  generic (
    -- Created with :vhdl:`mdio_master_pkg.new_mdio_master`
    master : mdio_master_t
  );
  port (
    -- The management clock
    mdc : out std_ulogic := '0';
    -- The management data line: driven in the bits the master sends, else
    -- released 'Z'
    mdio : inout std_logic := 'Z'
  );
end entity;

architecture a of mdio_master is

begin

  main : process

    -- The longest frame transfer_mdio sends
    constant max_bits : positive := 4096;

    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable period : delay_length := mdc_period(master);
    variable sampled : std_ulogic_vector(0 to max_bits - 1);
    variable length : natural;

    -- Send bits; sampled gets what MDIO was at the rising MDC edges
    procedure send_bits(bits : std_ulogic_vector)is
      alias normalized : std_ulogic_vector(0 to bits'length - 1) is bits;
    begin

      length := bits'length;
      if length > max_bits then
        check_failed(
          get_checker(master),
          "A frame of "
          & integer'image(length)
          & " bits exceeds "
          & integer'image(max_bits)
          & " bits."
        );
        length := 0;
        return;
      end if;
      for idx in normalized'range loop

        mdio <= normalized(idx);
        wait for period / 2;
        sampled(idx) := mdio;
        mdc <= '1';
        wait for period - period / 2;
        mdc <= '0';
      end loop;

      mdio <= 'Z';
    end procedure;

  begin
    loop

      receive(net, get_actor(master), msg);
      msg_type := message_type(msg);
      handle_sync_message(net, msg_type, msg);

      if msg_type = set_mdio_master_mdc_period_msg then
        period := pop(msg);
      elsif msg_type = write_mdio_msg then
        send_bits(pop_std_ulogic_vector(msg));
      elsif msg_type = read_mdio_msg then
        send_bits(pop_std_ulogic_vector(msg));
        reply_msg := new_msg(read_mdio_reply_msg);
        push_std_ulogic_vector(reply_msg, to_x01(sampled(length - 16 to length - 1)));
        reply(net, msg, reply_msg);
      elsif msg_type = transfer_mdio_msg then
        send_bits(pop_std_ulogic_vector(msg));
        reply_msg := new_msg(transfer_mdio_reply_msg);
        push_std_ulogic_vector(reply_msg, sampled(0 to length - 1));
        reply(net, msg, reply_msg);
      elsif msg_type = reset_mdio_master_msg then
        mdio <= 'Z';
        mdc <= '0';
        reply_msg := new_msg(reset_mdio_master_reply_msg);
        reply(net, msg, reply_msg);
      else
        unexpected_msg_type(msg_type, master);
      end if;
    end loop;

  end process;

end architecture;
