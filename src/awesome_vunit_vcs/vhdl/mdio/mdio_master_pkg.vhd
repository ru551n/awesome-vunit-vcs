-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the MDIO master verification component
-- (mdio_master.vhd), the station management entity of Clause 22.
--
-- The master drives MDC and sends frames bit by bit: it changes MDIO when MDC
-- falls and samples it when MDC rises. Reads and writes build the frame with
-- :vhdl:`mdio_pkg.mdio_frame`; transfer_mdio sends any bits, for malformed
-- frames.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

use work.mdio_pkg.all;

package mdio_master_pkg is

  -- The handle of a master, created with :vhdl:`mdio_master_pkg.new_mdio_master`
  type mdio_master_t is record
    -- Private. Use the constructor and the accessors below.
    p_mdc_period                 : delay_length;
    p_preamble_bits              : natural;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- An MDIO master with an MDC period of ``mdc_period``, 400 ns (2.5 MHz) or
  -- more for the standard, and ``preamble_bits`` preamble ones in the frames
  -- of read_mdio and write_mdio.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:mdio_master:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_mdio_master (
    mdc_period : delay_length := 400 ns;
    preamble_bits : natural := 32;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mdio_master_t;

  -- The id, logger, actor and checker of the master, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``
  impure function get_id (master : mdio_master_t) return id_t;
  impure function get_logger (master : mdio_master_t) return logger_t;
  impure function get_actor (master : mdio_master_t) return actor_t;
  impure function get_checker (master : mdio_master_t) return checker_t;
  impure function as_sync (master : mdio_master_t) return sync_handle_t;

  -- The MDC period and preamble length given to the constructor
  function mdc_period (master : mdio_master_t) return delay_length;
  function preamble_bits (master : mdio_master_t) return natural;

  -- Use this MDC period for the frames from now on
  procedure set_mdio_master_mdc_period(
    signal net : inout network_t;
    master : mdio_master_t;
    period : delay_length
  );

  -- Non-blocking: write ``data`` to a register of a PHY
  procedure write_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    data : std_ulogic_vector(15 downto 0)
  );

  -- A pending request, redeemed with the matching await procedure
  alias mdio_master_reference_t is msg_t;

  -- Non-blocking: read a register of a PHY. A register no PHY answers reads
  -- as the pull-up, all ones.
  procedure read_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    variable reference : inout mdio_master_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`mdio_master_pkg.read_mdio`
  procedure await_read_mdio_reply(
    signal net : inout network_t;
    variable reference : inout mdio_master_reference_t;
    variable data : out std_ulogic_vector(15 downto 0)
  );

  -- Blocking: read a register of a PHY
  procedure read_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    variable data : out std_ulogic_vector(15 downto 0)
  );

  -- Non-blocking: send ``bits``, leftmost first, one per MDC period: '0' and
  -- '1' drive MDIO, 'Z' releases it and any other value is driven as it is.
  -- The reply has the value of MDIO at every rising MDC edge.
  procedure transfer_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    bits : std_ulogic_vector;
    variable reference : inout mdio_master_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`mdio_master_pkg.transfer_mdio`
  -- into ``sampled``, as long as the bits sent
  procedure await_transfer_mdio_reply(
    signal net : inout network_t;
    variable reference : inout mdio_master_reference_t;
    variable sampled : out std_ulogic_vector
  );

  -- Blocking: send ``bits`` and return the value of MDIO at every rising MDC
  -- edge in ``sampled``, as long as ``bits``
  procedure transfer_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    bits : std_ulogic_vector;
    variable sampled : out std_ulogic_vector
  );

  -- Blocking: recover a master. It returns when the frames sent before it are
  -- over, with MDIO released and MDC low.
  procedure reset(signal net : inout network_t; master : mdio_master_t);

  -- The message types the procedures above send to the component
  constant set_mdio_master_mdc_period_msg : msg_type_t :=
    new_msg_type("set mdio master mdc period");
  constant write_mdio_msg : msg_type_t := new_msg_type("write mdio");
  constant read_mdio_msg : msg_type_t := new_msg_type("read mdio");
  constant read_mdio_reply_msg : msg_type_t := new_msg_type("read mdio reply");
  constant transfer_mdio_msg : msg_type_t := new_msg_type("transfer mdio");
  constant transfer_mdio_reply_msg : msg_type_t := new_msg_type("transfer mdio reply");
  constant reset_mdio_master_msg : msg_type_t := new_msg_type("reset mdio master");
  constant reset_mdio_master_reply_msg : msg_type_t := new_msg_type("reset mdio master reply");

  -- Private. A message type no handler took, see
  -- :vhdl:`mdio_pkg.mdio_unexpected_msg_type`
  procedure unexpected_msg_type(msg_type : msg_type_t; master : mdio_master_t);

end package;

package body mdio_master_pkg is

  impure function new_mdio_master (
    mdc_period : delay_length := 400 ns;
    preamble_bits : natural := 32;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mdio_master_t is
    variable result : mdio_master_t := (
      p_mdc_period => mdc_period,
      p_preamble_bits => preamble_bits,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if mdc_period < 2 fs then
      check_failed(
        mdio_pkg_checker,
        "An MDC period of " & time'image(mdc_period) & " is too short."
      );
    end if;
    if id = null_id then
      result.p_id := enumerate(get_id("mdio_master", parent => get_id("awesome_vunit_vcs")));
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

  impure function get_id (master : mdio_master_t) return id_t is
  begin

    return master.p_id;
  end function;

  impure function get_logger (master : mdio_master_t) return logger_t is
  begin

    return master.p_logger;
  end function;

  impure function get_actor (master : mdio_master_t) return actor_t is
  begin

    return master.p_actor;
  end function;

  impure function get_checker (master : mdio_master_t) return checker_t is
  begin

    return master.p_checker;
  end function;

  impure function as_sync (master : mdio_master_t) return sync_handle_t is
  begin

    return master.p_actor;
  end function;

  function mdc_period (master : mdio_master_t) return delay_length is
  begin

    return master.p_mdc_period;
  end function;

  function preamble_bits (master : mdio_master_t) return natural is
  begin

    return master.p_preamble_bits;
  end function;

  procedure unexpected_msg_type(msg_type : msg_type_t; master : mdio_master_t)is
  begin

    mdio_unexpected_msg_type(msg_type, master.p_unexpected_msg_type_policy, master.p_checker);
  end procedure;

  procedure set_mdio_master_mdc_period(
    signal net : inout network_t;
    master : mdio_master_t;
    period : delay_length
  )is
    variable msg : msg_t := new_msg(set_mdio_master_mdc_period_msg);
  begin

    push(msg, period);
    send(net, master.p_actor, msg);
  end procedure;

  procedure write_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    data : std_ulogic_vector(15 downto 0)
  )is
    variable msg : msg_t := new_msg(write_mdio_msg);
  begin

    push_std_ulogic_vector(
      msg,
      mdio_frame(mdio_write_op, phy_address, register_address, data, master.p_preamble_bits)
    );
    send(net, master.p_actor, msg);
  end procedure;

  procedure read_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    variable reference : inout mdio_master_reference_t
  )is
  begin

    reference := new_msg(read_mdio_msg);
    push_std_ulogic_vector(
      reference,
      mdio_frame(
        mdio_read_op,
        phy_address,
        register_address,
        preamble_bits => master.p_preamble_bits
      )
    );
    send(net, master.p_actor, reference);
  end procedure;

  procedure await_read_mdio_reply(
    signal net : inout network_t;
    variable reference : inout mdio_master_reference_t;
    variable data : out std_ulogic_vector(15 downto 0)
  )is
    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    data := pop_std_ulogic_vector(reply_msg);
    delete(reference);
    delete(reply_msg);
  end procedure;

  procedure read_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    phy_address : natural;
    register_address : natural;
    variable data : out std_ulogic_vector(15 downto 0)
  )is
    variable reference : mdio_master_reference_t;
  begin

    read_mdio(net, master, phy_address, register_address, reference);
    await_read_mdio_reply(net, reference, data);
  end procedure;

  procedure transfer_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    bits : std_ulogic_vector;
    variable reference : inout mdio_master_reference_t
  )is
  begin

    reference := new_msg(transfer_mdio_msg);
    push_std_ulogic_vector(reference, bits);
    send(net, master.p_actor, reference);
  end procedure;

  procedure await_transfer_mdio_reply(
    signal net : inout network_t;
    variable reference : inout mdio_master_reference_t;
    variable sampled : out std_ulogic_vector
  )is
    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    sampled := pop_std_ulogic_vector(reply_msg);
    delete(reference);
    delete(reply_msg);
  end procedure;

  procedure transfer_mdio(
    signal net : inout network_t;
    master : mdio_master_t;
    bits : std_ulogic_vector;
    variable sampled : out std_ulogic_vector
  )is
    variable reference : mdio_master_reference_t;
  begin

    transfer_mdio(net, master, bits, reference);
    await_transfer_mdio_reply(net, reference, sampled);
  end procedure;

  procedure reset(signal net : inout network_t; master : mdio_master_t)is
    variable request_msg : msg_t := new_msg(reset_mdio_master_msg);
    variable reply_msg : msg_t;
  begin

    request(net, master.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end procedure;

end package body;
