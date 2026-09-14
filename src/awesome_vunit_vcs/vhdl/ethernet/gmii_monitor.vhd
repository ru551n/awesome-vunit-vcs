-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive GMII monitor: samples one direction of a GMII interface on the
-- rising edge of its clock and never drives it. Frame reconstruction,
-- protocol checks, statistics and capture happen in the Python backend.
--
-- A sample is recorded when valid is asserted or the sample word changes, so
-- a long idle period costs one sample. Sample words (see
-- awesome_vunit_vcs/ethernet/phy/common.py):
--
--   bit 0-7  data
--   bit 8    dv
--   bit 9    er
--   bit 10   metavalue on data while dv is asserted
--   bit 11   metavalue on dv or er

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

entity gmii_monitor is
  generic (
    monitor : ethernet_monitor_t
  );
  port (
    -- GTX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : in std_ulogic_vector(7 downto 0);
    -- TX_EN or RX_DV
    dv : in std_ulogic;
    -- TX_ER or RX_ER
    er : in std_ulogic := '0'
  );
end entity;

architecture a of gmii_monitor is
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id(monitor));
    constant actor : actor_t := as_sync(monitor);
    -- wait_until_idle requests waiting for the end of a frame
    constant idle_requests : queue_t := new_queue;

    subtype sample_word_t is natural range 0 to 2 ** 12 - 1;
    constant valid_bit : sample_word_t := 2 ** 8;
    constant error_bit : sample_word_t := 2 ** 9;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;

    variable batch : sample_batch_t;
    variable word : sample_word_t;
    variable previous_word : integer := -1;
    variable in_frame : boolean := false;
    variable finished : boolean := false;
    variable msg : msg_t;

    impure function sample_word return sample_word_t is
      variable result : sample_word_t := to_integer(to_01(unsigned(data)));
    begin
      if to_x01(dv) = '1' then
        result := result + valid_bit;
        if is_x(data) then
          result := result + data_metavalue_bit;
        end if;
      end if;
      if to_x01(er) = '1' then
        result := result + error_bit;
      end if;
      if is_x(dv) or is_x(er) then
        result := result + control_metavalue_bit;
      end if;
      return result;
    end;

    function is_valid(sample : sample_word_t) return boolean is
    begin
      return sample / valid_bit mod 2 = 1;
    end;
  begin
    assert monitor.p_phy = gmii
      report "gmii_monitor needs a monitor created by new_gmii_monitor" severity failure;
    create_backend(session, ethernet_backend_module, ethernet_monitor_backend_class, backend_arguments(monitor));
    batch := new_sample_batch(
      session, get_logger(monitor), get_checker(monitor), monitor.p_batch_length, monitor.p_delta_unit
    );

    while not finished loop
      wait on clk, net, runner;

      if rising_edge(clk) then
        word := sample_word;
        if is_valid(word) or word /= previous_word or word >= error_bit then
          record_sample(batch, word);
        end if;

        if in_frame and not is_valid(word) then
          end_monitor_frame(net, monitor, batch, idle_requests);
        end if;

        in_frame := is_valid(word);
        previous_word := word;
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
