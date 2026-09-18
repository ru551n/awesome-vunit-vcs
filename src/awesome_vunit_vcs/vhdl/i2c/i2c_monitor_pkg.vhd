-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the I2C monitor verification component
-- (i2c_monitor.vhd).
--
-- The monitor records every change of SCL and SDA with its time and never
-- drives them. Its Python backend reconstructs the transfers: a transfer
-- starts with a START or repeated START, carries a 7-bit or 10-bit address,
-- the R/W bit and data bytes with their acknowledge bits, and ends at the
-- next repeated START or STOP. The monitor publishes every transfer as an
-- ``i2c_transfer_msg`` to its subscribers, keeps the last 1024 for
-- :vhdl:`i2c_monitor_pkg.pop_i2c_transfer`, compares them with the transfers
-- :vhdl:`i2c_monitor_pkg.check_i2c_transfer` expects, and counts statistics.
--
-- With a protocol checker in its handle the monitor instantiates an
-- i2c_protocol_checker on the same pins.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

  use work.i2c_pkg.all;
  use work.i2c_protocol_checker_pkg.all;

package i2c_monitor_pkg is

  -- The handle of a monitor, created with :vhdl:`i2c_monitor_pkg.new_i2c_monitor`
  type i2c_monitor_t is record
    -- Private. Use the constructor and the accessors below.
    p_protocol_checker           : i2c_protocol_checker_t;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- An I2C monitor. ``protocol_checker`` is instantiated on the pins of the
  -- monitor unless it is
  -- :vhdl:`i2c_protocol_checker_pkg.null_i2c_protocol_checker`. Without one,
  -- the monitor reports metavalues on SCL and SDA itself (``I2C_METAVALUE``).
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:i2c_monitor:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_i2c_monitor (
    protocol_checker : i2c_protocol_checker_t := null_i2c_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_monitor_t;

  -- The id, logger, actor and checker of the monitor, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``.
  -- ``wait_until_idle`` returns when Python has processed everything sampled
  -- so far.
  impure function get_id (monitor : i2c_monitor_t) return id_t;
  impure function get_logger (monitor : i2c_monitor_t) return logger_t;
  impure function get_actor (monitor : i2c_monitor_t) return actor_t;
  impure function get_checker (monitor : i2c_monitor_t) return checker_t;
  impure function as_sync (monitor : i2c_monitor_t) return sync_handle_t;

  -- The protocol checker the monitor instantiates, with its final id, or
  -- :vhdl:`i2c_protocol_checker_pkg.null_i2c_protocol_checker`
  function protocol_checker (monitor : i2c_monitor_t) return i2c_protocol_checker_t;

  -- One transfer the monitor reconstructed
  type i2c_transfer_t is record
    -- The 7-bit or 10-bit address, -1 when the bus carried no complete address
    address        : integer;
    -- The R/W bit is R
    is_read        : boolean;
    -- The address is a 10-bit address
    ten_bit        : boolean;
    -- The transfer started with a repeated START
    repeated_start : boolean;
    -- The transfer ended with a STOP, not a repeated START
    stopped        : boolean;
    -- Every address byte was acknowledged
    address_ack    : boolean;
    -- The index of the first data byte that was not acknowledged, -1 when all were
    nack_index     : integer;
    -- The time of the START
    start_time     : time;
    -- The data bytes, one per element. The receiver owns them and deallocates them.
    data           : integer_array_t;
  end record;

  -- A pending request, redeemed with the matching await procedure
  alias i2c_monitor_reference_t is msg_t;

  -- Non-blocking: pop the oldest transfer the monitor keeps, or the next one
  -- to come
  procedure pop_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable reference : inout i2c_monitor_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`i2c_monitor_pkg.pop_i2c_transfer`
  procedure await_pop_i2c_transfer_reply (
    signal net : inout network_t;
    variable reference : inout i2c_monitor_reference_t;
    variable transfer : out i2c_transfer_t
  );

  -- Blocking: pop the oldest transfer the monitor keeps, or wait for the next
  procedure pop_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable transfer : out i2c_transfer_t
  );

  -- Read the transfer of an ``i2c_transfer_msg`` the monitor published, or of
  -- a pop reply
  procedure pop_i2c_transfer (msg : msg_t; variable transfer : out i2c_transfer_t);

  -- Non-blocking: the next transfer must have this address, direction and
  -- data, leftmost byte first. A difference, or an expected transfer that
  -- never came when the test ends, is a check failure (``I2C_SCOREBOARD``) on
  -- the checker of the monitor, prefixed with msg.
  procedure check_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    address : natural;
    is_read : boolean;
    data : std_ulogic_vector;
    msg : string := ""
  );

  -- What the monitor observed since it started or its statistics were cleared
  type i2c_statistics_t is record
    -- Transactions started, START to STOP
    transactions         : natural;
    -- Transfers completed
    transfers            : natural;
    -- Transfers with the R/W bit R
    reads                : natural;
    -- Transfers with the R/W bit W
    writes               : natural;
    -- Transfers started with a repeated START
    repeated_starts      : natural;
    -- Data bytes, not counting address bytes
    data_bytes           : natural;
    -- Bytes not acknowledged, address bytes included
    nacks                : natural;
    -- Transfers whose address was not acknowledged
    address_nacks        : natural;
    -- Samples with a metavalue on SCL or SDA
    metavalues           : natural;
    -- 1 / the median time between rising SCL edges inside transactions, 0 without a clock
    scl_frequency_hz     : natural;
    -- 1 / the shortest time between rising SCL edges inside transactions
    max_scl_frequency_hz : natural;
    -- Time inside transactions
    busy_time            : delay_length;
    -- SCL low time beyond the usual low period, an estimate of clock stretching
    stretch_time         : delay_length;
    -- The share of the time the bus was busy, in parts per million
    utilization_ppm      : natural;
  end record;

  -- Non-blocking: request the statistics
  procedure get_i2c_statistics (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable reference : inout i2c_monitor_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`i2c_monitor_pkg.get_i2c_statistics`
  procedure await_get_i2c_statistics_reply (
    signal net : inout network_t;
    variable reference : inout i2c_monitor_reference_t;
    variable statistics : out i2c_statistics_t
  );

  -- Blocking: get the statistics
  procedure get_i2c_statistics (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable statistics : out i2c_statistics_t
  );

  -- Blocking: recover a monitor. Forgets a transaction in progress, the kept
  -- transfers and the expected ones. Pending pops are cancelled and must not
  -- be awaited. Statistics are kept unless clear_statistics.
  procedure reset (signal net : inout network_t; monitor : i2c_monitor_t; clear_statistics : boolean := false);

  -- The message types the procedures above send to the component, and the
  -- ``i2c_transfer_msg`` it publishes
  constant pop_i2c_transfer_msg : msg_type_t := new_msg_type("pop i2c transfer");
  constant pop_i2c_transfer_reply_msg : msg_type_t := new_msg_type("pop i2c transfer reply");
  constant i2c_transfer_msg : msg_type_t := new_msg_type("i2c transfer");
  constant check_i2c_transfer_msg : msg_type_t := new_msg_type("check i2c transfer");
  constant get_i2c_statistics_msg : msg_type_t := new_msg_type("get i2c statistics");
  constant get_i2c_statistics_reply_msg : msg_type_t := new_msg_type("get i2c statistics reply");
  constant reset_i2c_monitor_msg : msg_type_t := new_msg_type("reset i2c monitor");
  constant reset_i2c_monitor_reply_msg : msg_type_t := new_msg_type("reset i2c monitor reply");

  -- Private. A message type no handler took, see
  -- :vhdl:`i2c_pkg.i2c_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; monitor : i2c_monitor_t);
end package;

package body i2c_monitor_pkg is

  impure function new_i2c_monitor (
    protocol_checker : i2c_protocol_checker_t := null_i2c_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_monitor_t is

    variable result : i2c_monitor_t := (
      p_protocol_checker => null_i2c_protocol_checker,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if id = null_id then
      result.p_id := enumerate(get_id("i2c_monitor", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_i2c_actor(result.p_id);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_protocol_checker := get_valid_protocol_checker(protocol_checker, result.p_id);
    return result;
  end;

  impure function get_id (monitor : i2c_monitor_t) return id_t is
  begin

    return monitor.p_id;
  end;

  impure function get_logger (monitor : i2c_monitor_t) return logger_t is
  begin

    return monitor.p_logger;
  end;

  impure function get_actor (monitor : i2c_monitor_t) return actor_t is
  begin

    return monitor.p_actor;
  end;

  impure function get_checker (monitor : i2c_monitor_t) return checker_t is
  begin

    return monitor.p_checker;
  end;

  impure function as_sync (monitor : i2c_monitor_t) return sync_handle_t is
  begin

    return monitor.p_actor;
  end;

  function protocol_checker (monitor : i2c_monitor_t) return i2c_protocol_checker_t is
  begin

    return monitor.p_protocol_checker;
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; monitor : i2c_monitor_t) is
  begin

    i2c_unexpected_msg_type(msg_type, monitor.p_unexpected_msg_type_policy, monitor.p_checker);
  end;

  procedure pop_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable reference : inout i2c_monitor_reference_t
  ) is
  begin

    reference := new_msg(pop_i2c_transfer_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure pop_i2c_transfer (msg : msg_t; variable transfer : out i2c_transfer_t) is

    variable flags : natural;
    variable num_bytes : natural;
  begin

    transfer.address := pop(msg);
    flags := pop(msg);
    transfer.is_read := flags mod 2 = 1;
    transfer.ten_bit := flags / 2 mod 2 = 1;
    transfer.repeated_start := flags / 4 mod 2 = 1;
    transfer.stopped := flags / 8 mod 2 = 1;
    transfer.address_ack := flags / 16 mod 2 = 1;
    transfer.nack_index := pop(msg);
    transfer.start_time := pop(msg);
    num_bytes := pop(msg);
    transfer.data := new_1d(num_bytes, bit_width => 8, is_signed => false);
    for idx in 0 to num_bytes - 1 loop

      set(transfer.data, idx, integer'(pop(msg)));
    end loop;

  end;

  procedure await_pop_i2c_transfer_reply (
    signal net : inout network_t;
    variable reference : inout i2c_monitor_reference_t;
    variable transfer : out i2c_transfer_t
  ) is

    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    pop_i2c_transfer(reply_msg, transfer);
    delete(reference);
    delete(reply_msg);
  end;

  procedure pop_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable transfer : out i2c_transfer_t
  ) is

    variable reference : i2c_monitor_reference_t;
  begin

    pop_i2c_transfer(net, monitor, reference);
    await_pop_i2c_transfer_reply(net, reference, transfer);
  end;

  procedure check_i2c_transfer (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    address : natural;
    is_read : boolean;
    data : std_ulogic_vector;
    msg : string := ""
  ) is

    constant values : integer_vector := i2c_bytes(data);
    variable request_msg : msg_t := new_msg(check_i2c_transfer_msg);
  begin

    push(request_msg, address);
    push(request_msg, is_read);
    push(request_msg, values'length);
    for idx in values'range loop

      push(request_msg, values(idx));
    end loop;

    push_string(request_msg, msg);
    send(net, monitor.p_actor, request_msg);
  end;

  procedure get_i2c_statistics (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable reference : inout i2c_monitor_reference_t
  ) is
  begin

    reference := new_msg(get_i2c_statistics_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure await_get_i2c_statistics_reply (
    signal net : inout network_t;
    variable reference : inout i2c_monitor_reference_t;
    variable statistics : out i2c_statistics_t
  ) is

    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    statistics.transactions := pop(reply_msg);
    statistics.transfers := pop(reply_msg);
    statistics.reads := pop(reply_msg);
    statistics.writes := pop(reply_msg);
    statistics.repeated_starts := pop(reply_msg);
    statistics.data_bytes := pop(reply_msg);
    statistics.nacks := pop(reply_msg);
    statistics.address_nacks := pop(reply_msg);
    statistics.metavalues := pop(reply_msg);
    statistics.scl_frequency_hz := pop(reply_msg);
    statistics.max_scl_frequency_hz := pop(reply_msg);
    statistics.busy_time := pop(reply_msg);
    statistics.stretch_time := pop(reply_msg);
    statistics.utilization_ppm := pop(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_i2c_statistics (
    signal net : inout network_t;
    monitor : i2c_monitor_t;
    variable statistics : out i2c_statistics_t
  ) is

    variable reference : i2c_monitor_reference_t;
  begin

    get_i2c_statistics(net, monitor, reference);
    await_get_i2c_statistics_reply(net, reference, statistics);
  end;

  procedure reset (signal net : inout network_t; monitor : i2c_monitor_t; clear_statistics : boolean := false) is

    variable request_msg : msg_t := new_msg(reset_i2c_monitor_msg);
    variable reply_msg : msg_t;
  begin

    push(request_msg, clear_statistics);
    request(net, monitor.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
