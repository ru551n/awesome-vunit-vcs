-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Everything a testbench needs to use the MDIO verification components,
-- VUnit itself included, so it is the only context clause of an MDIO
-- testbench:
--
--   library awesome_vunit_vcs;
--   context awesome_vunit_vcs.mdio_context;

context mdio_context is

  library ieee;
  use ieee.std_logic_1164.all;

  library vunit_lib;
  context vunit_lib.vunit_context;
  context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

  library python_bridge;
  context python_bridge.python_context;

  library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;
  use awesome_vunit_vcs.mdio_pkg.all;
  use awesome_vunit_vcs.mdio_phy_pkg.all;
  use awesome_vunit_vcs.mdio_master_pkg.all;

end context mdio_context;
