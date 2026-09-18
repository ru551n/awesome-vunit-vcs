-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the I2C protocol checker verification component
-- (i2c_protocol_checker.vhd).
--
-- The checker observes SCL and SDA and never drives them. It records every
-- change of the lines with its time and its Python backend checks the timing
-- and the bit-level protocol. Each check is an
-- :vhdl:`i2c_pkg.i2c_check_t` that can be switched off and has its own
-- violation count.
--
-- A testbench instantiates the checker on a bus, or passes the handle to
-- :vhdl:`i2c_monitor_pkg.new_i2c_monitor`, which then instantiates it on its
-- own pins as a child of its id.

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.vc_python_pkg.arg_text;
  use work.vc_python_pkg.kwarg_time;

package i2c_protocol_checker_pkg is

  -- The handle of a protocol checker, created with
  -- :vhdl:`i2c_protocol_checker_pkg.new_i2c_protocol_checker`
  type i2c_protocol_checker_t is record
    -- Private. Use the constructor and the accessors below.
    p_speed                      : i2c_speed_t;
    p_f_scl_max_hz               : natural;
    p_t_hd_sta                   : delay_length;
    p_t_low                      : delay_length;
    p_t_high                     : delay_length;
    p_t_su_sta                   : delay_length;
    p_t_hd_dat                   : delay_length;
    p_t_su_dat                   : delay_length;
    p_t_su_sto                   : delay_length;
    p_t_buf                      : delay_length;
    p_t_stuck                    : delay_length;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    -- Whether the constructor got them, or derived them from the id
    p_explicit_id                : boolean;
    p_explicit_logger            : boolean;
    p_explicit_actor             : boolean;
    p_explicit_checker           : boolean;
    -- The id, logger, actor and checker of a checker constructed without an
    -- id, made the first time they are needed; null_ptr for other handles
    p_identity                   : integer_vector_ptr_t;
  end record;

  -- No protocol checker, the default of ``protocol_checker`` of
  -- :vhdl:`i2c_monitor_pkg.new_i2c_monitor`
  constant null_i2c_protocol_checker : i2c_protocol_checker_t := (
    p_speed => i2c_standard_mode,
    p_f_scl_max_hz => 0,
    p_t_hd_sta => 0 ns,
    p_t_low => 0 ns,
    p_t_high => 0 ns,
    p_t_su_sta => 0 ns,
    p_t_hd_dat => 0 ns,
    p_t_su_dat => 0 ns,
    p_t_su_sto => 0 ns,
    p_t_buf => 0 ns,
    p_t_stuck => 0 ns,
    p_id => null_id,
    p_logger => null_logger,
    p_actor => null_actor,
    p_checker => null_checker,
    p_unexpected_msg_type_policy => fail,
    p_explicit_id => false,
    p_explicit_logger => false,
    p_explicit_actor => false,
    p_explicit_checker => false,
    p_identity => null_ptr
  );

  -- An I2C protocol checker. The limits are those of ``speed``:
  --
  -- * ``f_scl_max_hz``: the highest SCL frequency, checked between rising
  --   edges of SCL
  -- * ``t_hd_sta``, ``t_su_sta``: hold time of a START, setup time of a
  --   repeated START
  -- * ``t_low``, ``t_high``: low and high period of SCL
  -- * ``t_hd_dat``, ``t_su_dat``: data hold after SCL falls and setup before
  --   SCL rises
  -- * ``t_su_sto``: setup time of a STOP
  -- * ``t_buf``: bus free time between a STOP and a START
  --
  -- A limit of 0 keeps the value of the speed mode; switch a check off with
  -- :vhdl:`i2c_protocol_checker_pkg.set_check_enabled`. ``t_stuck`` is how
  -- long SCL or SDA may stay low, 0 ns to never report it.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:i2c_protocol_checker:<n>``, made
  -- the first time it is needed, so a checker given to a monitor uses up no
  -- default id. A monitor given the handle moves an id, logger, actor and
  -- checker that were not given explicitly below its own id, as
  -- ``<monitor id>:protocol_checker``.
  impure function new_i2c_protocol_checker (
    speed : i2c_speed_t := i2c_standard_mode;
    f_scl_max_hz : natural := 0;
    t_hd_sta : delay_length := 0 ns;
    t_low : delay_length := 0 ns;
    t_high : delay_length := 0 ns;
    t_su_sta : delay_length := 0 ns;
    t_hd_dat : delay_length := 0 ns;
    t_su_dat : delay_length := 0 ns;
    t_su_sto : delay_length := 0 ns;
    t_buf : delay_length := 0 ns;
    t_stuck : delay_length := 35 ms;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_protocol_checker_t;

  -- The id, logger, actor and checker of the protocol checker, and its
  -- handle for ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id (protocol_checker : i2c_protocol_checker_t) return id_t;
  impure function get_logger (protocol_checker : i2c_protocol_checker_t) return logger_t;
  impure function get_actor (protocol_checker : i2c_protocol_checker_t) return actor_t;
  impure function get_checker (protocol_checker : i2c_protocol_checker_t) return checker_t;
  impure function as_sync (protocol_checker : i2c_protocol_checker_t) return sync_handle_t;

  -- The speed mode and the stuck-low time given to the constructor
  function speed (protocol_checker : i2c_protocol_checker_t) return i2c_speed_t;
  function t_stuck (protocol_checker : i2c_protocol_checker_t) return delay_length;

  -- A pending request, redeemed with
  -- :vhdl:`i2c_protocol_checker_pkg.await_get_check_count_reply`
  alias i2c_protocol_checker_reference_t is msg_t;

  -- Enable or disable one check. A disabled check neither reports nor counts.
  -- ``i2c_scoreboard`` belongs to the monitor and is a failure here.
  procedure set_check_enabled (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    enabled : boolean := true
  );

  -- Blocking: the violations of a check found while it was enabled
  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    variable count : out natural
  );

  -- Non-blocking: request the violation count of a check
  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    variable reference : inout i2c_protocol_checker_reference_t
  );

  -- Blocking: redeem a reference of
  -- :vhdl:`i2c_protocol_checker_pkg.get_check_count`
  procedure await_get_check_count_reply (
    signal net : inout network_t;
    variable reference : inout i2c_protocol_checker_reference_t;
    variable count : out natural
  );

  -- Blocking: recover the checker, for example after a reset of the bus. The
  -- violation counts return to 0 and the timing history is forgotten; the
  -- check switches are kept.
  procedure reset (signal net : inout network_t; protocol_checker : i2c_protocol_checker_t);

  -- The message types the procedures above send to the component
  constant set_i2c_check_enabled_msg : msg_type_t := new_msg_type("set i2c check enabled");
  constant get_i2c_check_count_msg : msg_type_t := new_msg_type("get i2c check count");
  constant get_i2c_check_count_reply_msg : msg_type_t := new_msg_type("get i2c check count reply");
  constant reset_i2c_protocol_checker_msg : msg_type_t := new_msg_type("reset i2c protocol checker");
  constant reset_i2c_protocol_checker_reply_msg : msg_type_t := new_msg_type("reset i2c protocol checker reply");

  -- Private. The handle a monitor with id parent instantiates: null stays
  -- null, and the id, logger, actor and checker the constructor derived are
  -- derived again from ``<parent>:protocol_checker``.
  impure function get_valid_protocol_checker (
    protocol_checker : i2c_protocol_checker_t;
    parent : id_t
  ) return i2c_protocol_checker_t;

  -- Private. The constructor arguments of the backend.
  impure function backend_arguments (protocol_checker : i2c_protocol_checker_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`i2c_pkg.i2c_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; protocol_checker : i2c_protocol_checker_t);
end package;

package body i2c_protocol_checker_pkg is

  -- The handle with its identity, made the first time it is needed for a
  -- checker constructed without an id
  impure function resolved (protocol_checker : i2c_protocol_checker_t) return i2c_protocol_checker_t is

    constant identity : integer_vector_ptr_t := protocol_checker.p_identity;
    variable result : i2c_protocol_checker_t := protocol_checker;
  begin

    if identity = null_ptr then
      return result;
    end if;

    if get(identity, 0) < 0 then
      result.p_id := enumerate(get_id("i2c_protocol_checker", parent => get_id("awesome_vunit_vcs")));
      if not result.p_explicit_logger then
        result.p_logger := get_logger(result.p_id);
      end if;
      if not result.p_explicit_actor then
        result.p_actor := new_i2c_actor(result.p_id);
      end if;
      if not result.p_explicit_checker then
        result.p_checker := new_checker(result.p_logger);
      end if;
      set(identity, 0, to_integer(result.p_id));
      set(identity, 1, to_integer(result.p_logger));
      set(identity, 2, to_integer(result.p_actor));
      set(identity, 3, to_integer(result.p_checker));
    end if;

    result.p_id := to_id(get(identity, 0));
    result.p_logger := to_logger(get(identity, 1));
    result.p_actor := to_actor(get(identity, 2));
    result.p_checker := to_checker(get(identity, 3));
    return result;
  end;

  -- The logger, actor and checker of id that were not given explicitly
  impure function derived (protocol_checker : i2c_protocol_checker_t; id : id_t) return i2c_protocol_checker_t is

    variable result : i2c_protocol_checker_t := protocol_checker;
  begin

    result.p_id := id;
    if not result.p_explicit_logger then
      result.p_logger := get_logger(id);
    end if;
    if not result.p_explicit_actor then
      result.p_actor := new_i2c_actor(id);
    end if;
    if not result.p_explicit_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_identity := null_ptr;
    return result;
  end;

  impure function new_i2c_protocol_checker (
    speed : i2c_speed_t := i2c_standard_mode;
    f_scl_max_hz : natural := 0;
    t_hd_sta : delay_length := 0 ns;
    t_low : delay_length := 0 ns;
    t_high : delay_length := 0 ns;
    t_su_sta : delay_length := 0 ns;
    t_hd_dat : delay_length := 0 ns;
    t_su_dat : delay_length := 0 ns;
    t_su_sto : delay_length := 0 ns;
    t_buf : delay_length := 0 ns;
    t_stuck : delay_length := 35 ms;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_protocol_checker_t is

    variable result : i2c_protocol_checker_t;
  begin

    result := (
      p_speed => speed,
      p_f_scl_max_hz => f_scl_max_hz,
      p_t_hd_sta => t_hd_sta,
      p_t_low => t_low,
      p_t_high => t_high,
      p_t_su_sta => t_su_sta,
      p_t_hd_dat => t_hd_dat,
      p_t_su_dat => t_su_dat,
      p_t_su_sto => t_su_sto,
      p_t_buf => t_buf,
      p_t_stuck => t_stuck,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_explicit_id => id /= null_id,
      p_explicit_logger => logger /= null_logger,
      p_explicit_actor => actor /= null_actor,
      p_explicit_checker => checker /= null_checker,
      p_identity => null_ptr
    );

    if not result.p_explicit_id then
      -- Made when first needed, see resolved
      result.p_identity := new_integer_vector_ptr(4, value => -1);
      return result;
    end if;
    return derived(result, id);
  end;

  impure function get_valid_protocol_checker (
    protocol_checker : i2c_protocol_checker_t;
    parent : id_t
  ) return i2c_protocol_checker_t is
  begin

    if protocol_checker = null_i2c_protocol_checker or protocol_checker.p_explicit_id then
      return protocol_checker;
    end if;
    return derived(protocol_checker, get_id("protocol_checker", parent => parent));
  end;

  impure function get_id (protocol_checker : i2c_protocol_checker_t) return id_t is
  begin

    return resolved(protocol_checker).p_id;
  end;

  impure function get_logger (protocol_checker : i2c_protocol_checker_t) return logger_t is
  begin

    return resolved(protocol_checker).p_logger;
  end;

  impure function get_actor (protocol_checker : i2c_protocol_checker_t) return actor_t is
  begin

    return resolved(protocol_checker).p_actor;
  end;

  impure function get_checker (protocol_checker : i2c_protocol_checker_t) return checker_t is
  begin

    return resolved(protocol_checker).p_checker;
  end;

  impure function as_sync (protocol_checker : i2c_protocol_checker_t) return sync_handle_t is
  begin

    return get_actor(protocol_checker);
  end;

  function speed (protocol_checker : i2c_protocol_checker_t) return i2c_speed_t is
  begin

    return protocol_checker.p_speed;
  end;

  function t_stuck (protocol_checker : i2c_protocol_checker_t) return delay_length is
  begin

    return protocol_checker.p_t_stuck;
  end;

  impure function backend_arguments (protocol_checker : i2c_protocol_checker_t) return arg_t is
  begin

    return arg_text(full_name(get_id(protocol_checker)))
           & arg(i2c_speed_t'pos(protocol_checker.p_speed))
           & kwarg("f_scl_max", protocol_checker.p_f_scl_max_hz)
           & kwarg_time("t_hd_sta", protocol_checker.p_t_hd_sta)
           & kwarg_time("t_low", protocol_checker.p_t_low)
           & kwarg_time("t_high", protocol_checker.p_t_high)
           & kwarg_time("t_su_sta", protocol_checker.p_t_su_sta)
           & kwarg_time("t_hd_dat", protocol_checker.p_t_hd_dat)
           & kwarg_time("t_su_dat", protocol_checker.p_t_su_dat)
           & kwarg_time("t_su_sto", protocol_checker.p_t_su_sto)
           & kwarg_time("t_buf", protocol_checker.p_t_buf)
           & kwarg_time("t_stuck", protocol_checker.p_t_stuck);
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; protocol_checker : i2c_protocol_checker_t) is
  begin

    i2c_unexpected_msg_type(msg_type, protocol_checker.p_unexpected_msg_type_policy, get_checker(protocol_checker));
  end;

  procedure set_check_enabled (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    enabled : boolean := true
  ) is

    variable msg : msg_t := new_msg(set_i2c_check_enabled_msg);
  begin

    push(msg, i2c_check_t'pos(check));
    push(msg, enabled);
    send(net, get_actor(protocol_checker), msg);
  end;

  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    variable reference : inout i2c_protocol_checker_reference_t
  ) is
  begin

    reference := new_msg(get_i2c_check_count_msg);
    push(reference, i2c_check_t'pos(check));
    send(net, get_actor(protocol_checker), reference);
  end;

  procedure await_get_check_count_reply (
    signal net : inout network_t;
    variable reference : inout i2c_protocol_checker_reference_t;
    variable count : out natural
  ) is

    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    count := pop(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : i2c_protocol_checker_t;
    check : i2c_check_t;
    variable count : out natural
  ) is

    variable reference : i2c_protocol_checker_reference_t;
  begin

    get_check_count(net, protocol_checker, check, reference);
    await_get_check_count_reply(net, reference, count);
  end;

  procedure reset (signal net : inout network_t; protocol_checker : i2c_protocol_checker_t) is

    variable request_msg : msg_t := new_msg(reset_i2c_protocol_checker_msg);
    variable reply_msg : msg_t;
  begin

    request(net, get_actor(protocol_checker), request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
