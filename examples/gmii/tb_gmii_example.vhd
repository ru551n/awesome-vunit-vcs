-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library osvvm;
  use osvvm.randompkg.randomptype;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

-- A gmii_source drives the input of the DUT, a register pipeline. One monitor
-- observes the input and one the output, each with a protocol checker: the
-- frames must leave the DUT as they entered it.
entity tb_gmii_example is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_gmii_example is

  constant clk_period : time := 8 ns;

  signal clk : std_ulogic := '0';
  signal in_data, out_data : std_ulogic_vector(7 downto 0);
  signal in_dv : std_ulogic;
  signal in_er : std_ulogic;
  signal out_dv : std_ulogic;
  signal out_er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  -- docs-start: monitors
  -- The input monitor checks the protocol with custom limits: VLAN-tagged frames may be 1522 octets
  constant input_monitor : gmii_monitor_t := new_gmii_monitor(
    protocol_checker => new_gmii_protocol_checker(max_frame_octets => 1522),
    id => get_id("tb_gmii_example:input_monitor")
  );
  -- The output monitor uses the default protocol checks
  constant output_monitor : gmii_monitor_t :=
    new_gmii_monitor(protocol_checker => default_gmii_protocol_checker, id => get_id("tb_gmii_example:output_monitor"));

-- docs-end: monitors
begin

  clk <= not clk after clk_period / 2;

  main : process

    variable rnd : randomptype;
    variable count : natural;
    variable input_statistics, output_statistics : ethernet_statistics_t;

    -- Frame data from the destination address up to, not including, the FCS:
    -- the addresses, the local experimental EtherType and a random payload
    impure function random_frame (octets : positive) return std_ulogic_vector is

      variable result : std_ulogic_vector(0 to 8 * octets - 1);
    begin

      result(0 to 111) := x"020000000001" & x"020000000002" & x"88B5";
      for idx in 14 to octets - 1 loop

        result(8 * idx to 8 * idx + 7) := rnd.RandSlv(8);
      end loop;

      return result;
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    while test_suite loop

      if run("test_frames_pass_through_the_dut") then
        start_capture(net, output_monitor, output_path(runner_cfg) & "gmii_example.pcapng");

        for idx in 1 to 20 loop

          -- The scoreboard compares the next received frame with the expected
          -- one; a difference is an ETH_SCOREBOARD check failure
          check_ethernet_frame(net, output_monitor, random_frame(rnd.RandInt(60, 1514)), blocking => false);
        end loop;

        -- Replay the same random sequence for the source
        rnd.InitSeed(get_string_seed(runner_cfg));
        for idx in 1 to 20 loop

          push_ethernet_frame(net, source, random_frame(rnd.RandInt(60, 1514)));
        end loop;

        wait_until_idle(net, as_sync(source));
        wait_until_idle(net, as_sync(input_monitor));
        wait_until_idle(net, as_sync(output_monitor));

        get_statistics(net, input_monitor, input_statistics);
        get_statistics(net, output_monitor, output_statistics);
        check_equal(output_statistics.good_frames, 20, "Seed " & get_string_seed(runner_cfg));
        check_equal(output_statistics.wire_octets, input_statistics.wire_octets);
        log_statistics(net, output_monitor);

      elsif run("test_bad_fcs_is_detected_on_both_sides") then
        -- A deliberate error is logged as an error on the protocol checker of
        -- each monitor. Count it instead of stopping; an error left uncounted
        -- still fails the test.
        disable_stop(get_logger(get_protocol_checker(input_monitor)), error);
        disable_stop(get_logger(get_protocol_checker(output_monitor)), error);

        push_ethernet_frame(net, source, random_frame(100), frame_options(fcs => fcs_bad));
        wait_until_idle(net, as_sync(source));
        wait_until_idle(net, as_sync(input_monitor));
        wait_until_idle(net, as_sync(output_monitor));

        get_check_count(net, input_monitor, eth_fcs, count);
        check_equal(count, 1);
        get_check_count(net, output_monitor, eth_fcs, count);
        check_equal(count, 1);
        check_equal(get_log_count(get_logger(get_protocol_checker(output_monitor)), error), 1);
        reset_log_count(get_logger(get_protocol_checker(input_monitor)), error);
        reset_log_count(get_logger(get_protocol_checker(output_monitor)), error);

      elsif run("test_python_subscriber") then
        -- The backend of a monitor is the object vc in the Python session
        -- with the identity of the monitor. python/frame_sizes.py subscribes
        -- to the frames it reconstructs.
        exec_file(tb_path(runner_cfg) & "python/frame_sizes.py", new_session(get_id(output_monitor)));

        push_ethernet_frame(net, source, random_frame(60));
        push_ethernet_frame(net, source, random_frame(200));
        wait_until_idle(net, as_sync(source));
        wait_until_idle(net, as_sync(input_monitor));
        wait_until_idle(net, as_sync(output_monitor));

        check_equal(eval_integer("len(frame_sizes)", new_session(get_id(output_monitor))), 2);
        check_equal(eval_integer("max(frame_sizes)", new_session(get_id(output_monitor))), 200);

      elsif run("test_scapy_packet") then
        if eval_boolean(
          "__import__('importlib.util').util.find_spec('scapy') is not None",
          new_session("tb_gmii_example:scapy")
        ) then
          -- python/packets.py builds the packet; the directory is on the Python path
          exec("import sys");
          call("sys.path.insert", arg(0), arg(tb_path(runner_cfg) & "python"));
          push_ethernet_packet(net, source, "packets:udp_packet", kwarg("dport", 1234));
          wait_until_idle(net, as_sync(source));
          wait_until_idle(net, as_sync(input_monitor));
          wait_until_idle(net, as_sync(output_monitor));
          check_equal(eval_integer("vc.last_packet()['UDP'].dport", new_session(get_id(output_monitor))), 1234);
        else
          info("Scapy is not installed (pip install awesome-vunit-vcs[scapy]), nothing to test");
        end if;
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => in_data,
      dv => in_dv,
      er => in_er
    );

  input_monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => input_monitor
    )
    port map (
      clk => clk,
      data => in_data,
      dv => in_dv,
      er => in_er
    );

  dut : entity work.gmii_pipeline
    port map (
      clk => clk,
      in_data => in_data,
      in_dv => in_dv,
      in_er => in_er,
      out_data => out_data,
      out_dv => out_dv,
      out_er => out_er
    );

  -- docs-start: monitor-instance
  output_monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => output_monitor
    )
    port map (
      clk => clk,
      data => out_data,
      dv => out_dv,
      er => out_er
    );

  -- docs-end: monitor-instance
end architecture;
