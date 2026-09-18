-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Everything a testbench needs to use the flash verification components,
-- VUnit itself included, so it is the only context clause of a flash
-- testbench:
--
--   library awesome_vunit_vcs;
--   context awesome_vunit_vcs.flash_context;

context flash_context is

  library ieee;
  use ieee.std_logic_1164.all;

  library vunit_lib;
  context vunit_lib.vunit_context;
  context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.vc_pkg.all;

  library python_bridge;
  context python_bridge.python_context;

  library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;
  use awesome_vunit_vcs.property_pkg.all;
  use awesome_vunit_vcs.qspi_pkg.all;
  use awesome_vunit_vcs.qspi_master_pkg.all;
  use awesome_vunit_vcs.qspi_protocol_checker_pkg.all;
  use awesome_vunit_vcs.qspi_flash_cmd_pkg.all;
  use awesome_vunit_vcs.flash_pkg.all;

end context flash_context;
