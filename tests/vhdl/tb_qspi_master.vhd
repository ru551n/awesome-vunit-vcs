-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- QSPI master verification component.
--
-- The far end here is a deliberately dumb stub slave written inside this file,
-- not the flash device model: the point is to prove that the master puts the
-- right bits on the right wires at the right times, which a model that also
-- decides what those bits mean would only obscure. The stub is told the shape
-- of each transaction up front through slave_cfg (how many bytes at how many
-- lanes in each phase, how many dummy cycles, how many bytes to send back),
-- counts SCK edges to stay in lockstep, pushes every byte it receives into
-- rx_queue and drives back whatever the test put into tx_queue. Because the
-- stub counts edges rather than decoding a command, a master that emitted the
-- wrong number of dummy cycles would slide the whole read phase and corrupt
-- the data -- which is exactly the check we want.
--
-- Bit-order claims are not checked through the same helper functions the
-- master uses, which would be circular. A separate recorder process samples
-- the resolved four-wire bus and the master's own output enables at every
-- rising edge while CS is low, and the bit-order tests compare that raw trace
-- against sequences worked out by hand from the byte values.
--
-- Every test runs once at each SCK period in periods, switched at run time
-- with set_sck_period, so the whole suite is proven at more than one bus
-- speed without testbench configurations.
--
-- Covered: MSB-first byte serialization at x1, x2 and x4; the x1 MOSI/MISO
-- lane split; dummy cycles (exact count, master tri-stated throughout); CS
-- framing (SCK low at every CS edge, IOs released while CS is high, a CS-high
-- gap between transactions); read-data capture at every lane width; mixed
-- lane widths within one transaction; the run-time SCK-period setter; and
-- sync_pkg's wait_until_idle against a batch of queued transactions.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_qspi_master is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_qspi_master is
  -- The SCK periods every test runs at
  constant periods : time_vector := (20 ns, 33 ns);

  constant master : qspi_master_t := new_qspi_master(sck_period => periods(periods'low));

  signal m2s : qspi_m2s_t := qspi_m2s_init;
  signal s2m : qspi_s2m_t := qspi_s2m_init;

  -- The resolved four wires, as a probe on the board would see them.
  signal io : qspi_io_t := (others => 'Z');

  -- The SCK period the master was last switched to, for the CS framing check
  signal sck_period_in_use : delay_length := periods(periods'low);

  -- Shape of the transaction the stub slave should expect next. Set by the
  -- test process before the transaction is issued.
  type slave_cfg_t is record
    cmd_bytes : natural;
    cmd_lanes : lane_count_t;
    addr_bytes : natural;
    addr_lanes : lane_count_t;
    wr_bytes : natural;
    wr_lanes : lane_count_t;
    dummy_cycles : natural;
    rd_bytes : natural;
    rd_lanes : lane_count_t;
  end record;

  constant slave_cfg_init : slave_cfg_t := (
    cmd_bytes => 0,
    cmd_lanes => 1,
    addr_bytes => 0,
    addr_lanes => 1,
    wr_bytes => 0,
    wr_lanes => 1,
    dummy_cycles => 0,
    rd_bytes => 0,
    rd_lanes => 1
  );

  signal slave_cfg : slave_cfg_t := slave_cfg_init;

  -- Bytes the stub slave received, and bytes it should send back.
  constant rx_queue : queue_t := new_queue;
  constant tx_queue : queue_t := new_queue;

  -- Raw bus trace, one entry per queue per rising SCK edge while CS is low.
  constant io_queue : queue_t := new_queue;
  constant oe_queue : queue_t := new_queue;

  signal cs_assert_count : natural := 0;
  -- The time CS last rose
  signal cs_rise_time : time := 0 fs;

  -- The length of the read a reset aborts
  constant long_read_bytes : positive := 4096;

  impure function to_byte_array(values : integer_vector) return integer_array_t is
    variable result : integer_array_t := new_1d(length => values'length, bit_width => 8, is_signed => false);
  begin
    for index in 0 to values'length - 1 loop
      set(result, index, values(values'low + index));
    end loop;

    return result;
  end;
begin
  io <= qspi_io_value(m2s, s2m);

  -- Raw bus trace. Independent of every qspi_pkg helper, so the bit-order
  -- tests below are a real check rather than a tautology.
  record_bus : process
  begin
    wait until rising_edge(m2s.sck);

    if m2s.cs_n = '0' then
      push_integer(io_queue, qspi_to_natural(io));
      push_integer(oe_queue, qspi_to_natural(m2s.io.enable));
    end if;
  end process;

  -- Chip-select framing, checked continuously rather than per test.
  check_cs_framing : process
    variable last_rise : delay_length := 0 fs;
  begin
    wait on m2s.cs_n;

    check(m2s.sck = '0', "SCK must be low whenever CS changes");

    if m2s.cs_n = '0' then
      cs_assert_count <= cs_assert_count + 1;
      if last_rise /= 0 fs then
        check(
          now - last_rise >= sck_period_in_use,
          "CS must stay high for at least one SCK period between transactions"
        );
      end if;
    else
      check_equal(qspi_to_natural(m2s.io.enable), 0, "Master must release the IOs when CS goes high");
      last_rise := now;
      cs_rise_time <= now;
    end if;
  end process;

  -- Stub slave. Counts SCK edges through the phase shape it was given, and
  -- gives up on the transaction when CS rises early, as after a reset.
  stub_slave : process
    variable cfg : slave_cfg_t;
    variable byte : std_ulogic_vector(7 downto 0);
    -- CS is still low
    variable selected : boolean;

    procedure wait_for_sck(rising : boolean) is
    begin
      if rising then
        wait until rising_edge(m2s.sck) or m2s.cs_n = '1';
      else
        wait until falling_edge(m2s.sck) or m2s.cs_n = '1';
      end if;
      selected := m2s.cs_n = '0';
    end;

    procedure receive_phase(num_bytes : natural; lanes : lane_count_t) is
    begin
      for index in 0 to num_bytes - 1 loop
        byte := (others => '0');
        for beat in 0 to qspi_beats_per_byte(lanes) - 1 loop
          exit when not selected;
          wait_for_sck(rising => true);
          exit when not selected;
          byte := qspi_byte_insert(byte, lanes, beat, qspi_sample_beat(io, lanes, qspi_master_side));
        end loop;
        exit when not selected;
        push_integer(rx_queue, qspi_to_natural(byte));
      end loop;
    end;
  begin
    s2m.io <= qspi_drive_init;

    wait until falling_edge(m2s.cs_n);
    cfg := slave_cfg;
    selected := true;

    receive_phase(cfg.cmd_bytes, cfg.cmd_lanes);
    receive_phase(cfg.addr_bytes, cfg.addr_lanes);
    receive_phase(cfg.wr_bytes, cfg.wr_lanes);

    for cycle in 1 to cfg.dummy_cycles loop
      exit when not selected;
      wait_for_sck(rising => true);
      exit when not selected;
      check_equal(qspi_to_natural(m2s.io.enable), 0, "Master must tri-state every IO during a dummy cycle");
    end loop;

    -- Drive each read beat on the falling edge before the rising edge the
    -- master samples it on, as a real device clocking out on CPOL=0 does.
    for index in 0 to cfg.rd_bytes - 1 loop
      exit when not selected;
      byte := qspi_to_byte(pop_integer(tx_queue));
      for beat in 0 to qspi_beats_per_byte(cfg.rd_lanes) - 1 loop
        wait_for_sck(rising => false);
        exit when not selected;
        s2m.io <= qspi_drive_beat(byte, cfg.rd_lanes, beat, qspi_slave_side);
      end loop;
    end loop;

    if m2s.cs_n = '0' then
      wait until rising_edge(m2s.cs_n);
    end if;
    s2m.io <= qspi_drive_init;
  end process;

  main : process
    -- 0xB2 = 1011_0010 and 0x1F = 0001_1111, the two bytes every bit-order
    -- test sends. Neither is a palindrome under bit reversal (0xB2 reverses to
    -- 0x4D, 0x1F to 0xF8), so an LSB-first master cannot pass by accident --
    -- which 0xA5 and 0x3C, tempting as they look, would have let it do.
    constant pattern : integer_vector(0 to 1) := (16#B2#, 16#1F#);

    variable period : delay_length;
    variable cmd, data, read_data : integer_array_t := null_integer_array;
    variable reference : qspi_transfer_reference_t;
    variable references : msg_vec_t(0 to 2);
    variable status : natural;
    variable timestamp : delay_length;
    variable reset_time : time;
    variable assertions_before : natural;

    -- A check message naming the SCK period of the current run
    impure function at_period(context_msg : string) return string is
    begin
      return context_msg & " (SCK period " & to_string(period) & ")";
    end;

    -- Switch the master, and the CS framing check, to the next SCK period
    procedure use_sck_period(period_idx : natural) is
    begin
      period := periods(period_idx);
      set_sck_period(net, master, period);
      sck_period_in_use <= period;
      wait for 0 ns;
    end;

    -- Deallocate the arrays a run allocated
    procedure free_arrays is
    begin
      if not is_null(cmd) then
        deallocate(cmd);
      end if;
      if not is_null(read_data) then
        deallocate(read_data);
      end if;
    end;

    -- Tell the stub slave what the next transaction looks like.
    procedure configure_slave(
      cmd_bytes : natural := 0;
      cmd_lanes : lane_count_t := 1;
      addr_bytes : natural := 0;
      addr_lanes : lane_count_t := 1;
      wr_bytes : natural := 0;
      wr_lanes : lane_count_t := 1;
      dummy_cycles : natural := 0;
      rd_bytes : natural := 0;
      rd_lanes : lane_count_t := 1
    ) is
    begin
      slave_cfg <= (
        cmd_bytes => cmd_bytes,
        cmd_lanes => cmd_lanes,
        addr_bytes => addr_bytes,
        addr_lanes => addr_lanes,
        wr_bytes => wr_bytes,
        wr_lanes => wr_lanes,
        dummy_cycles => dummy_cycles,
        rd_bytes => rd_bytes,
        rd_lanes => rd_lanes
      );
      -- Let the stub see it before the VC pulls CS low.
      wait for 0 ns;
    end;

    procedure load_tx(values : integer_vector) is
    begin
      for index in values'range loop
        push_integer(tx_queue, values(index));
      end loop;
    end;

    -- queue_pkg's length() counts encoded bytes rather than pushed items, so
    -- everything below counts by draining instead.
    procedure drain_trace(variable count : out natural) is
      variable drained : natural := 0;
      variable ignored : integer;
    begin
      while not is_empty(io_queue) loop
        ignored := pop_integer(io_queue);
        ignored := pop_integer(oe_queue);
        drained := drained + 1;
      end loop;

      count := drained;
    end;

    procedure check_trace_length(expected_cycles : natural; context_msg : string) is
      variable count : natural;
    begin
      drain_trace(count);
      check_equal(count, expected_cycles, at_period(context_msg & ": number of SCK cycles while CS was low"));
    end;

    -- Compare the recorded raw bus trace against a hand-derived sequence.
    procedure check_trace(expected_io : integer_vector; expected_oe : integer_vector; context_msg : string) is
      variable extra : natural;
    begin
      for index in 0 to expected_io'length - 1 loop
        check_false(
          is_empty(io_queue),
          at_period(
            context_msg & ": only " & integer'image(index) & " SCK cycles recorded, expected " &
            integer'image(expected_io'length)
          )
        );
        check_equal(
          pop_integer(io_queue),
          expected_io(expected_io'low + index),
          at_period(context_msg & ": bus value at SCK cycle " & integer'image(index))
        );
        check_equal(
          pop_integer(oe_queue),
          expected_oe(expected_oe'low + index),
          at_period(context_msg & ": master output enables at SCK cycle " & integer'image(index))
        );
      end loop;

      drain_trace(extra);
      check_equal(
        extra,
        0,
        at_period(context_msg & ": SCK cycles beyond the expected " & integer'image(expected_io'length))
      );
    end;

    procedure check_received(expected : integer_vector; context_msg : string) is
      variable extra : natural := 0;
      variable ignored : integer;
    begin
      for index in 0 to expected'length - 1 loop
        check_false(
          is_empty(rx_queue),
          at_period(
            context_msg & ": only " & integer'image(index) & " bytes received, expected " &
            integer'image(expected'length)
          )
        );
        check_equal(
          pop_integer(rx_queue),
          expected(expected'low + index),
          at_period(context_msg & ": byte " & integer'image(index))
        );
      end loop;

      while not is_empty(rx_queue) loop
        ignored := pop_integer(rx_queue);
        extra := extra + 1;
      end loop;
      check_equal(
        extra,
        0,
        at_period(context_msg & ": bytes received beyond the expected " & integer'image(expected'length))
      );
    end;

    procedure check_read_data(data : integer_array_t; expected : integer_vector; context_msg : string) is
    begin
      check_equal(length(data), expected'length, at_period(context_msg & ": number of bytes read"));

      for index in 0 to expected'length - 1 loop
        check_equal(
          get(data, index),
          expected(expected'low + index),
          at_period(context_msg & ": read byte " & integer'image(index))
        );
      end loop;
    end;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("test_command_phase_x1_is_msb_first") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 2, cmd_lanes => 1);
          cmd := to_byte_array(pattern);
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, cmd_lanes => 1);

          -- One bit per cycle on IO0, most significant first. Only IO0 is
          -- driven, so the other three wires are Hi-Z and read back as 0.
          check_trace(
            expected_io => (1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1),
            expected_oe => (
              2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#,
              2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#
            ),
            context_msg => "x1 command phase"
          );
          check_received(pattern, "x1 command phase");
          free_arrays;
        end loop;

      elsif run("test_command_phase_x2_is_msb_first") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 2, cmd_lanes => 2);
          cmd := to_byte_array(pattern);
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, cmd_lanes => 2);

          -- Two bits per cycle on IO1:IO0, most significant pair first:
          -- 0xB2 -> 10 11 00 10, 0x1F -> 00 01 11 11.
          check_trace(
            expected_io => (2#10#, 2#11#, 2#00#, 2#10#, 2#00#, 2#01#, 2#11#, 2#11#),
            expected_oe => (2#0011#, 2#0011#, 2#0011#, 2#0011#, 2#0011#, 2#0011#, 2#0011#, 2#0011#),
            context_msg => "x2 command phase"
          );
          check_received(pattern, "x2 command phase");
          free_arrays;
        end loop;

      elsif run("test_command_phase_x4_is_msb_first") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 2, cmd_lanes => 4);
          cmd := to_byte_array(pattern);
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, cmd_lanes => 4);

          -- One nibble per cycle on IO3:IO0, high nibble first.
          check_trace(
            expected_io => (2#1011#, 2#0010#, 2#0001#, 2#1111#),
            expected_oe => (2#1111#, 2#1111#, 2#1111#, 2#1111#),
            context_msg => "x4 command phase"
          );
          check_received(pattern, "x4 command phase");
          free_arrays;
        end loop;

      elsif run("test_dummy_cycles_are_counted_and_hi_z") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          -- The shape of a quad output read: opcode at x1, eight dummy cycles,
          -- two bytes at x4. The stub slave counts exactly eight dummy edges,
          -- so a wrong count would shift the read phase and corrupt the data.
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, dummy_cycles => 8, rd_bytes => 2, rd_lanes => 4);
          load_tx((16#5A#, 16#C3#));
          cmd := to_byte_array((0 => 16#6B#));
          qspi_transfer(
            net => net,
            qspi_master => master,
            cmd => cmd,
            data => read_data,
            cmd_lanes => 1,
            dummy_cycles => 8,
            num_read_bytes => 2,
            read_lanes => 4
          );

          -- 8 opcode cycles + 8 dummy + 4 read = 20, and the master drives
          -- only during the opcode: everything after it is Hi-Z on the master
          -- side.
          check_trace(
            expected_io => (
              0, 1, 1, 0, 1, 0, 1, 1,
              0, 0, 0, 0, 0, 0, 0, 0,
              2#0101#, 2#1010#, 2#1100#, 2#0011#
            ),
            expected_oe => (
              2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#,
              0, 0, 0, 0, 0, 0, 0, 0,
              0, 0, 0, 0
            ),
            context_msg => "dummy cycles"
          );
          check_received((0 => 16#6B#), "dummy cycles");
          check_read_data(read_data, (16#5A#, 16#C3#), "dummy cycles");
          free_arrays;
        end loop;

      elsif run("test_read_data_x1_uses_miso") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, rd_bytes => 2, rd_lanes => 1);
          load_tx((16#5A#, 16#C3#));
          cmd := to_byte_array((0 => 16#03#));
          qspi_transfer(
            net => net,
            qspi_master => master,
            cmd => cmd,
            data => read_data,
            cmd_lanes => 1,
            num_read_bytes => 2,
            read_lanes => 1
          );

          check_read_data(read_data, (16#5A#, 16#C3#), "x1 read");

          -- 0x03 on IO0, then 0x5A and 0xC3 on IO1 -- a single-lane read
          -- comes back on MISO, not on the wire the opcode went out on.
          check_trace(
            expected_io => (
              0, 0, 0, 0, 0, 0, 1, 1,
              0, 2, 0, 2, 2, 0, 2, 0,
              2, 2, 0, 0, 0, 0, 2, 2
            ),
            expected_oe => (
              2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#, 2#0001#,
              0, 0, 0, 0, 0, 0, 0, 0,
              0, 0, 0, 0, 0, 0, 0, 0
            ),
            context_msg => "x1 read"
          );
          free_arrays;
        end loop;

      elsif run("test_read_data_x2") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, dummy_cycles => 4, rd_bytes => 2, rd_lanes => 2);
          load_tx((16#5A#, 16#C3#));
          cmd := to_byte_array((0 => 16#3B#));
          qspi_transfer(
            net => net,
            qspi_master => master,
            cmd => cmd,
            data => read_data,
            cmd_lanes => 1,
            dummy_cycles => 4,
            num_read_bytes => 2,
            read_lanes => 2
          );

          check_read_data(read_data, (16#5A#, 16#C3#), "x2 read");
          check_received((0 => 16#3B#), "x2 read");
          check_trace_length(8 + 4 + 8, "x2 read");
          free_arrays;
        end loop;

      elsif run("test_read_data_x4") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          configure_slave(cmd_bytes => 1, cmd_lanes => 4, rd_bytes => 4, rd_lanes => 4);
          load_tx((16#00#, 16#FF#, 16#5A#, 16#C3#));
          cmd := to_byte_array((0 => 16#0B#));
          qspi_transfer(
            net => net,
            qspi_master => master,
            cmd => cmd,
            data => read_data,
            cmd_lanes => 4,
            num_read_bytes => 4,
            read_lanes => 4
          );

          check_read_data(read_data, (16#00#, 16#FF#, 16#5A#, 16#C3#), "x4 read");
          check_received((0 => 16#0B#), "x4 read");
          check_trace_length(2 + 8, "x4 read");
          free_arrays;
        end loop;

      elsif run("test_mixed_lane_phases") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          -- A 0xEB quad IO read: opcode at x1, then address plus mode byte at
          -- x4, four dummy cycles, then data at x4. Three lane widths in one
          -- frame.
          configure_slave(
            cmd_bytes => 1,
            cmd_lanes => 1,
            addr_bytes => 4,
            addr_lanes => 4,
            dummy_cycles => 4,
            rd_bytes => 3,
            rd_lanes => 4
          );
          load_tx((16#11#, 16#22#, 16#33#));

          qspi_flash_quad_io_read(
            net => net,
            qspi_master => master,
            addr => 16#123456#,
            num_bytes => 3,
            data => read_data,
            addr_bytes => 3,
            dummy_cycles => 4,
            mode_byte => 16#00#
          );

          check_received((16#EB#, 16#12#, 16#34#, 16#56#, 16#00#), "quad IO read");
          check_read_data(read_data, (16#11#, 16#22#, 16#33#), "quad IO read");

          -- 8 opcode + 8 (four bytes at x4) + 4 dummy + 6 data = 26 cycles.
          check_trace_length(26, "quad IO read");
          free_arrays;
        end loop;

      elsif run("test_cs_framing") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          assertions_before := cs_assert_count;

          configure_slave(cmd_bytes => 1, cmd_lanes => 1);
          cmd := to_byte_array((0 => 16#06#));
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, cmd_lanes => 1);

          check(m2s.cs_n = '1', at_period("CS must be high between transactions"));
          check_equal(
            qspi_to_natural(m2s.io.enable), 0, at_period("IOs must be released between transactions")
          );
          check_equal(cs_assert_count - assertions_before, 1, at_period("exactly one CS assertion so far"));

          configure_slave(cmd_bytes => 1, cmd_lanes => 1);
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, cmd_lanes => 1);

          check_equal(
            cs_assert_count - assertions_before, 2, at_period("each transaction gets its own CS assertion")
          );
          check_received((16#06#, 16#06#), "CS framing");
          drain_trace(status);
          free_arrays;
        end loop;

      elsif run("test_wait_until_idle") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          assertions_before := cs_assert_count;
          configure_slave(cmd_bytes => 1, cmd_lanes => 1);

          -- Queue three transactions without waiting for any of them, then
          -- prove wait_until_idle does not return until the bus has actually
          -- run them.
          for index in references'range loop
            cmd := to_byte_array((0 => 16#06# + index));
            qspi_transfer(
              net => net, qspi_master => master, cmd => cmd, reference => references(index), cmd_lanes => 1
            );
            deallocate(cmd);
          end loop;

          wait_until_idle(net, as_sync(master));

          check_equal(
            cs_assert_count - assertions_before, 3, at_period("wait_until_idle returned before the queue drained")
          );
          check_received((16#06#, 16#07#, 16#08#), "wait_until_idle");

          for index in references'range loop
            await_qspi_transfer_reply(net, references(index));
          end loop;
          drain_trace(status);
          free_arrays;
        end loop;

      elsif run("test_set_sck_period") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          set_sck_period(net, master, 2 * period);

          configure_slave(cmd_bytes => 1, cmd_lanes => 1);
          cmd := to_byte_array((0 => 16#9F#));
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, reference => reference, cmd_lanes => 1);

          wait until rising_edge(m2s.sck);
          timestamp := now;
          wait until rising_edge(m2s.sck);
          check_equal(now - timestamp, 2 * period, at_period("SCK period after set_sck_period"));

          await_qspi_transfer_reply(net, reference);
          check_received((0 => 16#9F#), "set_sck_period");
          drain_trace(status);
          free_arrays;
        end loop;

      elsif run("test_reset_aborts_an_in_flight_transfer") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          -- A long x1 read, reset after 100 SCK cycles
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, rd_bytes => long_read_bytes, rd_lanes => 1);
          for index in 1 to long_read_bytes loop
            push_integer(tx_queue, 16#A5#);
          end loop;
          cmd := to_byte_array((0 => 16#03#));
          qspi_transfer(
            net => net,
            qspi_master => master,
            cmd => cmd,
            reference => reference,
            num_read_bytes => long_read_bytes
          );
          for cycle in 1 to 100 loop
            wait until rising_edge(m2s.sck);
          end loop;

          reset_time := now;
          reset(net, master);
          check(m2s.cs_n = '1', at_period("CS is high after the reset"));
          check(m2s.sck = '0', at_period("SCK is idle after the reset"));
          check_equal(qspi_to_natural(m2s.io.enable), 0, at_period("IOs are released after the reset"));
          check(cs_rise_time >= reset_time, at_period("CS rose at the reset"));
          check(
            cs_rise_time - reset_time <= period,
            at_period("CS rose " & to_string(cs_rise_time - reset_time) & " after the reset")
          );

          -- The caller of the aborted transfer gets the whole bytes read
          await_qspi_transfer_reply(net, reference, read_data);
          check(length(read_data) < long_read_bytes, at_period("the aborted read returns fewer bytes"));
          for index in 0 to length(read_data) - 1 loop
            check_equal(get(read_data, index), 16#A5#, at_period("byte " & to_string(index) & " of the aborted read"));
          end loop;
          flush(tx_queue);
          flush(rx_queue);
          drain_trace(status);
          free_arrays;

          -- The next transfer runs normally
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, rd_bytes => 2, rd_lanes => 1);
          load_tx((16#5A#, 16#C3#));
          cmd := to_byte_array((0 => 16#03#));
          qspi_transfer(net => net, qspi_master => master, cmd => cmd, data => read_data, num_read_bytes => 2);
          check_received((0 => 16#03#), "transfer after a reset");
          check_read_data(read_data, (16#5A#, 16#C3#), "transfer after a reset");
          drain_trace(status);
          free_arrays;
        end loop;

      elsif run("test_flash_command_layer") then
        for period_idx in periods'range loop
          use_sck_period(period_idx);
          -- 0x9F, three ID bytes at x1.
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, rd_bytes => 3, rd_lanes => 1);
          load_tx((16#EF#, 16#40#, 16#18#));
          qspi_flash_read_id(net, master, read_data, num_bytes => 3);
          check_received((0 => 16#9F#), "read id");
          check_read_data(read_data, (16#EF#, 16#40#, 16#18#), "read id");

          -- 0x03 with a four-byte address, proving 4-byte addressing mode.
          configure_slave(
            cmd_bytes => 1, cmd_lanes => 1, addr_bytes => 4, addr_lanes => 1, rd_bytes => 1, rd_lanes => 1
          );
          load_tx((0 => 16#77#));
          qspi_flash_read(
            net => net,
            qspi_master => master,
            addr => 16#01234567#,
            num_bytes => 1,
            data => read_data,
            addr_bytes => 4
          );
          check_received((16#03#, 16#01#, 16#23#, 16#45#, 16#67#), "4-byte read");
          check_read_data(read_data, (0 => 16#77#), "4-byte read");

          -- 0x06 then 0x02 with a payload, the ordinary program sequence.
          configure_slave(cmd_bytes => 1, cmd_lanes => 1);
          qspi_flash_write_enable(net, master);
          check_received((0 => 16#06#), "write enable");

          configure_slave(
            cmd_bytes => 1, cmd_lanes => 1, addr_bytes => 3, addr_lanes => 1, wr_bytes => 3, wr_lanes => 1
          );
          data := to_byte_array((16#DE#, 16#AD#, 16#BE#));
          qspi_flash_page_program(net => net, qspi_master => master, addr => 16#00A000#, data => data, addr_bytes => 3);
          deallocate(data);
          check_received((16#02#, 16#00#, 16#A0#, 16#00#, 16#DE#, 16#AD#, 16#BE#), "page program");

          -- 0x05, one status byte.
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, rd_bytes => 1, rd_lanes => 1);
          load_tx((0 => 16#02#));
          qspi_flash_read_status(net, master, status);
          check_received((0 => 16#05#), "read status");
          check_equal(status, 16#02#, at_period("read status value"));

          -- 0x20, an erase with only an address.
          configure_slave(cmd_bytes => 1, cmd_lanes => 1, addr_bytes => 3, addr_lanes => 1);
          qspi_flash_sector_erase(net, master, addr => 16#010000#);
          check_received((16#20#, 16#01#, 16#00#, 16#00#), "sector erase");

          -- 0xFF on four lanes, the one command issued from inside QPI mode.
          configure_slave(cmd_bytes => 1, cmd_lanes => 4);
          qspi_flash_exit_qpi(net, master);
          check_received((0 => 16#FF#), "exit QPI");
          drain_trace(status);
          free_arrays;
        end loop;
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 2 ms);

  qspi_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => master
    )
    port map (
      m2s => m2s,
      s2m => s2m
    );
end architecture;
