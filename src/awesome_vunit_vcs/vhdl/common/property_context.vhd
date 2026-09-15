-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Everything a testbench needs to run properties, VUnit itself and the typed
-- Python arguments included, so it is the only context clause of a property
-- testbench:
--
--   library awesome_vunit_vcs;
--   context awesome_vunit_vcs.property_context;
--
-- The family contexts, ethernet_context and flash_context, include the same.

context property_context is
  library ieee;
  use ieee.std_logic_1164.all;

  library vunit_lib;
  context vunit_lib.vunit_context;

  library python_bridge;
  context python_bridge.python_context;

  library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;
  use awesome_vunit_vcs.property_pkg.all;
end context;
