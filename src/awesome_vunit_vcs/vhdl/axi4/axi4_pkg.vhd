-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Types shared by the AXI4 verification components: the widths of an
-- interface, the checks, and the sampling of the five channels.
--
-- The AXI4 VCs are thin and strictly passive frontends. On every rising edge
-- of ACLK they record the channels whose VALID is 1, whose VALID changed, or
-- whose VALID or READY is a metavalue, and changes of ARESETn and of the
-- clock period. Every decision about what the records mean is made by their
-- Python backends (awesome_vunit_vcs.axi4); the record layout is described in
-- awesome_vunit_vcs/axi4/bus.py.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.vc_python_pkg.all;

package axi4_pkg is

  -- The widths of an AXI4 or AXI4-Lite interface, created with
  -- :vhdl:`axi4_pkg.new_axi4_bus`
  type axi4_bus_t is record
    -- Private. Use the constructor and the accessors below.
    p_data_length    : natural;
    p_address_length : natural;
    p_id_length      : natural;
    p_awuser_length  : natural;
    p_wuser_length   : natural;
    p_buser_length   : natural;
    p_aruser_length  : natural;
    p_ruser_length   : natural;
    p_lite           : boolean;
  end record;

  -- An interface with the widths in bits of WDATA and RDATA (a power of 2
  -- from 8 to 1024; 32 or 64 for AXI4-Lite), of AWADDR and ARADDR (1 to 64),
  -- of the ID signals (0 to 31, 0 without IDs) and of the USER signals (0
  -- when absent). ``lite`` makes it AXI4-Lite: every transaction is one beat
  -- of the full data width with ID 0, and the signals AXI4-Lite does not have
  -- are ignored.
  function new_axi4_bus (
    data_length : positive := 32;
    address_length : positive := 32;
    id_length : natural := 0;
    awuser_length : natural := 0;
    wuser_length : natural := 0;
    buser_length : natural := 0;
    aruser_length : natural := 0;
    ruser_length : natural := 0;
    lite : boolean := false
  ) return axi4_bus_t;

  -- A 32-bit AXI4 interface with 32-bit addresses, without IDs and USER
  -- signals; the default bus of
  -- :vhdl:`axi4_protocol_checker_pkg.new_axi4_protocol_checker`
  constant default_axi4_bus : axi4_bus_t := (
    p_data_length => 32,
    p_address_length => 32,
    p_id_length => 0,
    p_awuser_length => 0,
    p_wuser_length => 0,
    p_buser_length => 0,
    p_aruser_length => 0,
    p_ruser_length => 0,
    p_lite => false
  );

  -- The widths in bits of the signals of an interface; ``byte_lanes`` is
  -- the width of WSTRB
  function data_length (axi4_bus : axi4_bus_t) return natural;
  function address_length (axi4_bus : axi4_bus_t) return natural;
  function id_length (axi4_bus : axi4_bus_t) return natural;
  function awuser_length (axi4_bus : axi4_bus_t) return natural;
  function wuser_length (axi4_bus : axi4_bus_t) return natural;
  function buser_length (axi4_bus : axi4_bus_t) return natural;
  function aruser_length (axi4_bus : axi4_bus_t) return natural;
  function ruser_length (axi4_bus : axi4_bus_t) return natural;
  function byte_lanes (axi4_bus : axi4_bus_t) return natural;

  -- The interface is AXI4-Lite
  function is_lite (axi4_bus : axi4_bus_t) return boolean;

  -- The AxSIZE of a beat as wide as the data bus, the default of AWSIZE and
  -- ARSIZE
  function full_size (axi4_bus : axi4_bus_t) return std_ulogic_vector;

  -- The checks of the AXI4 VCs, named like their check IDs (upper case in log
  -- messages, such as ``AXI4_WLAST``). The protocol checker runs all but
  -- ``axi4_scoreboard``, which the monitor runs.
  type axi4_check_t is (
    -- A metavalue on VALID, READY or ARESETn, on the payload of a channel
    -- while VALID is 1, or on a data byte lane that carries data
    axi4_metavalue,
    -- VALID is 1 while ARESETn is 0, or at the first rising edge after reset
    axi4_reset_valid,
    -- The payload of a channel changed while VALID was 1 and READY 0
    axi4_stable,
    -- VALID fell before READY accepted the payload
    axi4_valid_drop,
    -- AxBURST is the reserved value 0b11
    axi4_burst_type,
    -- An INCR burst crosses a 4 KB boundary
    axi4_burst_4k,
    -- A WRAP burst is not 2, 4, 8 or 16 beats long
    axi4_wrap_len,
    -- The start address of a WRAP burst is not aligned to the size of a beat
    axi4_wrap_align,
    -- A FIXED burst is longer than 16 beats
    axi4_len_fixed,
    -- A beat is wider than the data bus
    axi4_size,
    -- AxCACHE has allocate bits set on a non-modifiable transaction
    axi4_cache,
    -- An exclusive access breaks the exclusive access rules, or an EXOKAY
    -- response to a normal access
    axi4_excl,
    -- WLAST is 1 on a beat that is not the last of its burst, or 0 on the last
    axi4_wlast,
    -- RLAST is 1 on a beat that is not the last of its burst, or 0 on the last
    axi4_rlast,
    -- WSTRB is 1 for a byte lane outside the lanes of the beat
    axi4_wstrb,
    -- A write response or read data without an outstanding transaction with its ID
    axi4_unexpected_resp,
    -- A transaction without its response, write data without its address,
    -- or VALID without READY, for longer than the timeout
    axi4_timeout,
    -- A transaction differs from the expected one, an expected transaction
    -- never came, or a read returned data the shadow memory does not allow
    axi4_scoreboard
  );

  -- Private. The five channels, in the order of their codes in the sample words
  type axi4_channel_t is (axi4_aw, axi4_w, axi4_b, axi4_ar, axi4_r);

  -- Private. The previous VALID of each channel, ARESETn and clock edge,
  -- for deciding what to record
  type axi4_sampler_t is record
    p_previous_valid  : std_ulogic_vector(0 to 4);
    p_previous_resetn : std_ulogic;
    p_started         : boolean;
    p_last_edge       : time;
    p_period          : time;
  end record;

  -- Private. A sampler before the first edge
  constant new_axi4_sampler : axi4_sampler_t :=
    (p_previous_valid => "00000", p_previous_resetn => '1', p_started => false, p_last_edge => 0 fs, p_period => 0 fs);

  -- Private. At a rising edge of ACLK: record the clock period when it
  -- changed and ARESETn when it changed
  procedure record_axi4_clock (
    variable batch : inout sample_batch_t;
    variable sampler : inout axi4_sampler_t;
    aresetn : std_ulogic
  );

  -- Private. At a rising edge of ACLK: record a channel when VALID is 1 or
  -- changed, or VALID or READY is a metavalue. ``payload`` holds the fields
  -- of the channel, the first field in the rightmost bits.
  procedure record_axi4_channel (
    variable batch : inout sample_batch_t;
    variable sampler : inout axi4_sampler_t;
    channel : axi4_channel_t;
    valid, ready, aresetn : std_ulogic;
    payload_metavalue : boolean;
    payload : std_ulogic_vector
  );

  -- Private. A tick record, for a backend that must learn the time
  procedure record_axi4_tick (variable batch : inout sample_batch_t; aresetn : std_ulogic);

  -- Private. One bit per byte lane of data, rightmost lane first: 1 for a
  -- lane with a metavalue
  function lane_metavalues (data : std_ulogic_vector) return std_ulogic_vector;

  -- Private. The widths of an interface as keyword arguments of a backend
  impure function backend_bus_arguments (axi4_bus : axi4_bus_t) return arg_t;

  -- Private. A time the backend sends as the halves hi * 2**30 fs + lo fs
  function axi4_time (hi, lo : natural) return time;

  -- Private. The logger and checker of errors in the constructors, such as an
  -- id that already has an actor
  constant axi4_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:axi4_pkg");
  constant axi4_pkg_checker : checker_t := new_checker(axi4_pkg_logger);

  -- Private. A new actor for id, or an anonymous one after a check failure
  -- when id already has an actor
  impure function new_axi4_actor (id : id_t) return actor_t;

  -- Private. A message type no handler took: a check failure ``Got unexpected
  -- message <name>`` on checker unless policy is ignore or the message was
  -- already handled, like vc_pkg.unexpected_msg_type of VUnit
  procedure axi4_unexpected_msg_type (
    msg_type : msg_type_t;
    policy : unexpected_msg_type_policy_t;
    checker : checker_t
  );
end package;

package body axi4_pkg is

  constant control_kind : natural := 5;

  function new_axi4_bus (
    data_length : positive := 32;
    address_length : positive := 32;
    id_length : natural := 0;
    awuser_length : natural := 0;
    wuser_length : natural := 0;
    buser_length : natural := 0;
    aruser_length : natural := 0;
    ruser_length : natural := 0;
    lite : boolean := false
  ) return axi4_bus_t is

    variable width : natural := 8;
  begin

    while width < data_length loop

      width := 2 * width;
    end loop;

    assert width = data_length and data_length <= 1024
      report "The AXI4 data length " & integer'image(data_length) & " is not a power of 2 from 8 to 1024"
      severity failure;
    assert not lite or data_length = 32 or data_length = 64
      report "AXI4-Lite has a data length of 32 or 64, not " & integer'image(data_length)
      severity failure;
    assert address_length <= 64
      report "The AXI4 address length " & integer'image(address_length) & " is more than 64"
      severity failure;
    assert id_length <= 31
      report "The AXI4 ID length " & integer'image(id_length) & " is more than 31"
      severity failure;
    return (
      p_data_length => data_length,
      p_address_length => address_length,
      p_id_length => id_length,
      p_awuser_length => awuser_length,
      p_wuser_length => wuser_length,
      p_buser_length => buser_length,
      p_aruser_length => aruser_length,
      p_ruser_length => ruser_length,
      p_lite => lite
    );
  end;

  function data_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_data_length;
  end;

  function address_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_address_length;
  end;

  function id_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_id_length;
  end;

  function awuser_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_awuser_length;
  end;

  function wuser_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_wuser_length;
  end;

  function buser_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_buser_length;
  end;

  function aruser_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_aruser_length;
  end;

  function ruser_length (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_ruser_length;
  end;

  function byte_lanes (axi4_bus : axi4_bus_t) return natural is
  begin

    return axi4_bus.p_data_length / 8;
  end;

  function is_lite (axi4_bus : axi4_bus_t) return boolean is
  begin

    return axi4_bus.p_lite;
  end;

  function full_size (axi4_bus : axi4_bus_t) return std_ulogic_vector is

    variable size : natural := 0;
  begin

    while 2 ** size < byte_lanes(axi4_bus) loop

      size := size + 1;
    end loop;

    return std_ulogic_vector(to_unsigned(size, 3));
  end;

  function header (
    kind : natural;
    valid, ready, aresetn : std_ulogic;
    payload_metavalue : boolean;
    control : natural
  ) return natural is

    variable result : natural := kind + 1024 * control;
  begin

    if to_x01(valid) = '1' then
      result := result + 8;
    end if;
    if to_x01(ready) = '1' then
      result := result + 16;
    end if;
    if is_x(valid) then
      result := result + 32;
    end if;
    if is_x(ready) then
      result := result + 64;
    end if;
    if payload_metavalue then
      result := result + 128;
    end if;
    if to_x01(aresetn) = '1' then
      result := result + 256;
    end if;
    if is_x(aresetn) then
      result := result + 512;
    end if;
    return result;
  end;

  procedure record_axi4_clock (
    variable batch : inout sample_batch_t;
    variable sampler : inout axi4_sampler_t;
    aresetn : std_ulogic
  ) is
  begin

    if sampler.p_started and now - sampler.p_last_edge /= sampler.p_period then
      sampler.p_period := now - sampler.p_last_edge;
      record_sample(batch, header(control_kind, '0', '0', aresetn, false, 1));
      record_sample(batch, sampler.p_period / 1 ps);
    end if;
    sampler.p_started := true;
    sampler.p_last_edge := now;
    if to_x01(aresetn) /= sampler.p_previous_resetn then
      record_sample(batch, header(control_kind, '0', '0', aresetn, false, 0));
      sampler.p_previous_resetn := to_x01(aresetn);
    end if;
  end;

  procedure record_axi4_tick (variable batch : inout sample_batch_t; aresetn : std_ulogic) is
  begin

    record_sample(batch, header(control_kind, '0', '0', aresetn, false, 2));
  end;

  procedure record_axi4_channel (
    variable batch : inout sample_batch_t;
    variable sampler : inout axi4_sampler_t;
    channel : axi4_channel_t;
    valid, ready, aresetn : std_ulogic;
    payload_metavalue : boolean;
    payload : std_ulogic_vector
  ) is

    constant code : natural := axi4_channel_t'pos(channel);
    alias bits : std_ulogic_vector(payload'length - 1 downto 0) is payload;
    variable word : std_ulogic_vector(31 downto 0);
  begin

    if to_x01(valid) = '1' or to_x01(valid) /= sampler.p_previous_valid(code) or is_x(valid) or is_x(ready) then
      record_sample(batch, header(code, valid, ready, aresetn, payload_metavalue, 0));
      for word_idx in 0 to (bits'length + 31) / 32 - 1 loop

        word := (others => '0');
        for bit_idx in 0 to 31 loop

          exit when 32 * word_idx + bit_idx >= bits'length;
          if to_x01(bits(32 * word_idx + bit_idx)) = '1' then
            word(bit_idx) := '1';
          end if;
        end loop;

        record_sample(batch, to_integer(signed(word)));
      end loop;

    end if;
    sampler.p_previous_valid(code) := to_x01(valid);
  end;

  function lane_metavalues (data : std_ulogic_vector) return std_ulogic_vector is

    alias bits : std_ulogic_vector(data'length - 1 downto 0) is data;
    variable result : std_ulogic_vector(data'length / 8 - 1 downto 0) := (others => '0');
  begin

    for lane in result'range loop

      if is_x(bits(8 * lane + 7 downto 8 * lane)) then
        result(lane) := '1';
      end if;
    end loop;

    return result;
  end;

  impure function backend_bus_arguments (axi4_bus : axi4_bus_t) return arg_t is
  begin

    return kwarg("data_width", axi4_bus.p_data_length)
           & kwarg("address_width", axi4_bus.p_address_length)
           & kwarg("id_width", axi4_bus.p_id_length)
           & kwarg("awuser_width", axi4_bus.p_awuser_length)
           & kwarg("wuser_width", axi4_bus.p_wuser_length)
           & kwarg("buser_width", axi4_bus.p_buser_length)
           & kwarg("aruser_width", axi4_bus.p_aruser_length)
           & kwarg("ruser_width", axi4_bus.p_ruser_length)
           & kwarg("lite", axi4_bus.p_lite);
  end;

  function axi4_time (hi, lo : natural) return time is
  begin

    return hi * 1073741824 fs + lo * 1 fs;
  end;

  impure function new_axi4_actor (id : id_t) return actor_t is
  begin

    if find(id, enable_deferred_creation => false) /= null_actor then
      check_failed(axi4_pkg_checker, "An actor already exists for " & full_name(id) & ".");
      return new_actor;
    end if;
    return new_actor(id);
  end;

  procedure axi4_unexpected_msg_type (
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
