-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
-- docs-end: context

-- One test case per common construct. A GMII source sends frames through a
-- register stage (the design under test) to a monitor with the default
-- protocol checks.
entity tb_cookbook is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_cookbook is
  -- docs-start: signals
  signal clk : std_ulogic := '0';
  signal in_data, out_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal in_dv, in_er, out_dv, out_er : std_ulogic := '0';
  -- docs-end: signals

  -- docs-start: handles
  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
  -- docs-end: handles
  constant subscriber : actor_t := new_actor("tb_cookbook:subscriber");

  -- docs-start: frame
  -- A 60 octet frame: destination, source, EtherType and a payload of ones
  constant frame : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5" & (0 to 8 * 46 - 1 => '1');
  -- docs-end: frame
begin
  clk <= not clk after 4 ns;

  main : process
    -- docs-start: variables
    variable statistics : ethernet_statistics_t;
    variable count : natural;
    variable msg : msg_t;
    variable received : std_ulogic_vector(0 to 8 * 1518 - 1);
    variable length : natural;
    variable fcs_ok : boolean;
    constant frame_sizes : integer_vector := (60, 100, 1514);
    -- docs-end: variables

    -- docs-start: wait-helper
    procedure wait_until_idle is
    begin
      wait_until_idle(net, as_sync(source));
      wait_until_idle(net, as_sync(monitor));
    end;
    -- docs-end: wait-helper
  begin
    -- docs-start: test-structure
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_send_and_check_a_frame") then
        -- docs-end: test-structure
        -- docs-start: send-frame
        check_ethernet_frame(net, monitor, frame, blocking => false);
        push_ethernet_frame(net, source, frame);
        wait_until_idle;
        -- docs-end: send-frame

      elsif run("test_send_header_fields") then
        -- docs-start: header-fields
        check_ethernet_frame(net, monitor, frame, blocking => false);
        push_ethernet_frame(net, source, x"020000000001", x"020000000002", x"88B5", (0 to 8 * 46 - 1 => '1'));
        wait_until_idle;
        -- docs-end: header-fields

      elsif run("test_blocking_check") then
        -- docs-start: blocking-check
        push_ethernet_frame(net, source, frame);
        check_ethernet_frame(net, monitor, frame);  -- returns when the frame has been received
        -- docs-end: blocking-check

      elsif run("test_count_a_malformed_frame") then
        -- docs-start: malformed-frame
        -- The error is expected: count it instead of stopping the test
        disable_stop(get_logger(get_protocol_checker(monitor)), error);
        push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));
        wait_until_idle;
        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 1);
        -- An error left uncounted still fails the test at cleanup
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);
        -- docs-end: malformed-frame

      elsif run("test_count_a_mismatched_frame") then
        -- docs-start: mismatched-frame
        -- The monitor itself reports a frame that differs from the expected one
        disable_stop(get_logger(monitor), error);
        check_ethernet_frame(net, monitor, frame(0 to 8 * 59 - 1) & x"00", blocking => false);
        push_ethernet_frame(net, source, frame);
        wait_until_idle;
        get_check_count(net, monitor, eth_scoreboard, count);
        check_equal(count, 1);
        reset_log_count(get_logger(monitor), error);
        -- docs-end: mismatched-frame

      elsif run("test_disable_a_check") then
        -- docs-start: disable-check
        set_check_enabled(net, monitor, eth_fcs, false);
        push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));
        wait_until_idle;
        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 0);
        -- docs-end: disable-check

      elsif run("test_send_a_packet_from_python") then
        -- docs-start: packet
        push_ethernet_packet(
          net, source, "cookbook_traffic:udp_to_dut",
          kwarg("port", 1234) & kwarg("size", 64) & kwarg_text("label", "first frame")
        );
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        -- docs-end: packet

      elsif run("test_send_a_seeded_sequence") then
        -- docs-start: sequence
        -- The same function, arguments and seed give the same frames on both sides
        check_ethernet_sequence(net, monitor, "cookbook_traffic:random_frames", count => 20, seed => get_string_seed(runner_cfg));
        push_ethernet_sequence(net, source, "cookbook_traffic:random_frames", count => 20, seed => get_string_seed(runner_cfg));
        wait_until_idle;
        -- docs-end: sequence

      elsif run("test_pop_received_frames") then
        -- docs-start: pop-frame
        push_ethernet_frame(net, source, frame);
        pop_ethernet_frame(net, monitor, received, length, fcs_ok);
        check_equal(length, 60);
        check_true(fcs_ok);
        check_equal(received(0 to 8 * length - 1), frame);
        -- docs-end: pop-frame

      elsif run("test_subscribe_to_frames") then
        -- docs-start: subscribe
        subscribe(subscriber, get_actor(monitor));
        push_ethernet_frame(net, source, frame);
        receive(net, subscriber, msg);
        pop_ethernet_frame(msg, received, length, fcs_ok);
        check_equal(length, 60);
        unsubscribe(subscriber, get_actor(monitor));
        -- docs-end: subscribe

      elsif run("test_statistics") then
        -- docs-start: statistics
        push_ethernet_frame(net, source, frame);
        push_ethernet_frame(net, source, frame);
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2);
        log_statistics(net, monitor);  -- a readable summary in the log
        -- docs-end: statistics

      elsif run("test_capture_to_pcapng") then
        -- docs-start: capture
        start_capture(net, monitor, output_path(runner_cfg) & "frames.pcapng");
        push_ethernet_frame(net, source, frame);
        wait_until_idle;
        stop_capture(net, monitor);  -- open frames.pcapng in Wireshark
        -- docs-end: capture

      elsif run("test_call_a_python_function") then
        -- docs-start: call-python
        import_module_from_file(tb_path(runner_cfg) & "python/cookbook_model.py", "cookbook_model");
        check(call_integer_vector("cookbook_model.gain_table", kwarg("length", 4)) = integer_vector'(0, 1, 4, 9));
        -- docs-end: call-python

      elsif run("test_python_reference_model") then
        -- docs-start: reference-model
        import_module_from_file(tb_path(runner_cfg) & "python/cookbook_model.py", "cookbook_model");
        for idx in frame_sizes'range loop
          push_ethernet_frame(net, source, frame(0 to 111) & (0 to 8 * (frame_sizes(idx) - 14) - 1 => '1'));
        end loop;
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        -- The Python model predicts what the monitor must count
        check_equal(statistics.payload_octets, call("cookbook_model.expected_payload_octets", arg(frame_sizes)));
        -- docs-end: reference-model

      elsif run("test_count_errors_from_a_python_subscriber") then
        -- docs-start: python-subscriber-errors
        -- python/cookbook_subscriber.py runs in the monitor's Python session
        exec_file(tb_path(runner_cfg) & "python/cookbook_subscriber.py", new_session(get_id(monitor)));
        disable_stop(get_logger(monitor), error);
        push_ethernet_frame(net, source, frame);
        push_ethernet_frame(net, source, frame & (0 to 8 * 100 - 1 => '0'));
        wait_until_idle;
        get_check_count(net, monitor, eth_scoreboard, count);
        check_equal(count, 1, "the subscriber reported the long frame");
        reset_log_count(get_logger(monitor), error);
        -- docs-end: python-subscriber-errors

      elsif run("test_reset_a_source") then
        -- docs-start: reset
        push_ethernet_frame(net, source, frame & (0 to 8 * 1000 - 1 => '0'));
        wait until rising_edge(clk) and in_dv = '1';
        -- Abort the frame on the wire and forget it on the receiving side
        reset(net, source);
        reset(net, monitor);
        reset(net, get_protocol_checker(monitor));
        check_ethernet_frame(net, monitor, frame, blocking => false);
        push_ethernet_frame(net, source, frame);
        wait_until_idle;
        -- docs-end: reset
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);

  -- docs-start: instances
  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (source)
    port map (clk, in_data, in_dv, in_er);

  -- The design under test: one register stage
  out_data <= in_data when rising_edge(clk);
  out_dv <= in_dv when rising_edge(clk);
  out_er <= in_er when rising_edge(clk);

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (monitor)
    port map (clk, out_data, out_dv, out_er);
  -- docs-end: instances
end architecture;
