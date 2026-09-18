-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the I2C master verification component
-- (i2c_master.vhd).
--
-- The master is a controller on an open-drain bus. Its Python backend turns a
-- transfer into a list of operations (START, a byte out, a byte in, STOP) and
-- the component clocks them out with the timing of its speed mode. It honours
-- clock stretching, synchronizes its clock with other masters and detects a
-- lost arbitration. The results, acknowledge bits and bytes read, go back to
-- Python and to the caller.
--
-- Data is given as a std_ulogic_vector of whole bytes, leftmost byte first,
-- such as ``x"0012"``.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.vc_python_pkg.arg_text;
  use work.vc_python_pkg.kwarg_time;

package i2c_master_pkg is

  -- The handle of a master, created with :vhdl:`i2c_master_pkg.new_i2c_master`
  type i2c_master_t is record
    -- Private. Use the constructor and the accessors below.
    p_speed                      : i2c_speed_t;
    p_t_low                      : delay_length;
    p_t_high                     : delay_length;
    p_t_hd_dat                   : delay_length;
    p_t_su_sta                   : delay_length;
    p_t_hd_sta                   : delay_length;
    p_t_su_sto                   : delay_length;
    p_t_buf                      : delay_length;
    p_stretch_timeout            : delay_length;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- An I2C master. The times it drives are those of ``speed`` at the full
  -- SCL frequency, unless given:
  --
  -- * ``t_low``, ``t_high``: SCL low and high period
  -- * ``t_hd_dat``: from SCL falling to driving SDA
  -- * ``t_su_sta``, ``t_hd_sta``: setup of a repeated START, hold of a START
  -- * ``t_su_sto``: setup of a STOP
  -- * ``t_buf``: bus free time before a START after a STOP
  --
  -- 0 ns keeps the time of the speed mode. ``stretch_timeout`` is how long
  -- the master waits for SCL to rise after it released it; longer is a check
  -- failure on the checker of the master and ends the transfer.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:i2c_master:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_i2c_master (
    speed : i2c_speed_t := i2c_standard_mode;
    t_low : delay_length := 0 ns;
    t_high : delay_length := 0 ns;
    t_hd_dat : delay_length := 0 ns;
    t_su_sta : delay_length := 0 ns;
    t_hd_sta : delay_length := 0 ns;
    t_su_sto : delay_length := 0 ns;
    t_buf : delay_length := 0 ns;
    stretch_timeout : delay_length := 25 ms;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_master_t;

  -- The id, logger, actor and checker of the master, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id (master : i2c_master_t) return id_t;
  impure function get_logger (master : i2c_master_t) return logger_t;
  impure function get_actor (master : i2c_master_t) return actor_t;
  impure function get_checker (master : i2c_master_t) return checker_t;
  impure function as_sync (master : i2c_master_t) return sync_handle_t;

  -- The speed mode and the clock stretching timeout given to the constructor
  function speed (master : i2c_master_t) return i2c_speed_t;
  function stretch_timeout (master : i2c_master_t) return delay_length;

  -- A pending transfer, redeemed with the matching await procedure
  alias i2c_master_reference_t is msg_t;

  -- Non-blocking: write data to the target at ``address``. With ``ten_bit``
  -- the address is a 10-bit address, with ``pec`` an SMBus PEC follows the
  -- data, and without ``stop`` the master releases the bus without a STOP.
  -- Without data the transfer is the address alone, as for acknowledge
  -- polling. A byte that is not acknowledged ends the transfer with a STOP
  -- and is a check failure on the checker of the master, as is a lost
  -- arbitration.
  procedure i2c_write (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    data : std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false;
    stop : boolean := true
  );

  -- Blocking: like :vhdl:`i2c_master_pkg.i2c_write`, with its status instead
  -- of a check failure
  procedure i2c_write (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    data : std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false;
    stop : boolean := true
  );

  -- Blocking: read ``data'length / 8`` bytes from the target at ``address``.
  -- The master acknowledges every byte but the last. With ``pec`` it reads
  -- one more byte and checks it as the SMBus PEC. A byte that is not
  -- acknowledged, a lost arbitration or a wrong PEC is a check failure on the
  -- checker of the master.
  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    variable data : out std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- Blocking: like :vhdl:`i2c_master_pkg.i2c_read`, with its status instead
  -- of a check failure
  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    variable data : out std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- Non-blocking: read ``num_bytes`` bytes, redeemed with
  -- :vhdl:`i2c_master_pkg.await_i2c_read_reply`
  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    num_bytes : natural;
    variable reference : inout i2c_master_reference_t;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- Blocking: redeem a reference of :vhdl:`i2c_master_pkg.i2c_read` or
  -- :vhdl:`i2c_master_pkg.i2c_write_read`. The bytes read go to the leftmost
  -- bits of data, the rest is 0.
  procedure await_i2c_read_reply (
    signal net : inout network_t;
    variable reference : inout i2c_master_reference_t;
    variable data : out std_ulogic_vector;
    variable status : out i2c_status_t
  );

  -- Blocking: write ``write_data``, then read ``read_data'length / 8`` bytes
  -- after a repeated START, as a register read does. With ``pec`` the last
  -- byte read is the PEC of the whole transfer. Failures as for
  -- :vhdl:`i2c_master_pkg.i2c_read`.
  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    variable read_data : out std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- Blocking: like :vhdl:`i2c_master_pkg.i2c_write_read`, with its status
  -- instead of a check failure
  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    variable read_data : out std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- Non-blocking: write, then read ``num_bytes`` bytes, redeemed with
  -- :vhdl:`i2c_master_pkg.await_i2c_read_reply`
  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    num_bytes : natural;
    variable reference : inout i2c_master_reference_t;
    ten_bit : boolean := false;
    pec : boolean := false
  );

  -- The outcome of :vhdl:`i2c_master_pkg.i2c_transfer`. The receiver owns
  -- the arrays and deallocates them.
  type i2c_result_t is record
    -- The status of the transfer
    status : i2c_status_t;
    -- The bytes read, one per element
    data   : integer_array_t;
    -- For every byte written, address bytes included, 1 when it was
    -- acknowledged and 0 when not
    acks   : integer_array_t;
  end record;

  -- Non-blocking: a transfer written as operations, for traffic the other
  -- procedures cannot make: ``S`` a START or repeated START, ``P`` a STOP,
  -- ``0xA0`` a byte written with its acknowledge bit, ``R`` a byte read and
  -- acknowledged, ``RN`` a byte read and not acknowledged, and ``B101`` 1 to
  -- 8 bits written without an acknowledge bit. For example ``"S 0xA0 0x10
  -- B1010"`` stops in the middle of a byte and ends without a STOP. A NACK
  -- does not end the transfer and nothing is a check failure; the result
  -- tells.
  procedure i2c_transfer (
    signal net : inout network_t;
    master : i2c_master_t;
    ops : string;
    variable reference : inout i2c_master_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`i2c_master_pkg.i2c_transfer`
  procedure await_i2c_transfer_reply (
    signal net : inout network_t;
    variable reference : inout i2c_master_reference_t;
    variable result : out i2c_result_t
  );

  -- Blocking: :vhdl:`i2c_master_pkg.i2c_transfer` and its result
  procedure i2c_transfer (
    signal net : inout network_t;
    master : i2c_master_t;
    ops : string;
    variable result : out i2c_result_t
  );

  -- Blocking: recover a master. It releases SCL and SDA and takes the bus as
  -- free, also after a transaction some master left without a STOP.
  -- Transfers requested before the reset run first; one waiting for SCL
  -- held low ends after the stretch timeout.
  procedure reset (signal net : inout network_t; master : i2c_master_t);

  -- The message types the procedures above send to the component
  constant run_i2c_transfer_msg : msg_type_t := new_msg_type("run i2c transfer");
  constant run_i2c_transfer_reply_msg : msg_type_t := new_msg_type("run i2c transfer reply");
  constant reset_i2c_master_msg : msg_type_t := new_msg_type("reset i2c master");
  constant reset_i2c_master_reply_msg : msg_type_t := new_msg_type("reset i2c master reply");

  -- Private. The constructor arguments of the backend.
  impure function backend_arguments (master : i2c_master_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`i2c_pkg.i2c_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; master : i2c_master_t);
end package;

package body i2c_master_pkg is

  impure function new_i2c_master (
    speed : i2c_speed_t := i2c_standard_mode;
    t_low : delay_length := 0 ns;
    t_high : delay_length := 0 ns;
    t_hd_dat : delay_length := 0 ns;
    t_su_sta : delay_length := 0 ns;
    t_hd_sta : delay_length := 0 ns;
    t_su_sto : delay_length := 0 ns;
    t_buf : delay_length := 0 ns;
    stretch_timeout : delay_length := 25 ms;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return i2c_master_t is

    variable result : i2c_master_t := (
      p_speed => speed,
      p_t_low => t_low,
      p_t_high => t_high,
      p_t_hd_dat => t_hd_dat,
      p_t_su_sta => t_su_sta,
      p_t_hd_sta => t_hd_sta,
      p_t_su_sto => t_su_sto,
      p_t_buf => t_buf,
      p_stretch_timeout => stretch_timeout,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if id = null_id then
      result.p_id := enumerate(get_id("i2c_master", parent => get_id("awesome_vunit_vcs")));
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

  impure function get_id (master : i2c_master_t) return id_t is
  begin

    return master.p_id;
  end;

  impure function get_logger (master : i2c_master_t) return logger_t is
  begin

    return master.p_logger;
  end;

  impure function get_actor (master : i2c_master_t) return actor_t is
  begin

    return master.p_actor;
  end;

  impure function get_checker (master : i2c_master_t) return checker_t is
  begin

    return master.p_checker;
  end;

  impure function as_sync (master : i2c_master_t) return sync_handle_t is
  begin

    return master.p_actor;
  end;

  function speed (master : i2c_master_t) return i2c_speed_t is
  begin

    return master.p_speed;
  end;

  function stretch_timeout (master : i2c_master_t) return delay_length is
  begin

    return master.p_stretch_timeout;
  end;

  impure function backend_arguments (master : i2c_master_t) return arg_t is
  begin

    return arg_text(full_name(master.p_id))
           & arg(i2c_speed_t'pos(master.p_speed))
           & kwarg_time("t_low", master.p_t_low)
           & kwarg_time("t_high", master.p_t_high)
           & kwarg_time("t_hd_dat", master.p_t_hd_dat)
           & kwarg_time("t_su_sta", master.p_t_su_sta)
           & kwarg_time("t_hd_sta", master.p_t_hd_sta)
           & kwarg_time("t_su_sto", master.p_t_su_sto)
           & kwarg_time("t_buf", master.p_t_buf);
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; master : i2c_master_t) is
  begin

    i2c_unexpected_msg_type(msg_type, master.p_unexpected_msg_type_policy, master.p_checker);
  end;

  -- A transfer request. The component replies when want_reply.
  impure function new_transfer_msg (
    address : natural;
    write_data : std_ulogic_vector;
    num_read : natural;
    ten_bit : boolean;
    pec : boolean;
    stop : boolean;
    expect_ack : boolean;
    want_reply : boolean
  ) return msg_t is

    constant values : integer_vector := i2c_bytes(write_data);
    variable msg : msg_t := new_msg(run_i2c_transfer_msg);
  begin

    push(msg, want_reply);
    push(msg, false);
    push(msg, address);
    push(msg, values'length);
    for idx in values'range loop

      push(msg, values(idx));
    end loop;

    push(msg, num_read);
    push(msg, ten_bit);
    push(msg, pec);
    push(msg, stop);
    push(msg, expect_ack);
    return msg;
  end;

  procedure i2c_write (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    data : std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false;
    stop : boolean := true
  ) is

    variable msg : msg_t := new_transfer_msg(address, data, 0, ten_bit, pec, stop, true, false);
  begin

    send(net, master.p_actor, msg);
  end;

  procedure i2c_write (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    data : std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false;
    stop : boolean := true
  ) is

    variable reference : i2c_master_reference_t := new_transfer_msg(address, data, 0, ten_bit, pec, stop, false, true);
    variable nothing : std_ulogic_vector(1 to 0);
  begin

    send(net, master.p_actor, reference);
    await_i2c_read_reply(net, reference, nothing, status);
  end;

  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    num_bytes : natural;
    variable reference : inout i2c_master_reference_t;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is
  begin

    reference := new_transfer_msg(address, "", num_bytes, ten_bit, pec, true, false, true);
    send(net, master.p_actor, reference);
  end;

  procedure await_i2c_read_reply (
    signal net : inout network_t;
    variable reference : inout i2c_master_reference_t;
    variable data : out std_ulogic_vector;
    variable status : out i2c_status_t
  ) is

    alias normalized : std_ulogic_vector(0 to data'length - 1) is data;
    variable reply_msg : msg_t;
    variable num_bytes : natural;
    variable value : natural;
  begin

    receive_reply(net, reference, reply_msg);
    status := i2c_status_t'val(integer'(pop(reply_msg)));
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

  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    variable data : out std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is

    variable reference : i2c_master_reference_t;
  begin

    i2c_read(net, master, address, data'length / 8, reference, ten_bit, pec);
    await_i2c_read_reply(net, reference, data, status);
  end;

  procedure i2c_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    variable data : out std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is

    variable reference : i2c_master_reference_t :=
      new_transfer_msg(address, "", data'length / 8, ten_bit, pec, true, true, true);
    variable status : i2c_status_t;
  begin

    send(net, master.p_actor, reference);
    await_i2c_read_reply(net, reference, data, status);
  end;

  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    num_bytes : natural;
    variable reference : inout i2c_master_reference_t;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is
  begin

    reference := new_transfer_msg(address, write_data, num_bytes, ten_bit, pec, true, false, true);
    send(net, master.p_actor, reference);
  end;

  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    variable read_data : out std_ulogic_vector;
    variable status : out i2c_status_t;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is

    variable reference : i2c_master_reference_t;
  begin

    i2c_write_read(net, master, address, write_data, read_data'length / 8, reference, ten_bit, pec);
    await_i2c_read_reply(net, reference, read_data, status);
  end;

  procedure i2c_write_read (
    signal net : inout network_t;
    master : i2c_master_t;
    address : natural;
    write_data : std_ulogic_vector;
    variable read_data : out std_ulogic_vector;
    ten_bit : boolean := false;
    pec : boolean := false
  ) is

    variable reference : i2c_master_reference_t :=
      new_transfer_msg(address, write_data, read_data'length / 8, ten_bit, pec, true, true, true);
    variable status : i2c_status_t;
  begin

    send(net, master.p_actor, reference);
    await_i2c_read_reply(net, reference, read_data, status);
  end;

  procedure i2c_transfer (
    signal net : inout network_t;
    master : i2c_master_t;
    ops : string;
    variable reference : inout i2c_master_reference_t
  ) is
  begin

    reference := new_msg(run_i2c_transfer_msg);
    push(reference, true);
    push(reference, true);
    push_string(reference, ops);
    send(net, master.p_actor, reference);
  end;

  procedure await_i2c_transfer_reply (
    signal net : inout network_t;
    variable reference : inout i2c_master_reference_t;
    variable result : out i2c_result_t
  ) is

    variable reply_msg : msg_t;
    variable count : natural;
  begin

    receive_reply(net, reference, reply_msg);
    result.status := i2c_status_t'val(integer'(pop(reply_msg)));
    count := pop(reply_msg);
    result.data := new_1d(count, bit_width => 8, is_signed => false);
    for idx in 0 to count - 1 loop

      set(result.data, idx, integer'(pop(reply_msg)));
    end loop;

    count := pop(reply_msg);
    result.acks := new_1d(count, bit_width => 1, is_signed => false);
    for idx in 0 to count - 1 loop

      set(result.acks, idx, integer'(pop(reply_msg)));
    end loop;

    delete(reference);
    delete(reply_msg);
  end;

  procedure i2c_transfer (
    signal net : inout network_t;
    master : i2c_master_t;
    ops : string;
    variable result : out i2c_result_t
  ) is

    variable reference : i2c_master_reference_t;
  begin

    i2c_transfer(net, master, ops, reference);
    await_i2c_transfer_reply(net, reference, result);
  end;

  procedure reset (signal net : inout network_t; master : i2c_master_t) is

    variable request_msg : msg_t := new_msg(reset_i2c_master_msg);
    variable reply_msg : msg_t;
  begin

    request(net, master.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
