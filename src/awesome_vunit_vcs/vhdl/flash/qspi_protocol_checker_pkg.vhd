-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the QSPI protocol checker verification component
-- (qspi_protocol_checker.vhd).
--
-- The checker is a passive observer of a QSPI bus. It measures the intervals
-- between edges of the pins the master drives, SCK, CS and the IO lanes the
-- master drives, and reports every interval shorter than its minimum as a
-- check failure. Each rule is a :vhdl:`qspi_protocol_checker_pkg.qspi_check_t`
-- that can be switched off and has its own violation count.
--
-- A testbench instantiates the checker on a bus, or passes the handle to
-- :vhdl:`flash_pkg.new_flash` or :vhdl:`qspi_master_pkg.new_qspi_master`,
-- which then instantiate it on their own pins as a child of their id.

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

package qspi_protocol_checker_pkg is
  ---------------------------------------------------------------------------
  -- Handle
  ---------------------------------------------------------------------------

  -- The rules of the checker, named like their check IDs. A message of a
  -- violation starts with the ID in upper case, for example
  -- ``QSPI_CS_DESELECT``.
  type qspi_check_t is (
    -- SCK rising edge to the next rising edge, ``t_sck_min``
    qspi_sck_period,
    -- SCK rising edge to the next falling edge, ``t_sck_high_min``
    qspi_sck_high,
    -- SCK falling edge to the next rising edge, ``t_sck_low_min``
    qspi_sck_low,
    -- CS low to the first SCK rising edge, ``t_slch``
    qspi_cs_setup,
    -- The last SCK edge to CS high, ``t_chsh``
    qspi_cs_hold,
    -- CS high time between commands, ``t_shsl``
    qspi_cs_deselect,
    -- A driven IO lane to the SCK rising edge, ``t_dvch``
    qspi_data_setup,
    -- The SCK rising edge to a change of a driven IO lane, ``t_chdx``
    qspi_data_hold
  );

  -- The handle of a protocol checker, created with
  -- :vhdl:`qspi_protocol_checker_pkg.new_qspi_protocol_checker`. It is the
  -- generic of the qspi_protocol_checker entity and the first argument of the
  -- procedures below.
  type qspi_protocol_checker_t is record
    -- Private. Use the constructor and the accessors below.
    p_t_sck_min : delay_length;
    p_t_sck_high_min : delay_length;
    p_t_sck_low_min : delay_length;
    p_t_slch : delay_length;
    p_t_chsh : delay_length;
    p_t_shsl : delay_length;
    p_t_dvch : delay_length;
    p_t_chdx : delay_length;
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    -- Whether the constructor got them, or derived them from the id
    p_explicit_id : boolean;
    p_explicit_logger : boolean;
    p_explicit_actor : boolean;
    p_explicit_checker : boolean;
    -- The id, logger, actor and checker of a checker constructed without an
    -- id, made the first time they are needed; null_ptr for other handles
    p_identity : integer_vector_ptr_t;
  end record;

  -- No protocol checker. The default of the ``protocol_checker`` parameter
  -- of the flash and QSPI master constructors.
  constant null_qspi_protocol_checker : qspi_protocol_checker_t := (
    p_t_sck_min => 0 ns,
    p_t_sck_high_min => 0 ns,
    p_t_sck_low_min => 0 ns,
    p_t_slch => 0 ns,
    p_t_chsh => 0 ns,
    p_t_shsl => 0 ns,
    p_t_dvch => 0 ns,
    p_t_chdx => 0 ns,
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

  -- A QSPI protocol checker. The limits are the minimum times the master
  -- must meet, with the defaults of a typical 133 MHz part:
  --
  -- * ``t_sck_min``, ``t_sck_high_min``, ``t_sck_low_min``: SCK period, high
  --   and low time
  -- * ``t_slch``: CS low to the first SCK rising edge
  -- * ``t_chsh``: the last SCK edge to CS high
  -- * ``t_shsl``: CS high time between commands
  -- * ``t_dvch``, ``t_chdx``: setup and hold of the driven IO lanes around
  --   the SCK rising edge
  --
  -- A limit of 0 ns disables that rule.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:qspi_protocol_checker:<n>``. The
  -- logger defaults to the logger of the id, the actor to a new actor of the
  -- id and the checker to a checker on the logger. A flash or QSPI master
  -- given the handle moves an id, logger, actor and checker that were not
  -- given explicitly below its own id, as ``<parent id>:protocol_checker``.
  -- Without an explicit id, the default id and what derives from it are made
  -- the first time they are needed, by the checker entity or an accessor, so
  -- a checker passed to a flash or master uses up no default id and leaves no
  -- actor behind.
  -- ``unexpected_msg_type_policy`` says whether a message of an unknown type
  -- is a failure (``fail``) or ignored (``ignore``).
  impure function new_qspi_protocol_checker(
    t_sck_min : delay_length := 7519 ps;
    t_sck_high_min : delay_length := 3 ns;
    t_sck_low_min : delay_length := 3 ns;
    t_slch : delay_length := 5 ns;
    t_chsh : delay_length := 5 ns;
    t_shsl : delay_length := 30 ns;
    t_dvch : delay_length := 2 ns;
    t_chdx : delay_length := 3 ns;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return qspi_protocol_checker_t;

  -- The id, logger, actor and checker of the protocol checker, and its
  -- handle for ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id(protocol_checker : qspi_protocol_checker_t) return id_t;
  impure function get_logger(protocol_checker : qspi_protocol_checker_t) return logger_t;
  impure function get_actor(protocol_checker : qspi_protocol_checker_t) return actor_t;
  impure function get_checker(protocol_checker : qspi_protocol_checker_t) return checker_t;
  impure function as_sync(protocol_checker : qspi_protocol_checker_t) return sync_handle_t;

  -- The minimum times given to the constructor, 0 ns for a disabled rule
  function t_sck_min(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_sck_high_min(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_sck_low_min(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_slch(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_chsh(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_shsl(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_dvch(protocol_checker : qspi_protocol_checker_t) return delay_length;
  function t_chdx(protocol_checker : qspi_protocol_checker_t) return delay_length;

  -- The limit of one rule
  function limit(protocol_checker : qspi_protocol_checker_t; check : qspi_check_t) return delay_length;

  -- Handle a message type no handler took, following the unexpected message
  -- type policy of the handle like vc_pkg.unexpected_msg_type of VUnit: a
  -- check failure ``Got unexpected message <name>`` on the checker of the
  -- handle unless the policy is ignore or the message was already handled
  procedure unexpected_msg_type(msg_type : msg_type_t; protocol_checker : qspi_protocol_checker_t);

  ---------------------------------------------------------------------------
  -- Rules
  ---------------------------------------------------------------------------

  -- A pending request, redeemed with
  -- :vhdl:`qspi_protocol_checker_pkg.await_get_check_count_reply`
  alias qspi_protocol_checker_reference_t is msg_t;

  -- Enable or disable one rule. A disabled rule neither reports nor counts.
  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    enabled : boolean := true
  );

  -- Blocking: the violations of a rule found while it was enabled
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    variable count : out natural
  );

  -- Non-blocking: request the violation count of a rule
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  );

  -- Blocking: redeem a reference of
  -- :vhdl:`qspi_protocol_checker_pkg.get_check_count`
  procedure await_get_check_count_reply(
    signal net : inout network_t;
    variable reference : inout qspi_protocol_checker_reference_t;
    variable count : out natural
  );

  -- Blocking: recover the checker, for example after a reset of the bus. The
  -- violation counts of every rule return to 0 and the timing history is
  -- forgotten, such as the time CS last rose, so the first command after the
  -- reset is not measured against the edges before it. The rule switches are
  -- kept.
  procedure reset(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t
  );

  ---------------------------------------------------------------------------
  -- Message types
  ---------------------------------------------------------------------------

  -- The message types the procedures above send to the component
  constant set_qspi_protocol_checker_check_enabled_msg : msg_type_t := new_msg_type(
    "set qspi_protocol_checker check enabled"
  );
  constant get_qspi_protocol_checker_check_count_msg : msg_type_t := new_msg_type(
    "get qspi_protocol_checker check count"
  );
  constant get_qspi_protocol_checker_check_count_reply_msg : msg_type_t := new_msg_type(
    "get qspi_protocol_checker check count reply"
  );
  constant reset_qspi_protocol_checker_msg : msg_type_t := new_msg_type("reset qspi_protocol_checker");
  constant reset_qspi_protocol_checker_reply_msg : msg_type_t := new_msg_type("reset qspi_protocol_checker reply");

  ---------------------------------------------------------------------------
  -- Private, for the flash and QSPI master constructors
  ---------------------------------------------------------------------------

  -- Private. The handle a component with id parent instantiates: null stays
  -- null, and the id, logger, actor and checker the constructor derived are
  -- derived again from ``<parent>:protocol_checker``.
  impure function get_valid_protocol_checker(
    protocol_checker : qspi_protocol_checker_t;
    parent : id_t
  ) return qspi_protocol_checker_t;

  -- Private. The logger and checker of errors in the constructors of the
  -- flash family, such as an id that already has an actor.
  constant qspi_protocol_checker_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:qspi_protocol_checker_pkg");
  constant qspi_protocol_checker_pkg_checker : checker_t := new_checker(qspi_protocol_checker_pkg_logger);

  -- Private. A new actor for id, or an anonymous one after a check failure
  -- when id already has an actor.
  impure function new_vc_actor(id : id_t; pkg_checker : checker_t) return actor_t;
end package;

package body qspi_protocol_checker_pkg is
  impure function new_vc_actor(id : id_t; pkg_checker : checker_t) return actor_t is
  begin
    if find(id, enable_deferred_creation => false) /= null_actor then
      check_failed(pkg_checker, "An actor already exists for " & full_name(id) & ".");
      return new_actor;
    end if;
    return new_actor(id);
  end;

  -- The handle with its identity. A checker constructed without an id gets
  -- the default id, and the logger, actor and checker that derive from it,
  -- the first time this is called, and the same identity every time after.
  impure function resolved(protocol_checker : qspi_protocol_checker_t) return qspi_protocol_checker_t is
    constant identity : integer_vector_ptr_t := protocol_checker.p_identity;
    variable result : qspi_protocol_checker_t := protocol_checker;
  begin
    if identity = null_ptr then
      return result;
    end if;

    if get(identity, 0) < 0 then
      result.p_id := enumerate(get_id("qspi_protocol_checker", parent => get_id("awesome_vunit_vcs")));
      if not result.p_explicit_logger then
        result.p_logger := get_logger(result.p_id);
      end if;
      if not result.p_explicit_actor then
        result.p_actor := new_vc_actor(result.p_id, qspi_protocol_checker_pkg_checker);
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

  impure function new_qspi_protocol_checker(
    t_sck_min : delay_length := 7519 ps;
    t_sck_high_min : delay_length := 3 ns;
    t_sck_low_min : delay_length := 3 ns;
    t_slch : delay_length := 5 ns;
    t_chsh : delay_length := 5 ns;
    t_shsl : delay_length := 30 ns;
    t_dvch : delay_length := 2 ns;
    t_chdx : delay_length := 3 ns;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return qspi_protocol_checker_t is
    variable result : qspi_protocol_checker_t;
  begin
    result := (
      p_t_sck_min => t_sck_min,
      p_t_sck_high_min => t_sck_high_min,
      p_t_sck_low_min => t_sck_low_min,
      p_t_slch => t_slch,
      p_t_chsh => t_chsh,
      p_t_shsl => t_shsl,
      p_t_dvch => t_dvch,
      p_t_chdx => t_chdx,
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
    if not result.p_explicit_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if not result.p_explicit_actor then
      result.p_actor := new_vc_actor(result.p_id, qspi_protocol_checker_pkg_checker);
    end if;
    if not result.p_explicit_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;

    return result;
  end;

  impure function get_valid_protocol_checker(
    protocol_checker : qspi_protocol_checker_t;
    parent : id_t
  ) return qspi_protocol_checker_t is
    variable result : qspi_protocol_checker_t := protocol_checker;
  begin
    if protocol_checker = null_qspi_protocol_checker or protocol_checker.p_explicit_id then
      return protocol_checker;
    end if;

    result.p_id := get_id("protocol_checker", parent => parent);
    if not result.p_explicit_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if not result.p_explicit_actor then
      result.p_actor := new_vc_actor(result.p_id, qspi_protocol_checker_pkg_checker);
    end if;
    if not result.p_explicit_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_identity := null_ptr;

    return result;
  end;

  impure function get_id(protocol_checker : qspi_protocol_checker_t) return id_t is
  begin
    return resolved(protocol_checker).p_id;
  end;

  impure function get_logger(protocol_checker : qspi_protocol_checker_t) return logger_t is
  begin
    return resolved(protocol_checker).p_logger;
  end;

  impure function get_actor(protocol_checker : qspi_protocol_checker_t) return actor_t is
  begin
    return resolved(protocol_checker).p_actor;
  end;

  impure function get_checker(protocol_checker : qspi_protocol_checker_t) return checker_t is
  begin
    return resolved(protocol_checker).p_checker;
  end;

  impure function as_sync(protocol_checker : qspi_protocol_checker_t) return sync_handle_t is
  begin
    return get_actor(protocol_checker);
  end;

  function t_sck_min(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_sck_min;
  end;

  function t_sck_high_min(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_sck_high_min;
  end;

  function t_sck_low_min(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_sck_low_min;
  end;

  function t_slch(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_slch;
  end;

  function t_chsh(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_chsh;
  end;

  function t_shsl(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_shsl;
  end;

  function t_dvch(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_dvch;
  end;

  function t_chdx(protocol_checker : qspi_protocol_checker_t) return delay_length is
  begin
    return protocol_checker.p_t_chdx;
  end;

  function limit(protocol_checker : qspi_protocol_checker_t; check : qspi_check_t) return delay_length is
  begin
    case check is
      when qspi_sck_period => return protocol_checker.p_t_sck_min;
      when qspi_sck_high => return protocol_checker.p_t_sck_high_min;
      when qspi_sck_low => return protocol_checker.p_t_sck_low_min;
      when qspi_cs_setup => return protocol_checker.p_t_slch;
      when qspi_cs_hold => return protocol_checker.p_t_chsh;
      when qspi_cs_deselect => return protocol_checker.p_t_shsl;
      when qspi_data_setup => return protocol_checker.p_t_dvch;
      when qspi_data_hold => return protocol_checker.p_t_chdx;
    end case;
  end;

  procedure unexpected_msg_type(msg_type : msg_type_t; protocol_checker : qspi_protocol_checker_t) is
  begin
    if is_already_handled(msg_type) or protocol_checker.p_unexpected_msg_type_policy = ignore then
      null;
    else
      check_failed(get_checker(protocol_checker), "Got unexpected message " & name(msg_type));
    end if;
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    enabled : boolean := true
  ) is
    variable msg : msg_t := new_msg(set_qspi_protocol_checker_check_enabled_msg);
  begin
    push(msg, qspi_check_t'pos(check));
    push(msg, enabled);
    send(net, get_actor(protocol_checker), msg);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  ) is
  begin
    reference := new_msg(get_qspi_protocol_checker_check_count_msg);
    push(reference, qspi_check_t'pos(check));
    send(net, get_actor(protocol_checker), reference);
  end;

  procedure await_get_check_count_reply(
    signal net : inout network_t;
    variable reference : inout qspi_protocol_checker_reference_t;
    variable count : out natural
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    count := pop(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t;
    check : qspi_check_t;
    variable count : out natural
  ) is
    variable reference : qspi_protocol_checker_reference_t;
  begin
    get_check_count(net, protocol_checker, check, reference);
    await_get_check_count_reply(net, reference, count);
  end;

  procedure reset(
    signal net : inout network_t;
    protocol_checker : qspi_protocol_checker_t
  ) is
    variable request_msg : msg_t := new_msg(reset_qspi_protocol_checker_msg);
    variable reply_msg : msg_t;
  begin
    request(net, get_actor(protocol_checker), request_msg, reply_msg);
    delete(reply_msg);
  end;
end package body;
