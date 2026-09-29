-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the MDIO PHY verification component
-- (mdio_phy.vhd).
--
-- The PHY answers Clause 22 frames to its address from a Python device model,
-- by default a file of 32 registers of 16 bits (``"registers"``), or a class of
-- your own (``"package.module:Class"``). The component samples and drives MDIO;
-- the model decides what a read returns and what a write does.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.string_ptr_pkg.all;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.mdio_pkg.all;
use work.vc_python_pkg.arg_text;

package mdio_phy_pkg is

  -- The handle of a PHY, created with :vhdl:`mdio_phy_pkg.new_mdio_phy`
  type mdio_phy_t is record
    -- Private. Use the constructor and the accessors below.
    p_phy_address                : natural;
    p_clock_to_output_delay      : delay_length;
    p_preamble_bits              : natural;
    p_model                      : string_ptr_t;
    p_model_args_name            : string_ptr_t;
    p_model_args_value           : string_ptr_t;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- A Clause 22 PHY at ``phy_address``, 0 to 31.
  --
  -- * ``clock_to_output_delay``: the PHY changes MDIO this long after a rising
  --   MDC edge in a read, 0 ns to :vhdl:`mdio_pkg.mdio_max_clock_to_output_delay`.
  -- * ``preamble_bits``: the preamble ones the PHY needs before ST, 0 to accept
  --   frames with a suppressed preamble.
  -- * ``model`` names the device model: ``"registers"`` (``MdioDevice``) or
  --   ``"package.module:Class"``, a subclass of ``MdioDevice``. ``model_args``
  --   are its arguments, built with the bridge's ``kwarg``.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:mdio_phy:<n>``. The logger defaults
  -- to the logger of the id, the actor to a new actor of the id and the
  -- checker to a checker on the logger.
  impure function new_mdio_phy (
    phy_address : natural;
    clock_to_output_delay : delay_length := 0 ns;
    preamble_bits : natural := 32;
    model : string := "registers";
    model_args : arg_t := null_arg;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mdio_phy_t;

  -- The id, logger, actor and checker of the PHY, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id (phy : mdio_phy_t) return id_t;
  impure function get_logger (phy : mdio_phy_t) return logger_t;
  impure function get_actor (phy : mdio_phy_t) return actor_t;
  impure function get_checker (phy : mdio_phy_t) return checker_t;
  impure function as_sync (phy : mdio_phy_t) return sync_handle_t;

  -- The address, clock-to-output delay and preamble length given to the constructor
  function phy_address (phy : mdio_phy_t) return natural;
  function clock_to_output_delay (phy : mdio_phy_t) return delay_length;
  function preamble_bits (phy : mdio_phy_t) return natural;

  -- Change MDIO this long after a rising MDC edge in reads from now on, 0 ns
  -- to :vhdl:`mdio_pkg.mdio_max_clock_to_output_delay`
  procedure set_mdio_phy_clock_to_output_delay(
    signal net : inout network_t;
    phy : mdio_phy_t;
    delay : delay_length
  );

  -- Set a register of the model directly, without the bus and without side
  -- effects of the model
  procedure set_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    value : std_ulogic_vector(15 downto 0)
  );

  -- Compare a register of the model with ``expected``. A difference is a check
  -- failure (``MDIO_REGISTER``) on the checker of the PHY, prefixed with msg.
  procedure check_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    expected : std_ulogic_vector(15 downto 0);
    msg : string := ""
  );

  -- A pending request, redeemed with the matching await procedure
  alias mdio_phy_reference_t is msg_t;

  -- Non-blocking: read a register of the model directly, without the bus
  procedure get_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    variable reference : inout mdio_phy_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`mdio_phy_pkg.get_mdio_phy_register`
  procedure await_get_mdio_phy_register_reply(
    signal net : inout network_t;
    variable reference : inout mdio_phy_reference_t;
    variable value : out std_ulogic_vector(15 downto 0)
  );

  -- Blocking: read a register of the model directly, without the bus
  procedure get_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    variable value : out std_ulogic_vector(15 downto 0)
  );

  -- Blocking: the number of frames the PHY answered, to ``register_address``
  -- only unless it is -1. A frame with a violation is not counted.
  procedure get_mdio_phy_access_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    variable count : out natural;
    register_address : integer := -1
  );

  -- Blocking: the number of ``operation`` frames the PHY answered, to
  -- ``register_address`` only unless it is -1
  procedure get_mdio_phy_access_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    operation : mdio_operation_t;
    variable count : out natural;
    register_address : integer := -1
  );

  -- Blocking: the number of violations of ``check`` the PHY found
  procedure get_mdio_phy_check_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    check : mdio_check_t;
    variable count : out natural
  );

  -- Blocking: recover a PHY. It releases MDIO and forgets a frame in progress;
  -- the model keeps its registers.
  procedure reset(signal net : inout network_t; phy : mdio_phy_t);

  -- The message types the procedures above send to the component
  constant set_mdio_phy_clock_to_output_delay_msg : msg_type_t :=
    new_msg_type("set mdio phy clock to output delay");
  constant set_mdio_phy_register_msg : msg_type_t := new_msg_type("set mdio phy register");
  constant check_mdio_phy_register_msg : msg_type_t := new_msg_type("check mdio phy register");
  constant get_mdio_phy_register_msg : msg_type_t := new_msg_type("get mdio phy register");
  constant get_mdio_phy_register_reply_msg : msg_type_t :=
    new_msg_type("get mdio phy register reply");
  constant get_mdio_phy_access_count_msg : msg_type_t := new_msg_type("get mdio phy access count");
  constant get_mdio_phy_access_count_reply_msg : msg_type_t :=
    new_msg_type("get mdio phy access count reply");
  constant get_mdio_phy_check_count_msg : msg_type_t := new_msg_type("get mdio phy check count");
  constant get_mdio_phy_check_count_reply_msg : msg_type_t :=
    new_msg_type("get mdio phy check count reply");
  constant reset_mdio_phy_msg : msg_type_t := new_msg_type("reset mdio phy");
  constant reset_mdio_phy_reply_msg : msg_type_t := new_msg_type("reset mdio phy reply");

  -- Private. The constructor arguments of the backend, its model and the
  -- arguments of the model.
  impure function backend_arguments (phy : mdio_phy_t) return arg_t;
  impure function model (phy : mdio_phy_t) return string;
  impure function model_arguments (phy : mdio_phy_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`mdio_pkg.mdio_unexpected_msg_type`
  procedure unexpected_msg_type(msg_type : msg_type_t; phy : mdio_phy_t);

end package;

package body mdio_phy_pkg is

  impure function new_mdio_phy (
    phy_address : natural;
    clock_to_output_delay : delay_length := 0 ns;
    preamble_bits : natural := 32;
    model : string := "registers";
    model_args : arg_t := null_arg;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mdio_phy_t is
    variable result : mdio_phy_t := (
      p_phy_address => phy_address,
      p_clock_to_output_delay => clock_to_output_delay,
      p_preamble_bits => preamble_bits,
      p_model => new_string_ptr(model),
      p_model_args_name => new_string_ptr(model_args.name),
      p_model_args_value => new_string_ptr(model_args.value),
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if phy_address > 31 then
      check_failed(
        mdio_pkg_checker,
        "PHY address " & integer'image(phy_address) & " is not 0 to 31."
      );
    end if;
    if clock_to_output_delay > mdio_max_clock_to_output_delay then
      check_failed(
        mdio_pkg_checker,
        "A clock-to-output delay of "
        & time'image(clock_to_output_delay)
        & " exceeds "
        & time'image(mdio_max_clock_to_output_delay)
        & "."
      );
    end if;
    if id = null_id then
      result.p_id := enumerate(get_id("mdio_phy", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_mdio_actor(result.p_id);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    return result;
  end function;

  impure function get_id (phy : mdio_phy_t) return id_t is
  begin

    return phy.p_id;
  end function;

  impure function get_logger (phy : mdio_phy_t) return logger_t is
  begin

    return phy.p_logger;
  end function;

  impure function get_actor (phy : mdio_phy_t) return actor_t is
  begin

    return phy.p_actor;
  end function;

  impure function get_checker (phy : mdio_phy_t) return checker_t is
  begin

    return phy.p_checker;
  end function;

  impure function as_sync (phy : mdio_phy_t) return sync_handle_t is
  begin

    return phy.p_actor;
  end function;

  function phy_address (phy : mdio_phy_t) return natural is
  begin

    return phy.p_phy_address;
  end function;

  function clock_to_output_delay (phy : mdio_phy_t) return delay_length is
  begin

    return phy.p_clock_to_output_delay;
  end function;

  function preamble_bits (phy : mdio_phy_t) return natural is
  begin

    return phy.p_preamble_bits;
  end function;

  impure function backend_arguments (phy : mdio_phy_t) return arg_t is
  begin

    return arg_text(full_name(phy.p_id)) & arg(phy.p_phy_address) & arg(phy.p_preamble_bits);
  end function;

  impure function model (phy : mdio_phy_t) return string is
  begin

    return to_string(phy.p_model);
  end function;

  impure function model_arguments (phy : mdio_phy_t) return arg_t is
  begin

    return (name => to_string(phy.p_model_args_name), value => to_string(phy.p_model_args_value));
  end function;

  procedure unexpected_msg_type(msg_type : msg_type_t; phy : mdio_phy_t)is
  begin

    mdio_unexpected_msg_type(msg_type, phy.p_unexpected_msg_type_policy, phy.p_checker);
  end procedure;

  procedure set_mdio_phy_clock_to_output_delay(
    signal net : inout network_t;
    phy : mdio_phy_t;
    delay : delay_length
  )is
    variable msg : msg_t := new_msg(set_mdio_phy_clock_to_output_delay_msg);
  begin

    push(msg, delay);
    send(net, phy.p_actor, msg);
  end procedure;

  procedure set_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    value : std_ulogic_vector(15 downto 0)
  )is
    variable msg : msg_t := new_msg(set_mdio_phy_register_msg);
  begin

    push(msg, register_address);
    push_std_ulogic_vector(msg, value);
    send(net, phy.p_actor, msg);
  end procedure;

  procedure check_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    expected : std_ulogic_vector(15 downto 0);
    msg : string := ""
  )is
    variable request_msg : msg_t := new_msg(check_mdio_phy_register_msg);
  begin

    push(request_msg, register_address);
    push_std_ulogic_vector(request_msg, expected);
    push_string(request_msg, msg);
    send(net, phy.p_actor, request_msg);
  end procedure;

  procedure get_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    variable reference : inout mdio_phy_reference_t
  )is
  begin

    reference := new_msg(get_mdio_phy_register_msg);
    push(reference, register_address);
    send(net, phy.p_actor, reference);
  end procedure;

  procedure await_get_mdio_phy_register_reply(
    signal net : inout network_t;
    variable reference : inout mdio_phy_reference_t;
    variable value : out std_ulogic_vector(15 downto 0)
  )is
    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    value := pop_std_ulogic_vector(reply_msg);
    delete(reference);
    delete(reply_msg);
  end procedure;

  procedure get_mdio_phy_register(
    signal net : inout network_t;
    phy : mdio_phy_t;
    register_address : natural;
    variable value : out std_ulogic_vector(15 downto 0)
  )is
    variable reference : mdio_phy_reference_t;
  begin

    get_mdio_phy_register(net, phy, register_address, reference);
    await_get_mdio_phy_register_reply(net, reference, value);
  end procedure;

  procedure request_access_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    operation_code : natural;
    register_address : integer;
    variable count : out natural
  )is
    variable request_msg : msg_t := new_msg(get_mdio_phy_access_count_msg);
    variable reply_msg : msg_t;
  begin

    push(request_msg, operation_code);
    push(request_msg, register_address);
    request(net, phy.p_actor, request_msg, reply_msg);
    count := pop(reply_msg);
    delete(reply_msg);
  end procedure;

  procedure get_mdio_phy_access_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    variable count : out natural;
    register_address : integer := -1
  )is
  begin

    request_access_count(net, phy, 0, register_address, count);
  end procedure;

  procedure get_mdio_phy_access_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    operation : mdio_operation_t;
    variable count : out natural;
    register_address : integer := -1
  )is
  begin

    if operation = mdio_read_op then
      request_access_count(net, phy, 2, register_address, count);
    else
      request_access_count(net, phy, 1, register_address, count);
    end if;
  end procedure;

  procedure get_mdio_phy_check_count(
    signal net : inout network_t;
    phy : mdio_phy_t;
    check : mdio_check_t;
    variable count : out natural
  )is
    variable request_msg : msg_t := new_msg(get_mdio_phy_check_count_msg);
    variable reply_msg : msg_t;
  begin

    push_string(request_msg, mdio_check_t'image(check));
    request(net, phy.p_actor, request_msg, reply_msg);
    count := pop(reply_msg);
    delete(reply_msg);
  end procedure;

  procedure reset(signal net : inout network_t; phy : mdio_phy_t)is
    variable request_msg : msg_t := new_msg(reset_mdio_phy_msg);
    variable reply_msg : msg_t;
  begin

    request(net, phy.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end procedure;

end package body;
