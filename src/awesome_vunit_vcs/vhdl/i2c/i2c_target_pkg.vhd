-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the I2C target verification component
-- (i2c_target.vhd).
--
-- The target answers transfers to its address with a Python device model: a
-- register map (``"registers"``), a 24Cxx EEPROM (``"eeprom"``) or a class of
-- your own (``"package.module:Class"``). The component shifts bits in and
-- out; the model decides, once per byte, whether to acknowledge and what to
-- send. Clock stretching and NACK injection are set from VHDL or Python.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.string_ptr_pkg.all;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.vc_python_pkg.arg_text;
  use work.vc_python_pkg.kwarg_time;

package i2c_target_pkg is

  -- The handle of a target, created with :vhdl:`i2c_target_pkg.new_i2c_target`
  type i2c_target_t is record
    -- Private. Use the constructor and the accessors below.
    p_address                    : natural;
    p_ten_bit                    : boolean;
    p_general_call               : boolean;
    p_pec                        : boolean;
    p_pec_read_bytes             : natural;
    p_stretch                    : delay_length;
    p_t_hd_dat                   : delay_length;
    p_model                      : string_ptr_t;
    p_model_args_name            : string_ptr_t;
    p_model_args_value           : string_ptr_t;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- An I2C target at ``address``, a 10-bit address with ``ten_bit``.
  --
  -- * ``model`` names the device model: ``"registers"``
  --   (``RegisterDevice``), ``"eeprom"`` (``Eeprom24``), ``"device"`` (acknowledges
  --   everything, reads 0xFF) or ``"package.module:Class"``, a subclass of
  --   ``I2cDevice``. ``model_args`` are its arguments, built with the bridge's
  --   ``kwarg``, for example ``kwarg("size_bytes", 512) & kwarg("page_bytes", 16)``.
  -- * ``general_call``: answer the general call address as a write.
  -- * ``pec``: SMBus PEC. A write before a STOP ends with a PEC, checked before
  --   the model sees the write; a read sends ``pec_read_bytes`` data bytes and
  --   then the PEC.
  -- * ``stretch``: hold SCL low for this long before the acknowledge bit of
  --   every byte the target acknowledges, 0 ns for no stretching.
  -- * ``t_hd_dat``: the target changes SDA this long after SCL falls.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:i2c_target:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_i2c_target (
    address : natural;
    ten_bit : boolean := false;
    model : string := "registers";
    model_args : arg_t := null_arg;
    general_call : boolean := false;
    pec : boolean := false;
    pec_read_bytes : natural := 1;
    stretch : delay_length := 0 ns;
    t_hd_dat : delay_length := 100 ns;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_target_t;

  -- The id, logger, actor and checker of the target, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id (target : i2c_target_t) return id_t;
  impure function get_logger (target : i2c_target_t) return logger_t;
  impure function get_actor (target : i2c_target_t) return actor_t;
  impure function get_checker (target : i2c_target_t) return checker_t;
  impure function as_sync (target : i2c_target_t) return sync_handle_t;

  -- The address and the SDA delay after SCL falls given to the constructor
  function address (target : i2c_target_t) return natural;
  function t_hd_dat (target : i2c_target_t) return delay_length;

  -- Stretch SCL for this long before the acknowledge bit of every byte the
  -- target acknowledges from now on, 0 ns to stop stretching
  procedure set_i2c_target_stretch (signal net : inout network_t; target : i2c_target_t; stretch : delay_length);

  -- Do not acknowledge byte ``byte_index`` of the next transfer to the
  -- target, whatever the model says. Byte 0 is the address; a 10-bit
  -- address is bytes 0 and 1.
  procedure inject_i2c_target_nack (signal net : inout network_t; target : i2c_target_t; byte_index : natural);

  -- Write the memory of the model at ``address`` directly, leftmost byte
  -- first. A model without memory reports a failure.
  procedure i2c_target_preload (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    data : std_ulogic_vector
  );

  -- Compare the memory of the model at ``address`` with ``expected``. A
  -- difference is a check failure on the checker of the target, prefixed with
  -- msg.
  procedure i2c_target_check_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    expected : std_ulogic_vector;
    msg : string := ""
  );

  -- A pending request, redeemed with the matching await procedure
  alias i2c_target_reference_t is msg_t;

  -- Non-blocking: read ``num_bytes`` bytes of the memory of the model
  procedure i2c_target_read_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    num_bytes : natural;
    variable reference : inout i2c_target_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`i2c_target_pkg.i2c_target_read_memory`
  -- into the leftmost bits of data
  procedure await_i2c_target_read_memory_reply (
    signal net : inout network_t;
    variable reference : inout i2c_target_reference_t;
    variable data : out std_ulogic_vector
  );

  -- Blocking: read ``data'length / 8`` bytes of the memory of the model
  procedure i2c_target_read_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    variable data : out std_ulogic_vector
  );

  -- Blocking: recover a target. It releases SCL and SDA and forgets a
  -- transfer in progress; the model keeps its memory.
  procedure reset (signal net : inout network_t; target : i2c_target_t);

  -- The message types the procedures above send to the component
  constant set_i2c_target_stretch_msg : msg_type_t := new_msg_type("set i2c target stretch");
  constant inject_i2c_target_nack_msg : msg_type_t := new_msg_type("inject i2c target nack");
  constant preload_i2c_target_memory_msg : msg_type_t := new_msg_type("preload i2c target memory");
  constant check_i2c_target_memory_msg : msg_type_t := new_msg_type("check i2c target memory");
  constant read_i2c_target_memory_msg : msg_type_t := new_msg_type("read i2c target memory");
  constant read_i2c_target_memory_reply_msg : msg_type_t := new_msg_type("read i2c target memory reply");
  constant reset_i2c_target_msg : msg_type_t := new_msg_type("reset i2c target");
  constant reset_i2c_target_reply_msg : msg_type_t := new_msg_type("reset i2c target reply");

  -- Private. The constructor arguments of the backend, its model and the
  -- arguments of the model.
  impure function backend_arguments (target : i2c_target_t) return arg_t;
  impure function model (target : i2c_target_t) return string;
  impure function model_arguments (target : i2c_target_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`i2c_pkg.i2c_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; target : i2c_target_t);
end package;

package body i2c_target_pkg is

  impure function new_i2c_target (
    address : natural;
    ten_bit : boolean := false;
    model : string := "registers";
    model_args : arg_t := null_arg;
    general_call : boolean := false;
    pec : boolean := false;
    pec_read_bytes : natural := 1;
    stretch : delay_length := 0 ns;
    t_hd_dat : delay_length := 100 ns;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_target_t is

    variable result : i2c_target_t := (
      p_address => address,
      p_ten_bit => ten_bit,
      p_general_call => general_call,
      p_pec => pec,
      p_pec_read_bytes => pec_read_bytes,
      p_stretch => stretch,
      p_t_hd_dat => t_hd_dat,
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

    if id = null_id then
      result.p_id := enumerate(get_id("i2c_target", parent => get_id("awesome_vunit_vcs")));
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
    return result;
  end;

  impure function get_id (target : i2c_target_t) return id_t is
  begin

    return target.p_id;
  end;

  impure function get_logger (target : i2c_target_t) return logger_t is
  begin

    return target.p_logger;
  end;

  impure function get_actor (target : i2c_target_t) return actor_t is
  begin

    return target.p_actor;
  end;

  impure function get_checker (target : i2c_target_t) return checker_t is
  begin

    return target.p_checker;
  end;

  impure function as_sync (target : i2c_target_t) return sync_handle_t is
  begin

    return target.p_actor;
  end;

  function address (target : i2c_target_t) return natural is
  begin

    return target.p_address;
  end;

  function t_hd_dat (target : i2c_target_t) return delay_length is
  begin

    return target.p_t_hd_dat;
  end;

  impure function backend_arguments (target : i2c_target_t) return arg_t is
  begin

    return arg_text(full_name(target.p_id))
           & arg(target.p_address)
           & kwarg("ten_bit", target.p_ten_bit)
           & kwarg("general_call", target.p_general_call)
           & kwarg("pec", target.p_pec)
           & kwarg("pec_read_bytes", target.p_pec_read_bytes)
           & kwarg_time("stretch", target.p_stretch);
  end;

  impure function model (target : i2c_target_t) return string is
  begin

    return to_string(target.p_model);
  end;

  impure function model_arguments (target : i2c_target_t) return arg_t is
  begin

    return (name => to_string(target.p_model_args_name), value => to_string(target.p_model_args_value));
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; target : i2c_target_t) is
  begin

    i2c_unexpected_msg_type(msg_type, target.p_unexpected_msg_type_policy, target.p_checker);
  end;

  procedure set_i2c_target_stretch (signal net : inout network_t; target : i2c_target_t; stretch : delay_length) is

    variable msg : msg_t := new_msg(set_i2c_target_stretch_msg);
  begin

    push(msg, stretch);
    send(net, target.p_actor, msg);
  end;

  procedure inject_i2c_target_nack (signal net : inout network_t; target : i2c_target_t; byte_index : natural) is

    variable msg : msg_t := new_msg(inject_i2c_target_nack_msg);
  begin

    push(msg, byte_index);
    send(net, target.p_actor, msg);
  end;

  procedure push_bytes (msg : msg_t; data : std_ulogic_vector) is

    constant values : integer_vector := i2c_bytes(data);
  begin

    push(msg, values'length);
    for idx in values'range loop

      push(msg, values(idx));
    end loop;

  end;

  procedure i2c_target_preload (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    data : std_ulogic_vector
  ) is

    variable msg : msg_t := new_msg(preload_i2c_target_memory_msg);
  begin

    push(msg, address);
    push_bytes(msg, data);
    send(net, target.p_actor, msg);
  end;

  procedure i2c_target_check_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    expected : std_ulogic_vector;
    msg : string := ""
  ) is

    variable request_msg : msg_t := new_msg(check_i2c_target_memory_msg);
  begin

    push(request_msg, address);
    push_bytes(request_msg, expected);
    push_string(request_msg, msg);
    send(net, target.p_actor, request_msg);
  end;

  procedure i2c_target_read_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    num_bytes : natural;
    variable reference : inout i2c_target_reference_t
  ) is
  begin

    reference := new_msg(read_i2c_target_memory_msg);
    push(reference, address);
    push(reference, num_bytes);
    send(net, target.p_actor, reference);
  end;

  procedure await_i2c_target_read_memory_reply (
    signal net : inout network_t;
    variable reference : inout i2c_target_reference_t;
    variable data : out std_ulogic_vector
  ) is

    alias normalized : std_ulogic_vector(0 to data'length - 1) is data;
    variable reply_msg : msg_t;
    variable num_bytes : natural;
    variable value : natural;
  begin

    receive_reply(net, reference, reply_msg);
    normalized := (others => '0');
    num_bytes := pop(reply_msg);
    for idx in 0 to num_bytes - 1 loop

      value := pop(reply_msg);
      if 8 * idx + 7 < data'length then
        for bit_idx in 0 to 7 loop

          if (value / 2 ** (7 - bit_idx)) mod 2 = 1 then
            normalized(8 * idx + bit_idx) := '1';
          end if;
        end loop;

      end if;
    end loop;

    delete(reference);
    delete(reply_msg);
  end;

  procedure i2c_target_read_memory (
    signal net : inout network_t;
    target : i2c_target_t;
    address : natural;
    variable data : out std_ulogic_vector
  ) is

    variable reference : i2c_target_reference_t;
  begin

    i2c_target_read_memory(net, target, address, data'length / 8, reference);
    await_i2c_target_read_memory_reply(net, reference, data);
  end;

  procedure reset (signal net : inout network_t; target : i2c_target_t) is

    variable request_msg : msg_t := new_msg(reset_i2c_target_msg);
    variable reply_msg : msg_t;
  begin

    request(net, target.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
