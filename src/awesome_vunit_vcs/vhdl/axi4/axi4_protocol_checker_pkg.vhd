-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the AXI4 protocol checker verification component
-- (axi4_protocol_checker.vhd).
--
-- The checker observes the five channels of an AXI4 or AXI4-Lite interface
-- and never drives them. It records what happens at every rising edge of
-- ACLK and its Python backend checks the protocol. Each check is an
-- :vhdl:`axi4_pkg.axi4_check_t` that can be switched off and has its own
-- violation count.
--
-- A testbench instantiates the checker on an interface, or passes the handle
-- to :vhdl:`axi4_monitor_pkg.new_axi4_monitor`, which then instantiates it on
-- its own pins as a child of its id.

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.axi4_pkg.all;
  use work.vc_python_pkg.arg_text;

package axi4_protocol_checker_pkg is

  -- The handle of a protocol checker, created with
  -- :vhdl:`axi4_protocol_checker_pkg.new_axi4_protocol_checker`
  type axi4_protocol_checker_t is record
    -- Private. Use the constructor and the accessors below.
    p_bus                        : axi4_bus_t;
    p_timeout_cycles             : natural;
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
  -- :vhdl:`axi4_monitor_pkg.new_axi4_monitor`
  constant null_axi4_protocol_checker : axi4_protocol_checker_t := (
    p_bus => default_axi4_bus,
    p_timeout_cycles => 0,
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

  -- An AXI4 protocol checker of an interface with the widths of
  -- ``axi4_bus``. A monitor given the checker gives it its own bus.
  -- ``timeout_cycles`` is how many clock cycles a transaction may wait for
  -- its response, write data for its address, and VALID for READY, before
  -- ``AXI4_TIMEOUT``; 0 never reports it. The checker reports what it found
  -- at least every ``timeout_cycles`` cycles.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:axi4_protocol_checker:<n>``, made
  -- the first time it is needed, so a checker given to a monitor uses up no
  -- default id. A monitor given the handle moves an id, logger, actor and
  -- checker that were not given explicitly below its own id, as
  -- ``<monitor id>:protocol_checker``.
  impure function new_axi4_protocol_checker (
    axi4_bus : axi4_bus_t := default_axi4_bus;
    timeout_cycles : natural := 1000;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_protocol_checker_t;

  -- The id, logger, actor and checker of the protocol checker, and its
  -- handle for ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``.
  -- ``wait_until_idle`` returns when Python has checked everything sampled
  -- so far.
  impure function get_id (protocol_checker : axi4_protocol_checker_t) return id_t;
  impure function get_logger (protocol_checker : axi4_protocol_checker_t) return logger_t;
  impure function get_actor (protocol_checker : axi4_protocol_checker_t) return actor_t;
  impure function get_checker (protocol_checker : axi4_protocol_checker_t) return checker_t;
  impure function as_sync (protocol_checker : axi4_protocol_checker_t) return sync_handle_t;

  -- The widths of the interface, for the ports of the entity
  function get_bus (protocol_checker : axi4_protocol_checker_t) return axi4_bus_t;

  -- The timeout given to the constructor
  function timeout_cycles (protocol_checker : axi4_protocol_checker_t) return natural;

  -- A pending request, redeemed with
  -- :vhdl:`axi4_protocol_checker_pkg.await_get_check_count_reply`
  alias axi4_protocol_checker_reference_t is msg_t;

  -- Enable or disable one check. A disabled check neither reports nor counts.
  -- ``axi4_scoreboard`` belongs to the monitor and is a failure here.
  procedure set_check_enabled (
    signal net : inout network_t;
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    enabled : boolean := true
  );

  -- Blocking: the violations of a check found while it was enabled
  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    variable count : out natural
  );

  -- Non-blocking: request the violation count of a check
  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    variable reference : inout axi4_protocol_checker_reference_t
  );

  -- Blocking: redeem a reference of
  -- :vhdl:`axi4_protocol_checker_pkg.get_check_count`
  procedure await_get_check_count_reply (
    signal net : inout network_t;
    variable reference : inout axi4_protocol_checker_reference_t;
    variable count : out natural
  );

  -- Blocking: recover the checker, for example after a reset of the design.
  -- The violation counts return to 0 and the history of the bus, outstanding
  -- transactions included, is forgotten; the check switches are kept.
  procedure reset (signal net : inout network_t; protocol_checker : axi4_protocol_checker_t);

  -- The message types the procedures above send to the component
  constant set_axi4_check_enabled_msg : msg_type_t := new_msg_type("set axi4 check enabled");
  constant get_axi4_check_count_msg : msg_type_t := new_msg_type("get axi4 check count");
  constant get_axi4_check_count_reply_msg : msg_type_t := new_msg_type("get axi4 check count reply");
  constant reset_axi4_protocol_checker_msg : msg_type_t := new_msg_type("reset axi4 protocol checker");
  constant reset_axi4_protocol_checker_reply_msg : msg_type_t := new_msg_type("reset axi4 protocol checker reply");

  -- Private. The handle a monitor with id parent instantiates on a bus: null
  -- stays null, the bus becomes that of the monitor, and the id, logger,
  -- actor and checker the constructor derived are derived again from
  -- ``<parent>:protocol_checker``.
  impure function get_valid_protocol_checker (
    protocol_checker : axi4_protocol_checker_t;
    parent : id_t;
    axi4_bus : axi4_bus_t
  ) return axi4_protocol_checker_t;

  -- Private. The constructor arguments of the backend.
  impure function backend_arguments (protocol_checker : axi4_protocol_checker_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`axi4_pkg.axi4_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; protocol_checker : axi4_protocol_checker_t);
end package;

package body axi4_protocol_checker_pkg is

  -- The handle with its identity, made the first time it is needed for a
  -- checker constructed without an id
  impure function resolved (protocol_checker : axi4_protocol_checker_t) return axi4_protocol_checker_t is

    constant identity : integer_vector_ptr_t := protocol_checker.p_identity;
    variable result : axi4_protocol_checker_t := protocol_checker;
  begin

    if identity = null_ptr then
      return result;
    end if;

    if get(identity, 0) < 0 then
      result.p_id := enumerate(get_id("axi4_protocol_checker", parent => get_id("awesome_vunit_vcs")));
      if not result.p_explicit_logger then
        result.p_logger := get_logger(result.p_id);
      end if;
      if not result.p_explicit_actor then
        result.p_actor := new_axi4_actor(result.p_id);
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
  impure function derived (protocol_checker : axi4_protocol_checker_t; id : id_t) return axi4_protocol_checker_t is

    variable result : axi4_protocol_checker_t := protocol_checker;
  begin

    result.p_id := id;
    if not result.p_explicit_logger then
      result.p_logger := get_logger(id);
    end if;
    if not result.p_explicit_actor then
      result.p_actor := new_axi4_actor(id);
    end if;
    if not result.p_explicit_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_identity := null_ptr;
    return result;
  end;

  impure function new_axi4_protocol_checker (
    axi4_bus : axi4_bus_t := default_axi4_bus;
    timeout_cycles : natural := 1000;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_protocol_checker_t is

    variable result : axi4_protocol_checker_t;
  begin

    result := (
      p_bus => axi4_bus,
      p_timeout_cycles => timeout_cycles,
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
    protocol_checker : axi4_protocol_checker_t;
    parent : id_t;
    axi4_bus : axi4_bus_t
  ) return axi4_protocol_checker_t is

    variable result : axi4_protocol_checker_t := protocol_checker;
  begin

    if protocol_checker = null_axi4_protocol_checker then
      return protocol_checker;
    end if;
    result.p_bus := axi4_bus;
    if protocol_checker.p_explicit_id then
      return result;
    end if;
    return derived(result, get_id("protocol_checker", parent => parent));
  end;

  impure function get_id (protocol_checker : axi4_protocol_checker_t) return id_t is
  begin

    return resolved(protocol_checker).p_id;
  end;

  impure function get_logger (protocol_checker : axi4_protocol_checker_t) return logger_t is
  begin

    return resolved(protocol_checker).p_logger;
  end;

  impure function get_actor (protocol_checker : axi4_protocol_checker_t) return actor_t is
  begin

    return resolved(protocol_checker).p_actor;
  end;

  impure function get_checker (protocol_checker : axi4_protocol_checker_t) return checker_t is
  begin

    return resolved(protocol_checker).p_checker;
  end;

  impure function as_sync (protocol_checker : axi4_protocol_checker_t) return sync_handle_t is
  begin

    return get_actor(protocol_checker);
  end;

  function get_bus (protocol_checker : axi4_protocol_checker_t) return axi4_bus_t is
  begin

    return protocol_checker.p_bus;
  end;

  function timeout_cycles (protocol_checker : axi4_protocol_checker_t) return natural is
  begin

    return protocol_checker.p_timeout_cycles;
  end;

  impure function backend_arguments (protocol_checker : axi4_protocol_checker_t) return arg_t is
  begin

    return arg_text(full_name(get_id(protocol_checker)))
           & backend_bus_arguments(protocol_checker.p_bus)
           & kwarg("timeout_cycles", protocol_checker.p_timeout_cycles);
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; protocol_checker : axi4_protocol_checker_t) is
  begin

    axi4_unexpected_msg_type(msg_type, protocol_checker.p_unexpected_msg_type_policy, get_checker(protocol_checker));
  end;

  procedure set_check_enabled (
    signal net : inout network_t;
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    enabled : boolean := true
  ) is

    variable msg : msg_t := new_msg(set_axi4_check_enabled_msg);
  begin

    push(msg, axi4_check_t'pos(check));
    push(msg, enabled);
    send(net, get_actor(protocol_checker), msg);
  end;

  procedure get_check_count (
    signal net : inout network_t;
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    variable reference : inout axi4_protocol_checker_reference_t
  ) is
  begin

    reference := new_msg(get_axi4_check_count_msg);
    push(reference, axi4_check_t'pos(check));
    send(net, get_actor(protocol_checker), reference);
  end;

  procedure await_get_check_count_reply (
    signal net : inout network_t;
    variable reference : inout axi4_protocol_checker_reference_t;
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
    protocol_checker : axi4_protocol_checker_t;
    check : axi4_check_t;
    variable count : out natural
  ) is

    variable reference : axi4_protocol_checker_reference_t;
  begin

    get_check_count(net, protocol_checker, check, reference);
    await_get_check_count_reply(net, reference, count);
  end;

  procedure reset (signal net : inout network_t; protocol_checker : axi4_protocol_checker_t) is

    variable request_msg : msg_t := new_msg(reset_axi4_protocol_checker_msg);
    variable reply_msg : msg_t;
  begin

    request(net, get_actor(protocol_checker), request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
