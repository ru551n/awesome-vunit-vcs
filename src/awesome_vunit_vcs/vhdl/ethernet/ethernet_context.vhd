-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Everything a testbench needs to use the Ethernet verification components,
-- VUnit itself included:
--
--   library awesome_vunit_vcs;
--   context awesome_vunit_vcs.ethernet_context;

context ethernet_context is
  library ieee;
  use ieee.std_logic_1164.all;

  library vunit_lib;
  context vunit_lib.vunit_context;
  context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.stream_master_pkg.all;
  use vunit_lib.stream_slave_pkg.all;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.vc_pkg.all;

  library python_bridge;
  context python_bridge.python_context;

  library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;
  use awesome_vunit_vcs.ethernet_pkg.all;
  use awesome_vunit_vcs.axis_mac_pkg.all;
  use awesome_vunit_vcs.gmii_pkg.all;
  use awesome_vunit_vcs.mii_pkg.all;
  use awesome_vunit_vcs.rgmii_pkg.all;
  use awesome_vunit_vcs.rmii_pkg.all;
  use awesome_vunit_vcs.xgmii_pkg.all;
  use awesome_vunit_vcs.property_pkg.all;
end context;
