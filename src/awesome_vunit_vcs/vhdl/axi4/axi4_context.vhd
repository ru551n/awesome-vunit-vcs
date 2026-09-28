-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Everything a testbench needs to use the AXI4 verification components,
-- VUnit itself and its AXI package included, so it is the only context
-- clause of an AXI4 testbench:
--
--   library awesome_vunit_vcs;
--   context awesome_vunit_vcs.axi4_context;

context axi4_context is

  library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

  library vunit_lib;
  context vunit_lib.vunit_context;
  context vunit_lib.com_context;
  context vunit_lib.vc_context;

  library python_bridge;
  context python_bridge.python_context;

  library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;
  use awesome_vunit_vcs.axi4_pkg.all;
  use awesome_vunit_vcs.axi4_protocol_checker_pkg.all;
  use awesome_vunit_vcs.axi4_monitor_pkg.all;
  use awesome_vunit_vcs.axi4_memory_pkg.all;
  use awesome_vunit_vcs.axi4_slave_pkg.all;

end context axi4_context;
