-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An AXI-Stream MAC client sink: drives tready with a seeded backpressure
-- pattern, so a DUT or a source is tested with stalls. A monitor on the same
-- bus reconstructs the accepted frames.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.math_real.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

  use work.axis_mac_pkg.all;

entity axis_mac_sink is
  generic (
    sink : axis_mac_sink_t);
  port (
    clk : in  std_ulogic;
    tready : out std_ulogic := '1'
  );
end entity;

architecture a of axis_mac_sink is

begin

  main : process

    variable ready_high_percent : natural := get_ready_high_percent(sink);
    variable seed1, seed2 : positive;
    variable random_value : real;
    variable resume_time : time := 0 fs;
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;

    procedure set_seed (seed : natural) is
    begin

      seed1 := 1 + seed mod 2147483562;
      seed2 := 1 + (seed / 2147483562) mod 2147483398;
    end;

  begin

    set_seed(get_ready_seed(sink));
    tready <= '1' when ready_high_percent >= 100 else
              '0';

    loop

      if resume_time > now then
        wait on clk, net for resume_time - now;
      else
        wait on clk, net;
      end if;

      if rising_edge(clk) then
        if ready_high_percent >= 100 then
          tready <= '1';
        elsif ready_high_percent = 0 then
          tready <= '0';
        else
          uniform(seed1, seed2, random_value);
          tready <= '1' when random_value * 100.0 < real(ready_high_percent) else
                    '0';
        end if;
      end if;

      -- Messages after wait_for_time wait until its delay has passed, while
      -- tready keeps following the pattern
      while now >= resume_time and has_message(get_actor(sink)) loop

        receive(net, get_actor(sink), msg);
        msg_type := message_type(msg);

        if msg_type = set_axis_mac_sink_ready_msg then
          handle_message(msg_type);
          ready_high_percent := pop(msg);
          set_seed(pop(msg));
        elsif msg_type = reset_axis_mac_sink_msg then
          handle_message(msg_type);
          ready_high_percent := get_ready_high_percent(sink);
          set_seed(get_ready_seed(sink));
          resume_time := now;
          reply_msg := new_msg(reset_axis_mac_sink_reply_msg);
          reply(net, msg, reply_msg);
        elsif msg_type = wait_for_time_msg then
          handle_message(msg_type);
          resume_time := now + pop_time(msg);
        else
          -- A sink has nothing in progress, so it is always idle
          handle_wait_until_idle(net, msg_type, msg);
        end if;

        if not is_already_handled(msg_type) and get_unexpected_msg_type_policy(sink) = fail then
          check_failed(get_checker(sink), "Got unexpected message " & name(msg_type));
        end if;
      end loop;

    end loop;

  end process;

end architecture;
