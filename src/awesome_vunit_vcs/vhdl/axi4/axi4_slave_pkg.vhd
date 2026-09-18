-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the AXI4 read and write slaves
-- (axi4_read_slave.vhd, axi4_write_slave.vhd), the counterparts of VUnit's
-- axi_slave_pkg with an axi4_memory_t behind them.
--
-- A slave drives the handshakes and the timing: the address FIFO, the write
-- response FIFO, the stall probabilities and the response latency. For each
-- burst it asks its memory's Python backend (awesome_vunit_vcs.axi4.slave)
-- which bytes the beats move, whether the permissions allow them, whether
-- written bytes have their expected values and what to respond. A read slave
-- makes one bridge call per burst, at its AR handshake; a write slave two, at
-- its AW handshake and at its write response.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.axi_slave_pkg.probability_t;
  use vunit_lib.axi_statistics_pkg.all;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.queue_pkg.all;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.axi4_pkg.all;
  use work.axi4_memory_pkg.all;
  use work.vc_python_pkg.all;

package axi4_slave_pkg is

  -- Private. The configuration a slave starts with, read by the entities
  type axi4_slave_config_t is record
    address_fifo_depth               : positive;
    write_response_fifo_depth        : positive;
    check_4kbyte_boundary            : boolean;
    address_stall_probability        : probability_t;
    data_stall_probability           : probability_t;
    write_response_stall_probability : probability_t;
    min_response_latency             : delay_length;
    max_response_latency             : delay_length;
    drive_invalid                    : boolean;
    drive_invalid_val                : std_ulogic;
    seed                             : natural;
  end record;

  -- The handle of a read or a write slave, created with
  -- :vhdl:`axi4_slave_pkg.new_axi4_slave`. Each slave entity needs a handle
  -- of its own.
  type axi4_slave_t is record
    -- Private. Use the constructor and the accessors below.
    p_bus                        : axi4_bus_t;
    p_memory                     : axi4_memory_t;
    p_config                     : axi4_slave_config_t;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- A slave on ``memory`` with the widths of ``axi4_bus``, like VUnit's
  -- new_axi_slave: ``address_fifo_depth`` bursts may wait for their data
  -- (read) or data phase (write), ``write_response_fifo_depth`` write
  -- responses may wait for BREADY, and an INCR burst crossing a 4 KB boundary
  -- is a check failure unless ``check_4kbyte_boundary`` is false. Each cycle
  -- AxREADY is 0 with ``address_stall_probability``, RVALID or WREADY with
  -- ``data_stall_probability`` and BVALID with
  -- ``write_response_stall_probability``, drawn from ``seed``. The response
  -- latency, uniform from ``min_response_latency`` to
  -- ``max_response_latency``, is the time from the AR handshake to the first
  -- read data, and from the last write data to the write response. With
  -- ``drive_invalid`` the slave drives ``drive_invalid_val`` on the payload
  -- of R and B while their VALID is 0, and on the RDATA lanes a beat does not
  -- use.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:axi4_slave:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_axi4_slave (
    memory : axi4_memory_t;
    axi4_bus : axi4_bus_t := default_axi4_bus;
    address_fifo_depth : positive := 1;
    write_response_fifo_depth : positive := 1;
    check_4kbyte_boundary : boolean := true;
    address_stall_probability : probability_t := 0.0;
    data_stall_probability : probability_t := 0.0;
    write_response_stall_probability : probability_t := 0.0;
    min_response_latency : delay_length := 0 ns;
    max_response_latency : delay_length := 0 ns;
    drive_invalid : boolean := true;
    drive_invalid_val : std_ulogic := 'X';
    seed : natural := 0;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_slave_t;

  -- The id, logger, actor and checker of the slave, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``.
  -- ``wait_until_idle`` returns when no burst is queued or in progress and
  -- no response waits.
  impure function get_id (axi_slave : axi4_slave_t) return id_t;
  impure function get_logger (axi_slave : axi4_slave_t) return logger_t;
  impure function get_actor (axi_slave : axi4_slave_t) return actor_t;
  impure function get_checker (axi_slave : axi4_slave_t) return checker_t;
  impure function as_sync (axi_slave : axi4_slave_t) return sync_handle_t;

  -- The widths of the interface, for the ports of the entities, and the memory
  function get_bus (axi_slave : axi4_slave_t) return axi4_bus_t;
  function get_memory (axi_slave : axi4_slave_t) return axi4_memory_t;

  -- Private. The configuration the entities start with
  function get_config (axi_slave : axi4_slave_t) return axi4_slave_config_t;

  -- Blocking: set the depth of the address FIFO. A depth smaller than the
  -- bursts waiting is a check failure and leaves it unchanged.
  procedure set_address_fifo_depth (signal net : inout network_t; axi_slave : axi4_slave_t; depth : positive);

  -- Blocking: set the depth of the write response FIFO, likewise
  procedure set_write_response_fifo_depth (signal net : inout network_t; axi_slave : axi4_slave_t; depth : positive);

  -- Blocking: set the stall probabilities of AxREADY, of RVALID or WREADY,
  -- and of BVALID
  procedure set_address_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  );
  procedure set_data_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  );
  procedure set_write_response_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  );

  -- Blocking: set the response latency, uniform in [min_latency,
  -- max_latency], or fixed. All write data is written to the memory right
  -- before the write response.
  procedure set_response_latency (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    min_latency, max_latency : delay_length
  );
  procedure set_response_latency (signal net : inout network_t; axi_slave : axi4_slave_t; latency : delay_length);

  -- Blocking: check INCR bursts for crossing a 4 KB boundary, or not
  procedure enable_4kbyte_boundary_check (signal net : inout network_t; axi_slave : axi4_slave_t);
  procedure disable_4kbyte_boundary_check (signal net : inout network_t; axi_slave : axi4_slave_t);

  -- Blocking: the number of bursts of each length the slave accepted, as
  -- VUnit's ``axi_statistics_t``. ``stat`` is deallocated first; the caller
  -- deallocates the new one. ``clear`` starts counting from 0 again.
  procedure get_statistics (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    variable stat : inout axi_statistics_t;
    clear : boolean := false
  );

  -- Blocking: check that bursts are well behaved, that is compact on the
  -- data channel, as VUnit does. For a write slave: WVALID and BREADY stay 1
  -- while a burst is active and bursts of more than one beat use the full
  -- data width. For a read slave: RREADY stays 1 while a burst is active and
  -- bursts of more than one beat use the full data width.
  procedure enable_well_behaved_check (signal net : inout network_t; axi_slave : axi4_slave_t);

  -- Blocking: recover a slave, for example after a reset of the design.
  -- Drops the bursts and responses queued or in progress and deasserts VALID
  -- and READY until the next clock edge. The configuration, the statistics and
  -- the memory are kept. ARESETn at 0 does the same at every edge.
  procedure reset (signal net : inout network_t; axi_slave : axi4_slave_t);

  -- The message types the procedures above send to the slave
  constant set_axi4_slave_address_fifo_depth_msg : msg_type_t := new_msg_type("set axi4 slave address fifo depth");
  constant set_axi4_slave_write_response_fifo_depth_msg : msg_type_t :=
    new_msg_type("set axi4 slave write response fifo depth");
  constant set_axi4_slave_address_stall_probability_msg : msg_type_t :=
    new_msg_type("set axi4 slave address stall probability");
  constant set_axi4_slave_data_stall_probability_msg : msg_type_t :=
    new_msg_type("set axi4 slave data stall probability");
  constant set_axi4_slave_write_response_stall_probability_msg : msg_type_t :=
    new_msg_type("set axi4 slave write response stall probability");
  constant set_axi4_slave_response_latency_msg : msg_type_t := new_msg_type("set axi4 slave response latency");
  constant set_axi4_slave_4kbyte_boundary_check_msg : msg_type_t :=
    new_msg_type("set axi4 slave 4kbyte boundary check");
  constant get_axi4_slave_statistics_msg : msg_type_t := new_msg_type("get axi4 slave statistics");
  constant enable_axi4_slave_well_behaved_check_msg : msg_type_t :=
    new_msg_type("enable axi4 slave well behaved check");
  constant reset_axi4_slave_msg : msg_type_t := new_msg_type("reset axi4 slave");
  constant axi4_slave_reply_msg : msg_type_t := new_msg_type("axi4 slave reply");

  -- Private. A message type no handler took, see
  -- :vhdl:`axi4_pkg.axi4_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; axi_slave : axi4_slave_t);

  -- Private. A vector as a number, metavalues as 0
  function known (value : std_ulogic_vector) return u_unsigned;
  function known (value : std_ulogic_vector) return natural;

  -- Private. An address in decimal, as VUnit's messages give addresses
  function to_decimal (value : u_unsigned) return string;

  -- Private. The random numbers of one process of a slave
  type axi4_slave_random_t is record
    p_seed1 : positive;
    p_seed2 : positive;
  end record;

  -- Private. The random numbers of the process ``stream`` of a slave
  function new_axi4_slave_random (axi_slave : axi4_slave_t; stream : natural) return axi4_slave_random_t;

  -- Private. Whether to stall a cycle, with ``probability``
  procedure draw_stall (
    variable random : inout axi4_slave_random_t;
    probability : probability_t;
    variable stall : out boolean
  );

  -- Private. A response latency, uniform in [min_latency, max_latency]
  procedure draw_latency (
    variable random : inout axi4_slave_random_t;
    min_latency, max_latency : delay_length;
    variable latency : out delay_length
  );

  -- Private. Attach a slave to its memory, returning its port
  impure function attach_axi4_slave (axi_slave : axi4_slave_t; is_write : boolean) return natural;

  -- Private. Log the reports of a slave, and of its memory, when
  -- ``num_reports`` is not 0
  procedure log_slave_reports (axi_slave : axi4_slave_t; port_index : natural; num_reports : natural);

  -- Private. What the messages to a slave change
  type axi4_slave_state_t is record
    address_fifo_depth               : positive;
    write_response_fifo_depth        : positive;
    address_stall_probability        : probability_t;
    data_stall_probability           : probability_t;
    write_response_stall_probability : probability_t;
    min_response_latency             : delay_length;
    max_response_latency             : delay_length;
    well_behaved_check               : boolean;
    -- The bursts in the address FIFO and the responses in the write response FIFO
    queued_bursts                    : natural;
    queued_responses                 : natural;
    -- A reset request was handled; the entity drops its bursts
    reset_requested                  : boolean;
    -- Messages wait until then, after wait_for_time
    resume_time                      : time;
    -- The wait_until_idle requests to reply to when the slave is idle
    idle_requests                    : queue_t;
  end record;

  -- Private. The state a slave starts in
  impure function new_axi4_slave_state (axi_slave : axi4_slave_t) return axi4_slave_state_t;

  -- Private. Handle the messages waiting for a slave, and reply to the
  -- wait_until_idle requests when ``idle``
  procedure handle_axi4_slave_messages (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    port_index : natural;
    variable state : inout axi4_slave_state_t;
    idle : boolean
  );
end package;

package body axi4_slave_pkg is

  impure function new_axi4_slave (
    memory : axi4_memory_t;
    axi4_bus : axi4_bus_t := default_axi4_bus;
    address_fifo_depth : positive := 1;
    write_response_fifo_depth : positive := 1;
    check_4kbyte_boundary : boolean := true;
    address_stall_probability : probability_t := 0.0;
    data_stall_probability : probability_t := 0.0;
    write_response_stall_probability : probability_t := 0.0;
    min_response_latency : delay_length := 0 ns;
    max_response_latency : delay_length := 0 ns;
    drive_invalid : boolean := true;
    drive_invalid_val : std_ulogic := 'X';
    seed : natural := 0;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_slave_t is

    variable result : axi4_slave_t := (
      p_bus => axi4_bus,
      p_memory => memory,
      p_config => (
        address_fifo_depth => address_fifo_depth,
        write_response_fifo_depth => write_response_fifo_depth,
        check_4kbyte_boundary => check_4kbyte_boundary,
        address_stall_probability => address_stall_probability,
        data_stall_probability => data_stall_probability,
        write_response_stall_probability => write_response_stall_probability,
        min_response_latency => min_response_latency,
        max_response_latency => max_response_latency,
        drive_invalid => drive_invalid,
        drive_invalid_val => drive_invalid_val,
        seed => seed
      ),
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if id = null_id then
      result.p_id := enumerate(get_id("axi4_slave", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_axi4_actor(result.p_id);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    return result;
  end;

  impure function get_id (axi_slave : axi4_slave_t) return id_t is
  begin

    return axi_slave.p_id;
  end;

  impure function get_logger (axi_slave : axi4_slave_t) return logger_t is
  begin

    return axi_slave.p_logger;
  end;

  impure function get_actor (axi_slave : axi4_slave_t) return actor_t is
  begin

    return axi_slave.p_actor;
  end;

  impure function get_checker (axi_slave : axi4_slave_t) return checker_t is
  begin

    return axi_slave.p_checker;
  end;

  impure function as_sync (axi_slave : axi4_slave_t) return sync_handle_t is
  begin

    return axi_slave.p_actor;
  end;

  function get_bus (axi_slave : axi4_slave_t) return axi4_bus_t is
  begin

    return axi_slave.p_bus;
  end;

  function get_memory (axi_slave : axi4_slave_t) return axi4_memory_t is
  begin

    return axi_slave.p_memory;
  end;

  function get_config (axi_slave : axi4_slave_t) return axi4_slave_config_t is
  begin

    return axi_slave.p_config;
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; axi_slave : axi4_slave_t) is
  begin

    axi4_unexpected_msg_type(msg_type, axi_slave.p_unexpected_msg_type_policy, axi_slave.p_checker);
  end;

  -- Send a request and wait for the slave to handle it
  procedure request (signal net : inout network_t; axi_slave : axi4_slave_t; msg : msg_t) is

    variable request_msg : msg_t := msg;
    variable reply_msg : msg_t;
  begin

    request(net, axi_slave.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

  procedure set_address_fifo_depth (signal net : inout network_t; axi_slave : axi4_slave_t; depth : positive) is

    variable request_msg : msg_t := new_msg(set_axi4_slave_address_fifo_depth_msg);
  begin

    push(request_msg, depth);
    request(net, axi_slave, request_msg);
  end;

  procedure set_write_response_fifo_depth (signal net : inout network_t; axi_slave : axi4_slave_t; depth : positive) is

    variable request_msg : msg_t := new_msg(set_axi4_slave_write_response_fifo_depth_msg);
  begin

    push(request_msg, depth);
    request(net, axi_slave, request_msg);
  end;

  procedure set_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    msg_type : msg_type_t;
    probability : probability_t
  ) is

    variable request_msg : msg_t := new_msg(msg_type);
  begin

    push_real(request_msg, probability);
    request(net, axi_slave, request_msg);
  end;

  procedure set_address_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  ) is
  begin

    set_probability(net, axi_slave, set_axi4_slave_address_stall_probability_msg, probability);
  end;

  procedure set_data_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  ) is
  begin

    set_probability(net, axi_slave, set_axi4_slave_data_stall_probability_msg, probability);
  end;

  procedure set_write_response_stall_probability (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    probability : probability_t
  ) is
  begin

    set_probability(net, axi_slave, set_axi4_slave_write_response_stall_probability_msg, probability);
  end;

  procedure set_response_latency (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    min_latency, max_latency : delay_length
  ) is

    variable request_msg : msg_t := new_msg(set_axi4_slave_response_latency_msg);
  begin

    push_time(request_msg, min_latency);
    push_time(request_msg, max_latency);
    request(net, axi_slave, request_msg);
  end;

  procedure set_response_latency (signal net : inout network_t; axi_slave : axi4_slave_t; latency : delay_length) is
  begin

    set_response_latency(net, axi_slave, latency, latency);
  end;

  procedure set_4kbyte_boundary_check (signal net : inout network_t; axi_slave : axi4_slave_t; enabled : boolean) is

    variable request_msg : msg_t := new_msg(set_axi4_slave_4kbyte_boundary_check_msg);
  begin

    push_boolean(request_msg, enabled);
    request(net, axi_slave, request_msg);
  end;

  procedure enable_4kbyte_boundary_check (signal net : inout network_t; axi_slave : axi4_slave_t) is
  begin

    set_4kbyte_boundary_check(net, axi_slave, true);
  end;

  procedure disable_4kbyte_boundary_check (signal net : inout network_t; axi_slave : axi4_slave_t) is
  begin

    set_4kbyte_boundary_check(net, axi_slave, false);
  end;

  procedure get_statistics (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    variable stat : inout axi_statistics_t;
    clear : boolean := false
  ) is

    variable request_msg : msg_t := new_msg(get_axi4_slave_statistics_msg);
    variable reply_msg : msg_t;
  begin

    deallocate(stat);
    push_boolean(request_msg, clear);
    request(net, axi_slave.p_actor, request_msg, reply_msg);
    stat := (p_count_by_burst_length => pop_integer_vector_ptr_ref(reply_msg));
    delete(reply_msg);
  end;

  procedure enable_well_behaved_check (signal net : inout network_t; axi_slave : axi4_slave_t) is

    variable request_msg : msg_t := new_msg(enable_axi4_slave_well_behaved_check_msg);
  begin

    request(net, axi_slave, request_msg);
  end;

  procedure reset (signal net : inout network_t; axi_slave : axi4_slave_t) is

    variable request_msg : msg_t := new_msg(reset_axi4_slave_msg);
  begin

    request(net, axi_slave, request_msg);
  end;

  function known (value : std_ulogic_vector) return u_unsigned is

    alias normalized : std_ulogic_vector(value'length - 1 downto 0) is value;
    variable result : u_unsigned(value'length - 1 downto 0) := (others => '0');
  begin

    for idx in normalized'range loop

      if to_x01(normalized(idx)) = '1' then
        result(idx) := '1';
      end if;
    end loop;

    return result;
  end;

  function known (value : std_ulogic_vector) return natural is

    constant bits : u_unsigned(value'length - 1 downto 0) := known(value);
  begin

    if value'length = 0 then
      return 0;
    end if;
    return to_integer(bits);
  end;

  function to_decimal (value : u_unsigned) return string is

    variable rest : u_unsigned(value'length - 1 downto 0) := value;
    variable digit : natural;
  begin

    if rest < 10 then
      return integer'image(to_integer(rest));
    end if;
    digit := to_integer(rest mod 10);
    return to_decimal(rest / 10) & integer'image(digit);
  end;

  function new_axi4_slave_random (axi_slave : axi4_slave_t; stream : natural) return axi4_slave_random_t is

    constant seed : natural := axi_slave.p_config.seed;
  begin

    return (
      p_seed1 => 1 + (seed + stream) mod 2147483562,
      p_seed2 => 1 + (seed / 2147483562 + 7 * stream) mod 2147483398
    );
  end;

  procedure draw_stall (
    variable random : inout axi4_slave_random_t;
    probability : probability_t;
    variable stall : out boolean
  ) is

    variable value : real;
  begin

    stall := false;
    if probability /= 0.0 then
      uniform(random.p_seed1, random.p_seed2, value);
      stall := value < probability;
    end if;
  end;

  procedure draw_latency (
    variable random : inout axi4_slave_random_t;
    min_latency, max_latency : delay_length;
    variable latency : out delay_length
  ) is

    variable value : real;
  begin

    latency := min_latency;
    if max_latency > min_latency then
      uniform(random.p_seed1, random.p_seed2, value);
      latency := min_latency + integer(value * real((max_latency - min_latency) / 1 ps)) * 1 ps;
    end if;
  end;

  impure function attach_axi4_slave (axi_slave : axi4_slave_t; is_write : boolean) return natural is
  begin

    return backend_call_integer(
      memory_session(axi_slave.p_memory),
      "attach",
      arg_text(full_name(axi_slave.p_id))
      & arg(data_length(axi_slave.p_bus))
      & arg(is_write)
      & arg(axi_slave.p_config.check_4kbyte_boundary)
    );
  end;

  procedure log_slave_reports (axi_slave : axi4_slave_t; port_index : natural; num_reports : natural) is

    constant memory : axi4_memory_t := axi_slave.p_memory;
  begin

    if num_reports > 0 then
      log_reports(memory_session(memory), axi_slave.p_logger, axi_slave.p_checker, arg(port_index));
      log_reports(memory_session(memory), get_logger(memory), get_checker(memory));
    end if;
  end;

  impure function new_axi4_slave_state (axi_slave : axi4_slave_t) return axi4_slave_state_t is

    constant config : axi4_slave_config_t := axi_slave.p_config;
  begin

    return (
      address_fifo_depth => config.address_fifo_depth,
      write_response_fifo_depth => config.write_response_fifo_depth,
      address_stall_probability => config.address_stall_probability,
      data_stall_probability => config.data_stall_probability,
      write_response_stall_probability => config.write_response_stall_probability,
      min_response_latency => config.min_response_latency,
      max_response_latency => config.max_response_latency,
      well_behaved_check => false,
      queued_bursts => 0,
      queued_responses => 0,
      reset_requested => false,
      resume_time => 0 fs,
      idle_requests => new_queue
    );
  end;

  procedure handle_axi4_slave_messages (
    signal net : inout network_t;
    axi_slave : axi4_slave_t;
    port_index : natural;
    variable state : inout axi4_slave_state_t;
    idle : boolean
  ) is

    constant checker : checker_t := axi_slave.p_checker;
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable depth : positive;
    variable counts : integer_array_t;
    variable count_by_burst_length : integer_vector_ptr_t;
  begin

    while now >= state.resume_time and has_message(axi_slave.p_actor) loop

      receive(net, axi_slave.p_actor, msg);
      msg_type := message_type(msg);
      reply_msg := new_msg(axi4_slave_reply_msg);
      if msg_type = set_axi4_slave_address_fifo_depth_msg then
        depth := pop(msg);
        if state.queued_bursts > depth then
          check_failed(
            checker,
            "New address fifo depth "
            & to_string(depth)
            & " is smaller than current content size "
            & to_string(state.queued_bursts)
          );
        else
          state.address_fifo_depth := depth;
        end if;
      elsif msg_type = set_axi4_slave_write_response_fifo_depth_msg then
        depth := pop(msg);
        if state.queued_responses > depth then
          check_failed(
            checker,
            "New write response fifo depth "
            & to_string(depth)
            & " is smaller than current content size "
            & to_string(state.queued_responses)
          );
        else
          state.write_response_fifo_depth := depth;
        end if;
      elsif msg_type = set_axi4_slave_address_stall_probability_msg then
        state.address_stall_probability := pop_real(msg);
      elsif msg_type = set_axi4_slave_data_stall_probability_msg then
        state.data_stall_probability := pop_real(msg);
      elsif msg_type = set_axi4_slave_write_response_stall_probability_msg then
        state.write_response_stall_probability := pop_real(msg);
      elsif msg_type = set_axi4_slave_response_latency_msg then
        state.min_response_latency := pop_time(msg);
        state.max_response_latency := pop_time(msg);
      elsif msg_type = set_axi4_slave_4kbyte_boundary_check_msg then
        backend_call(
          memory_session(axi_slave.p_memory),
          "set_check_4kbyte_boundary",
          arg(port_index) & arg(boolean'(pop_boolean(msg)))
        );
      elsif msg_type = get_axi4_slave_statistics_msg then
        counts := backend_call_integer_array(
          memory_session(axi_slave.p_memory),
          "statistics",
          arg(port_index) & arg(boolean'(pop_boolean(msg)))
        );
        count_by_burst_length := new_integer_vector_ptr(length(counts));
        for idx in 0 to length(counts) - 1 loop

          set(count_by_burst_length, idx, get(counts, idx));
        end loop;

        deallocate(counts);
        push_integer_vector_ptr_ref(reply_msg, count_by_burst_length);
      elsif msg_type = enable_axi4_slave_well_behaved_check_msg then
        state.well_behaved_check := true;
      elsif msg_type = reset_axi4_slave_msg then
        state.reset_requested := true;
        log_slave_reports(
          axi_slave,
          port_index,
          backend_call_integer(memory_session(axi_slave.p_memory), "reset_slave", arg(port_index))
        );
      elsif msg_type = wait_until_idle_msg then
        handle_message(msg_type);
        push(state.idle_requests, msg);
        delete(reply_msg);
      elsif msg_type = wait_for_time_msg then
        handle_message(msg_type);
        state.resume_time := now + pop_time(msg);
        delete(reply_msg);
        delete(msg);
      else
        unexpected_msg_type(msg_type, axi_slave);
        delete(reply_msg);
      end if;

      if reply_msg /= null_msg then
        reply(net, msg, reply_msg);
      end if;
    end loop;

    while idle and not is_empty(state.idle_requests) loop

      msg := pop(state.idle_requests);
      reply_msg := new_msg(wait_until_idle_reply_msg);
      reply(net, msg, reply_msg);
    end loop;

  end;

end package body;
