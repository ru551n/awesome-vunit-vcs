-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Types shared by the MDIO verification components: the checks, the
-- operations and the bits of a Clause 22 frame.
--
-- MDIO is a tri-state line with a pull-up. The VCs drive it '0', '1' or 'Z' on
-- a resolved std_logic signal that the testbench pulls up with 'H', and read it
-- with to_x01, so 'H' is a 1. MDC is driven by the master.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.vc_pkg.all;

package mdio_pkg is

  -- The checks of the MDIO PHY, named like their check IDs (upper case in log
  -- messages, such as ``MDIO_TA``)
  type mdio_check_t is (
    -- Fewer preamble ones before ST than the PHY needs
    mdio_preamble,
    -- An OP of 00 or 11 in a Clause 22 frame to the PHY
    mdio_op,
    -- A write whose TA is not 10, or a read whose first TA bit the master drove
    mdio_ta,
    -- MDIO differed from the value the PHY drove, in the second TA bit or the data of a read
    mdio_contention,
    -- A metavalue on MDIO in a frame header, or in a frame to the PHY
    mdio_metavalue,
    -- A register differs from the value expected with check_mdio_phy_register
    mdio_register
  );

  -- The operations of a Clause 22 frame
  type mdio_operation_t is (mdio_read_op, mdio_write_op);

  -- The largest clock-to-output delay of a PHY the standard allows, from a
  -- rising MDC edge to valid read data on MDIO
  constant mdio_max_clock_to_output_delay : delay_length := 300 ns;

  -- The bits a master sends for a Clause 22 frame, leftmost first:
  -- ``preamble_bits`` ones, ST 01, OP, PHYAD, REGAD, TA and the data. A write
  -- drives ``ta`` and ``data``; a read leaves TA and the data to the PHY, 'Z'.
  -- Change bits of the result to make a malformed frame for
  -- :vhdl:`mdio_master_pkg.transfer_mdio`.
  function mdio_frame (
    operation : mdio_operation_t;
    phy_address : natural;
    register_address : natural;
    data : std_ulogic_vector(15 downto 0) := x"0000";
    preamble_bits : natural := 32;
    ta : std_ulogic_vector(1 downto 0) := "10"
  ) return std_ulogic_vector;

  -- Private. The logger and checker of errors in the constructors, such as an
  -- id that already has an actor
  constant mdio_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:mdio_pkg");
  constant mdio_pkg_checker : checker_t := new_checker(mdio_pkg_logger);

  -- Private. A new actor for id, or an anonymous one after a check failure
  -- when id already has an actor
  impure function new_mdio_actor (id : id_t) return actor_t;

  -- Private. A message type no handler took: a check failure ``Got unexpected
  -- message <name>`` on checker unless policy is ignore or the message was
  -- already handled, like vc_pkg.unexpected_msg_type of VUnit
  procedure mdio_unexpected_msg_type(
    msg_type : msg_type_t;
    policy : unexpected_msg_type_policy_t;
    checker : checker_t
  );

end package;

package body mdio_pkg is

  function mdio_frame (
    operation : mdio_operation_t;
    phy_address : natural;
    register_address : natural;
    data : std_ulogic_vector(15 downto 0) := x"0000";
    preamble_bits : natural := 32;
    ta : std_ulogic_vector(1 downto 0) := "10"
  ) return std_ulogic_vector is
    constant preamble : std_ulogic_vector(0 to preamble_bits - 1) := (others => '1');
    constant header : std_ulogic_vector(0 to 9)
      := std_ulogic_vector(to_unsigned(phy_address, 5))
         & std_ulogic_vector(to_unsigned(register_address, 5));
    constant released : std_ulogic_vector(0 to 17) := (others => 'Z');
  begin

    if operation = mdio_write_op then
      return preamble & "01" & "01" & header & ta & data;
    end if;
    return preamble & "01" & "10" & header & released;
  end function;

  impure function new_mdio_actor (id : id_t) return actor_t is
  begin

    if find(id, enable_deferred_creation => false) /= null_actor then
      check_failed(mdio_pkg_checker, "An actor already exists for " & full_name(id) & ".");
      return new_actor;
    end if;
    return new_actor(id);
  end function;

  procedure mdio_unexpected_msg_type(
    msg_type : msg_type_t;
    policy : unexpected_msg_type_policy_t;
    checker : checker_t
  )is
  begin

    if is_already_handled(msg_type) or policy = ignore then
      null;
    else
      check_failed(checker, "Got unexpected message " & name(msg_type));
    end if;
  end procedure;

end package body;
