-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Types shared by the I2C verification components: the speed modes, the
-- checks and the status of a transfer.
--
-- The I2C VCs are thin pin-level frontends. They drive SCL and SDA open drain,
-- '0' or 'Z', on resolved std_logic lines that the testbench pulls up with
-- 'H', and read them with to_x01, so 'H' is a 1. Every decision about what the
-- bits mean is made by their Python backends (awesome_vunit_vcs.i2c).

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.vc_pkg.all;

package i2c_pkg is

  -- The speed modes of UM10204, which select the timing of a master and the
  -- limits of a protocol checker: Standard-mode up to 100 kHz, Fast-mode up
  -- to 400 kHz and Fast-mode Plus up to 1 MHz
  type i2c_speed_t is (i2c_standard_mode, i2c_fast_mode, i2c_fast_mode_plus);

  -- The checks of the I2C VCs, named like their check IDs (upper case in log
  -- messages, such as ``I2C_T_LOW``). The protocol checker runs all but
  -- ``i2c_scoreboard``, which the monitor runs.
  type i2c_check_t is (
    -- Two rising SCL edges closer than 1 / fSCL max
    i2c_f_scl,
    -- A START held for less than tHD;STA before SCL fell
    i2c_t_hd_sta,
    -- SCL low for less than tLOW
    i2c_t_low,
    -- SCL high for less than tHIGH
    i2c_t_high,
    -- A repeated START less than tSU;STA after SCL rose
    i2c_t_su_sta,
    -- SDA changed less than tHD;DAT after SCL fell
    i2c_t_hd_dat,
    -- SDA changed less than tSU;DAT before SCL rose
    i2c_t_su_dat,
    -- A STOP less than tSU;STO after SCL rose
    i2c_t_su_sto,
    -- A START less than tBUF after a STOP
    i2c_t_buf,
    -- SDA changed while SCL was high inside a byte: a START or STOP after 1 to 7 bits
    i2c_sda_stable,
    -- A byte without an acknowledge bit: a START or STOP right after 8 bits
    i2c_ack_slot,
    -- A metavalue on SCL or SDA
    i2c_metavalue,
    -- SCL or SDA low for longer than the stuck-low time of the protocol checker
    i2c_stuck_low,
    -- A transfer differs from the one expected with check_i2c_transfer
    i2c_scoreboard
  );

  -- The outcome of a transfer of a master
  type i2c_status_t is (
    -- Every byte was acknowledged, and the PEC was right
    i2c_ok,
    -- An address byte was not acknowledged
    i2c_address_nack,
    -- A data byte was not acknowledged
    i2c_data_nack,
    -- The master lost arbitration to another master
    i2c_arbitration_lost,
    -- The PEC of a read was wrong
    i2c_pec_error,
    -- SCL stayed low for longer than the stretch timeout of the master
    i2c_scl_timeout
  );

  -- Private. The sample word of the monitor and the protocol checker: bit 0
  -- SCL high, bit 1 SDA high, bit 2 a metavalue on SCL, bit 3 on SDA (see
  -- awesome_vunit_vcs/i2c/bus.py)
  function i2c_sample_word (scl, sda : std_ulogic) return natural;

  -- Private. A time the backend sends as the halves hi * 2**30 fs + lo fs
  function i2c_time (hi, lo : natural) return time;

  -- Private. The bytes of a vector, leftmost byte first, for the backend
  function i2c_bytes (value : std_ulogic_vector) return integer_vector;

  -- Private. The logger and checker of errors in the constructors, such as an
  -- id that already has an actor
  constant i2c_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:i2c_pkg");
  constant i2c_pkg_checker : checker_t := new_checker(i2c_pkg_logger);

  -- Private. A new actor for id, or an anonymous one after a check failure
  -- when id already has an actor
  impure function new_i2c_actor (id : id_t) return actor_t;

  -- Private. A message type no handler took: a check failure ``Got unexpected
  -- message <name>`` on checker unless policy is ignore or the message was
  -- already handled, like vc_pkg.unexpected_msg_type of VUnit
  procedure i2c_unexpected_msg_type (msg_type : msg_type_t; policy : unexpected_msg_type_policy_t; checker : checker_t);
end package;

package body i2c_pkg is

  function i2c_sample_word (scl, sda : std_ulogic) return natural is

    variable result : natural := 0;
  begin

    if to_x01(scl) = '1' then
      result := result + 1;
    end if;
    if to_x01(sda) = '1' then
      result := result + 2;
    end if;
    if is_x(scl) then
      result := result + 4;
    end if;
    if is_x(sda) then
      result := result + 8;
    end if;
    return result;
  end;

  function i2c_time (hi, lo : natural) return time is
  begin

    return hi * 1073741824 fs + lo * 1 fs;
  end;

  function i2c_bytes (value : std_ulogic_vector) return integer_vector is

    alias normalized : std_ulogic_vector(0 to value'length - 1) is value;
    variable result : integer_vector(0 to value'length / 8 - 1);
    variable byte : natural;
  begin

    assert value'length mod 8 = 0
      report "I2C data of " & integer'image(value'length) & " bits is not a whole number of bytes"
      severity failure;
    for idx in result'range loop

      byte := 0;
      for bit_idx in 0 to 7 loop

        byte := 2 * byte;
        if to_x01(normalized(8 * idx + bit_idx)) = '1' then
          byte := byte + 1;
        end if;
      end loop;

      result(idx) := byte;
    end loop;

    return result;
  end;

  impure function new_i2c_actor (id : id_t) return actor_t is
  begin

    if find(id, enable_deferred_creation => false) /= null_actor then
      check_failed(i2c_pkg_checker, "An actor already exists for " & full_name(id) & ".");
      return new_actor;
    end if;
    return new_actor(id);
  end;

  procedure i2c_unexpected_msg_type (
    msg_type : msg_type_t;
    policy : unexpected_msg_type_policy_t;
    checker : checker_t
  ) is
  begin

    if is_already_handled(msg_type) or policy = ignore then
      null;
    else
      check_failed(checker, "Got unexpected message " & name(msg_type));
    end if;
  end;

end package body;
