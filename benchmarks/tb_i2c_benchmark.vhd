-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Cost of the I2C target's bridge call per byte, and of a monitor: a master
-- reads num_reads times 2048 bytes in Fast-mode Plus from a target, or from
-- an empty bus that reads 0xFF, with or without a monitor. The cost of the
-- target per byte is (target - empty bus) / bytes of wall clock time.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_benchmark is
  generic (
    runner_cfg : string;
    config_name : string;
    num_reads : positive := 16;
    with_target : boolean := true;
    with_monitor : boolean := false);
end entity;

architecture tb of tb_i2c_benchmark is

  constant master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode_plus);
  constant target : i2c_target_t := new_i2c_target(address => 16#50#, model => "device");
  constant monitor : i2c_monitor_t := new_i2c_monitor;

  constant num_bytes : positive := 2048;

  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

  -- The operations of the read: every byte acknowledged but the last
  function read_ops return string is

    variable result : string(1 to 7 + 2 * (num_bytes - 1) + 5);
  begin

    result(1 to 7) := "S 0xA1 ";
    for idx in 0 to num_bytes - 2 loop

      result(8 + 2 * idx to 9 + 2 * idx) := "R ";
    end loop;

    result(result'high - 4 to result'high) := "RN P ";
    return result;
  end;

begin

  scl <= 'H';
  sda <= 'H';

  master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => master
    )
    port map (
      scl => scl,
      sda => sda
    );

  target_gen : if with_target generate
    target_inst : entity awesome_vunit_vcs.i2c_target
      generic map (
        target => target
      )
      port map (
        scl => scl,
        sda => sda
      );

  end generate target_gen;

  monitor_gen : if with_monitor generate
    monitor_inst : entity awesome_vunit_vcs.i2c_monitor
      generic map (
        monitor => monitor
      )
      port map (
        scl => scl,
        sda => sda
      );

  end generate monitor_gen;

  main : process

    variable result : i2c_result_t;

  begin

    test_runner_setup(runner, runner_cfg);
    for idx in 1 to num_reads loop

      i2c_transfer(net, master, read_ops, result);
      check_equal(length(result.data), num_bytes, "bytes read");
      deallocate(result.data);
      deallocate(result.acks);
    end loop;

    info("BENCHMARK " & config_name & " bytes=" & to_string(num_reads * num_bytes) & " sim=" & to_string(now));
    test_runner_cleanup(runner);
  end process;

end architecture;
