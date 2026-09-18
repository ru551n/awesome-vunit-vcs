-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Control surface for the protocol-generic QSPI master verification component
-- (qspi_master.vhd).
--
-- This package knows nothing about flash. It offers exactly one primitive --
-- a QSPI transaction -- described in the vocabulary of the bus itself:
--
--   CS low
--     -> command bytes   at cmd_lanes    (the opcode, typically)
--     -> address bytes   at addr_lanes   (address, mode byte, ...)
--     -> write bytes     at wr_lanes     (a program payload, typically)
--     -> dummy_cycles    SCK cycles with every master IO tri-stated
--     -> num_read_bytes  read bytes at read_lanes
--   CS high
--
-- Three separate write phases rather than one is what lets a caller express
-- every flash command shape with one transaction: a quad-IO read sends its
-- opcode at x1 and its address at x4; a quad page program sends opcode and
-- address at x1 and its payload at x4. Any phase may be empty. The caller
-- composes the bytes; the VC owns CS framing, SCK generation, lane placement
-- and tri-stating.
--
-- Calls are non-blocking first: qspi_transfer with a reference queues the
-- transaction and returns at once, and await_qspi_transfer_reply redeems the
-- read data when the caller actually needs it. Blocking convenience overloads
-- that do both in one call are provided for directed sequences. Every
-- transaction is acknowledged with a reply whether or not it reads anything,
-- so a redeemed reference is also the point at which the transaction is known
-- to have completed on the bus.
--
-- The handle follows the constructor pattern of VUnit's own verification
-- components: an id, a logger, an actor, a checker and an unexpected message
-- type policy. as_sync makes sync_pkg.wait_until_idle work.
--
-- SPI mode 0 only (CPOL = 0, CPHA = 0): SCK idles low, the master changes its
-- outputs on the falling edge and both ends sample on the rising edge. That is
-- the mode every QSPI NOR flash supports; mode 3 differs only in the idle
-- level and is not needed here.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

  use work.qspi_pkg.all;
  use work.qspi_protocol_checker_pkg.all;

package qspi_master_pkg is

  ---------------------------------------------------------------------------
  -- Handle
  ---------------------------------------------------------------------------

  -- The handle of a QSPI master, created with
  -- :vhdl:`qspi_master_pkg.new_qspi_master`. It is the generic of the
  -- qspi_master entity and the first argument of the procedures below.
  type qspi_master_t is record
    -- Private. Use the accessors below.
    p_sck_period                 : delay_length;
    -- Minimum CS-high time between two transactions. A real device specifies
    -- this as tSHSL and ignores a command that arrives too soon after the
    -- previous one, so a master that deselects for less than tSHSL is a bug
    -- even though nothing on the bus looks wrong. It is NOT derived from the
    -- SCK period: tSHSL is a property of the device, not of the bus speed, and
    -- tying the two makes a fast bus silently violate a slow part.
    p_cs_deselect_time           : delay_length;
    p_protocol_checker           : qspi_protocol_checker_t;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- No QSPI master
  constant null_qspi_master : qspi_master_t := (
    p_sck_period => 0 ns,
    p_cs_deselect_time => 0 ns,
    p_protocol_checker => null_qspi_protocol_checker,
    p_id => null_id,
    p_logger => null_logger,
    p_actor => null_actor,
    p_checker => null_checker,
    p_unexpected_msg_type_policy => fail
  );

  -- The default SCK period, 50 MHz
  constant qspi_default_sck_period : delay_length := 20 ns;

  -- Comfortably above the default tSHSL of a flash (30 ns). Chosen as a
  -- default that does not violate a typical part rather than as the fastest
  -- legal value; a test that wants to probe the limit sets it down.
  constant qspi_default_cs_deselect_time : delay_length := 50 ns;

  -- A QSPI master. ``sck_period`` is the SCK period it starts with, and
  -- ``cs_deselect_time`` the minimum CS high time between two transactions;
  -- CS stays high for the longer of it and one SCK period.
  --
  -- A ``protocol_checker`` other than
  -- :vhdl:`qspi_protocol_checker_pkg.null_qspi_protocol_checker` is
  -- instantiated on the pins of the master, with the id
  -- ``<id>:protocol_checker`` unless it was created with an explicit id.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:qspi_master:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger. ``unexpected_msg_type_policy``
  -- says whether a message of an unknown type is a failure (``fail``) or
  -- ignored (``ignore``).
  impure function new_qspi_master (
    sck_period : delay_length := qspi_default_sck_period;
    cs_deselect_time : delay_length := qspi_default_cs_deselect_time;
    protocol_checker : qspi_protocol_checker_t := null_qspi_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return qspi_master_t;

  -- The id, actor, logger and checker of the master, and its handle for
  -- wait_until_idle and wait_for_time of sync_pkg
  impure function get_id (qspi_master : qspi_master_t) return id_t;
  impure function get_actor (qspi_master : qspi_master_t) return actor_t;
  impure function get_logger (qspi_master : qspi_master_t) return logger_t;
  impure function get_checker (qspi_master : qspi_master_t) return checker_t;
  impure function as_sync (qspi_master : qspi_master_t) return sync_handle_t;

  -- The SCK period the VC starts out with. The value actually in force can be
  -- changed at run time with set_sck_period below and is then owned by the
  -- VC process, so this accessor reports the initial value only.
  function sck_period (qspi_master : qspi_master_t) return delay_length;

  -- The configured minimum CS-high time between transactions
  function cs_deselect_time (qspi_master : qspi_master_t) return delay_length;

  -- The protocol checker the master instantiates, with its final id, or
  -- :vhdl:`qspi_protocol_checker_pkg.null_qspi_protocol_checker`
  function protocol_checker (qspi_master : qspi_master_t) return qspi_protocol_checker_t;

  -- Handle a message type no handler took, following the unexpected message
  -- type policy of the handle like vc_pkg.unexpected_msg_type of VUnit: a
  -- check failure ``Got unexpected message <name>`` on the checker of the
  -- handle unless the policy is ignore or the message was already handled
  procedure unexpected_msg_type (msg_type : msg_type_t; qspi_master : qspi_master_t);

  ---------------------------------------------------------------------------
  -- Byte arrays
  ---------------------------------------------------------------------------

  -- A new byte array of values, one byte per element, for the phases of
  -- qspi_transfer and the data of the flash procedures, for example
  -- new_byte_array((16#DE#, 16#AD#)). The caller owns the result.
  impure function new_byte_array (values : integer_vector) return integer_array_t;

  ---------------------------------------------------------------------------
  -- Transactions
  ---------------------------------------------------------------------------

  -- Handle to an issued, not yet redeemed transaction.
  alias qspi_transfer_reference_t is msg_t;

  -- Non-blocking: queue one transaction and return immediately.
  --
  -- cmd, addr and wr_data are byte arrays (one byte per element, 0 .. 255);
  -- any of them may be null_integer_array for an empty phase. The arrays are
  -- read during this call only, so the caller keeps ownership and may
  -- deallocate or reuse them as soon as it returns.
  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    variable reference : inout qspi_transfer_reference_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0;
    num_read_bytes : natural := 0;
    read_lanes : lane_count_t := 1
  );

  -- Blocking: redeem a reference. data is replaced by a freshly allocated
  -- byte array holding the num_read_bytes bytes read, which the caller then
  -- owns and must deallocate. Any array previously held by data is
  -- deallocated first.
  procedure await_qspi_transfer_reply (
    signal net : inout network_t;
    variable reference : inout qspi_transfer_reference_t;
    variable data : inout integer_array_t
  );

  -- Blocking: redeem a reference, discarding any read data.
  procedure await_qspi_transfer_reply (
    signal net : inout network_t;
    variable reference : inout qspi_transfer_reference_t
  );

  -- Blocking convenience: issue and redeem in one call.
  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    variable data : inout integer_array_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0;
    num_read_bytes : natural := 0;
    read_lanes : lane_count_t := 1
  );

  -- Blocking convenience for a write-only transaction.
  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0
  );

  ---------------------------------------------------------------------------
  -- Run-time configuration
  ---------------------------------------------------------------------------

  -- Blocking, acknowledged: change the SCK period used by every subsequent
  -- transaction. Queued transactions issued before this call still run at the
  -- old period, since the VC handles its messages in order.
  procedure set_sck_period (signal net : inout network_t; qspi_master : qspi_master_t; period : delay_length);

  ---------------------------------------------------------------------------
  -- Protocol checks
  ---------------------------------------------------------------------------

  -- :vhdl:`qspi_protocol_checker_pkg.set_check_enabled` for the protocol
  -- checker of the master. A master without a protocol checker reports
  -- ``<id> has no protocol checker`` as a check failure on its checker.
  procedure set_check_enabled (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    enabled : boolean := true
  );

  -- Blocking: :vhdl:`qspi_protocol_checker_pkg.get_check_count` for the
  -- protocol checker of the master. A master without a protocol checker reports
  -- ``<id> has no protocol checker`` as a check failure on its checker, and
  -- count is 0.
  procedure get_check_count (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    variable count : out natural
  );

  -- Non-blocking: request the violation count of a rule of the protocol
  -- checker of the master, redeemed with
  -- :vhdl:`qspi_protocol_checker_pkg.await_get_check_count_reply`. A master
  -- without a protocol checker reports ``<id> has no protocol checker`` as a
  -- check failure on its checker, and reference is then null_msg, which is
  -- not to be awaited.
  procedure get_check_count (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  );

  ---------------------------------------------------------------------------
  -- Reset
  ---------------------------------------------------------------------------

  -- Blocking: recover the master, also in the middle of a transfer and while
  -- the far end is stuck. A transfer in progress is aborted within the SCK half
  -- period it is in: SCK returns to '0', the IOs are released and CS rises. CS
  -- then stays high for the CS deselect time before the reset returns. Every
  -- transfer queued before the reset is dropped.
  --
  -- The callers of the aborted and the dropped transfers do not hang: their
  -- replies carry the bytes read before the abort, so data is shorter than
  -- num_read_bytes, and is empty for a dropped transfer. The master logs what
  -- it aborted and dropped on its logger at level info. Other requests queued
  -- before the reset, such as set_sck_period, are handled after it. A reset of
  -- an idle master returns at once.
  procedure reset (signal net : inout network_t; qspi_master : qspi_master_t);

  ---------------------------------------------------------------------------
  -- Message types, for the VC implementation
  ---------------------------------------------------------------------------

  -- The message types the procedures above send to the component
  constant transfer_qspi_master_data_msg : msg_type_t := new_msg_type("transfer qspi master data");
  constant transfer_qspi_master_data_reply_msg : msg_type_t := new_msg_type("transfer qspi master data reply");
  constant set_qspi_master_sck_period_msg : msg_type_t := new_msg_type("set qspi master sck period");
  constant set_qspi_master_sck_period_reply_msg : msg_type_t := new_msg_type("set qspi master sck period reply");
  constant reset_qspi_master_msg : msg_type_t := new_msg_type("reset qspi master");
  constant reset_qspi_master_reply_msg : msg_type_t := new_msg_type("reset qspi master reply");

  ---------------------------------------------------------------------------
  -- Private
  ---------------------------------------------------------------------------

  -- Private. The logger and checker of errors in new_qspi_master, such as an
  -- id that already has an actor.
  constant qspi_master_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:qspi_master_pkg");
  constant qspi_master_pkg_checker : checker_t := new_checker(qspi_master_pkg_logger);
end package;

package body qspi_master_pkg is

  impure function new_qspi_master (
    sck_period : delay_length := qspi_default_sck_period;
    cs_deselect_time : delay_length := qspi_default_cs_deselect_time;
    protocol_checker : qspi_protocol_checker_t := null_qspi_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return qspi_master_t is

    variable result : qspi_master_t := (
      p_sck_period => sck_period,
      p_cs_deselect_time => cs_deselect_time,
      p_protocol_checker => null_qspi_protocol_checker,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if id = null_id then
      result.p_id := enumerate(get_id("qspi_master", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_vc_actor(result.p_id, qspi_master_pkg_checker);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_protocol_checker := get_valid_protocol_checker(protocol_checker, result.p_id);

    return result;
  end;

  impure function get_id (qspi_master : qspi_master_t) return id_t is
  begin

    return qspi_master.p_id;
  end;

  impure function get_actor (qspi_master : qspi_master_t) return actor_t is
  begin

    return qspi_master.p_actor;
  end;

  impure function get_logger (qspi_master : qspi_master_t) return logger_t is
  begin

    return qspi_master.p_logger;
  end;

  impure function get_checker (qspi_master : qspi_master_t) return checker_t is
  begin

    return qspi_master.p_checker;
  end;

  impure function as_sync (qspi_master : qspi_master_t) return sync_handle_t is
  begin

    return qspi_master.p_actor;
  end;

  function sck_period (qspi_master : qspi_master_t) return delay_length is
  begin

    return qspi_master.p_sck_period;
  end;

  function cs_deselect_time (qspi_master : qspi_master_t) return delay_length is
  begin

    return qspi_master.p_cs_deselect_time;
  end;

  function protocol_checker (qspi_master : qspi_master_t) return qspi_protocol_checker_t is
  begin

    return qspi_master.p_protocol_checker;
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; qspi_master : qspi_master_t) is
  begin

    if is_already_handled(msg_type) or qspi_master.p_unexpected_msg_type_policy = ignore then
      null;
    else
      check_failed(qspi_master.p_checker, "Got unexpected message " & name(msg_type));
    end if;
  end;

  impure function new_byte_array (values : integer_vector) return integer_array_t is

    variable result : integer_array_t := new_1d(length => values'length, bit_width => 8, is_signed => false);
  begin

    for idx in 0 to values'length - 1 loop

      set(result, idx, values(values'low + idx));
    end loop;

    return result;
  end;

  -- Bytes go into the message one integer at a time rather than by reference:
  -- pushing an integer_array_t would hand ownership of the caller's array to
  -- the VC, and a caller that composes a command from a constant array would
  -- then lose it on the first call.
  procedure push_byte_phase (msg : msg_t; bytes : integer_array_t; lanes : lane_count_t) is

    variable count : natural := 0;
  begin

    if not is_null(bytes) then
      count := length(bytes);
    end if;

    push_integer(msg, count);
    push_integer(msg, lanes);
    for index in 0 to count - 1 loop

      push_integer(msg, get(bytes, index));
    end loop;

  end;

  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    variable reference : inout qspi_transfer_reference_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0;
    num_read_bytes : natural := 0;
    read_lanes : lane_count_t := 1
  ) is

    alias request_msg : msg_t is reference;
  begin

    request_msg := new_msg(transfer_qspi_master_data_msg);

    push_byte_phase(request_msg, cmd, cmd_lanes);
    push_byte_phase(request_msg, addr, addr_lanes);
    push_byte_phase(request_msg, wr_data, wr_lanes);
    push_integer(request_msg, dummy_cycles);
    push_integer(request_msg, num_read_bytes);
    push_integer(request_msg, read_lanes);

    send(net, get_actor(qspi_master), request_msg);
  end;

  procedure await_qspi_transfer_reply (
    signal net : inout network_t;
    variable reference : inout qspi_transfer_reference_t;
    variable data : inout integer_array_t
  ) is

    alias request_msg : msg_t is reference;
    variable reply_msg : msg_t;
  begin

    receive_reply(net, request_msg, reply_msg);

    if not is_null(data) then
      deallocate(data);
    end if;
    data := pop_ref(reply_msg);

    delete(request_msg);
    delete(reply_msg);
  end;

  procedure await_qspi_transfer_reply (
    signal net : inout network_t;
    variable reference : inout qspi_transfer_reference_t
  ) is

    variable data : integer_array_t := null_integer_array;
  begin

    await_qspi_transfer_reply(net, reference, data);
    deallocate(data);
  end;

  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    variable data : inout integer_array_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0;
    num_read_bytes : natural := 0;
    read_lanes : lane_count_t := 1
  ) is

    variable reference : qspi_transfer_reference_t;
  begin

    qspi_transfer(
      net => net,
      qspi_master => qspi_master,
      cmd => cmd,
      reference => reference,
      cmd_lanes => cmd_lanes,
      addr => addr,
      addr_lanes => addr_lanes,
      wr_data => wr_data,
      wr_lanes => wr_lanes,
      dummy_cycles => dummy_cycles,
      num_read_bytes => num_read_bytes,
      read_lanes => read_lanes
    );
    await_qspi_transfer_reply(net, reference, data);
  end;

  procedure qspi_transfer (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    cmd : integer_array_t;
    cmd_lanes : lane_count_t := 1;
    addr : integer_array_t := null_integer_array;
    addr_lanes : lane_count_t := 1;
    wr_data : integer_array_t := null_integer_array;
    wr_lanes : lane_count_t := 1;
    dummy_cycles : natural := 0
  ) is

    variable reference : qspi_transfer_reference_t;
  begin

    qspi_transfer(
      net => net,
      qspi_master => qspi_master,
      cmd => cmd,
      reference => reference,
      cmd_lanes => cmd_lanes,
      addr => addr,
      addr_lanes => addr_lanes,
      wr_data => wr_data,
      wr_lanes => wr_lanes,
      dummy_cycles => dummy_cycles
    );
    await_qspi_transfer_reply(net, reference);
  end;

  procedure set_sck_period (signal net : inout network_t; qspi_master : qspi_master_t; period : delay_length) is

    variable request_msg : msg_t := new_msg(set_qspi_master_sck_period_msg);
    variable reply_msg : msg_t;
  begin

    push_time(request_msg, period);
    request(net, get_actor(qspi_master), request_msg, reply_msg);
    delete(reply_msg);
  end;

  procedure reset (signal net : inout network_t; qspi_master : qspi_master_t) is

    variable request_msg : msg_t := new_msg(reset_qspi_master_msg);
    variable reply_msg : msg_t;
  begin

    request(net, get_actor(qspi_master), request_msg, reply_msg);
    delete(reply_msg);
  end;

  -- Whether the master has a protocol checker, after a check failure when not
  impure function has_protocol_checker (qspi_master : qspi_master_t) return boolean is
  begin

    if qspi_master.p_protocol_checker = null_qspi_protocol_checker then
      check_failed(qspi_master.p_checker, full_name(qspi_master.p_id) & " has no protocol checker");
      return false;
    end if;
    return true;
  end;

  procedure set_check_enabled (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    enabled : boolean := true
  ) is
  begin

    if has_protocol_checker(qspi_master) then
      set_check_enabled(net, qspi_master.p_protocol_checker, check, enabled);
    end if;
  end;

  procedure get_check_count (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    variable count : out natural
  ) is
  begin

    if has_protocol_checker(qspi_master) then
      get_check_count(net, qspi_master.p_protocol_checker, check, count);
    else
      count := 0;
    end if;
  end;

  procedure get_check_count (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  ) is
  begin

    reference := null_msg;
    if has_protocol_checker(qspi_master) then
      get_check_count(net, qspi_master.p_protocol_checker, check, reference);
    end if;
  end;

end package body;
