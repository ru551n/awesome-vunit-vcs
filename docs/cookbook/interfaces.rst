Interfaces
==========

Every interface uses the same procedures; only the handles, the entities and the clock differ. The
recipes come from :repo-file:`examples/cookbook/tb_cookbook_interfaces.vhd`, which connects each
source straight to a monitor.

Use GMII
--------

**Goal:** 1G traffic with 8-bit data, data valid and error signals.

**When to use this:** for 1G designs with a GMII interface. Every recipe on :doc:`sources` and
:doc:`monitors` uses GMII.

**Full example:** :repo-file:`examples/cookbook/tb_cookbook.vhd`

**See also:** :doc:`../ethernet/gmii`

Use MII at 10 or 100 Mbit/s
---------------------------

**Goal:** 4-bit MII with the clock for the link rate.

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: mii
   :end-before: -- docs-end: mii
   :dedent:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: mii-instances
   :end-before: -- docs-end: mii-instances
   :dedent:

**When to use this:** for 10M and 100M designs with an MII interface.

* Give the source and the monitor the same ``link_rate_mbps``.
* Use a 2.5 MHz clock at 10 Mbit/s and 25 MHz at 100 Mbit/s.

**Full example:** ``test_mii``

.. code-block:: console
   :caption: Terminal

   $ python examples/cookbook/run.py "*test_mii"

**See also:** :doc:`../ethernet/mii`

Use RGMII at 10, 100 or 1000 Mbit/s
-----------------------------------

**Goal:** RGMII on both clock edges, with the clock for the link rate.

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rgmii
   :end-before: -- docs-end: rgmii
   :dedent:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rgmii-instances
   :end-before: -- docs-end: rgmii-instances
   :dedent:

**When to use this:** for designs with an RGMII port, such as an FPGA MAC connected to a gigabit PHY.

* Give the source and the monitor the same ``link_rate_mbps``.
* Use a 125 MHz clock at 1000 Mbit/s, 25 MHz at 100 and 2.5 MHz at 10.
* Set ``data_timing => rgmii_edge_aligned`` on a monitor that observes outputs registered on the clock.

**Full example:** ``test_rgmii``

.. code-block:: console
   :caption: Terminal

   $ python examples/cookbook/run.py "*test_rgmii"

**See also:** :doc:`../ethernet/rgmii`

Use RMII at 10 or 100 Mbit/s
----------------------------

**Goal:** RMII on its 50 MHz reference clock.

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rmii
   :end-before: -- docs-end: rmii
   :dedent:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rmii-instances
   :end-before: -- docs-end: rmii-instances
   :dedent:

**When to use this:** for 10M and 100M designs with an RMII port.

* The reference clock is 50 MHz at both rates; only ``link_rate_mbps`` changes.
* Set ``crs_dv_toggle_octets`` on a source to test a MAC against a PHY whose ``CRS_DV`` toggles.

**Full example:** ``test_rmii``

.. code-block:: console
   :caption: Terminal

   $ python examples/cookbook/run.py "*test_rmii"

**See also:** :doc:`../ethernet/rmii`

Use XGMII, from 10G up to 400G
------------------------------

**Goal:** the XGMII family with 4 or 8 lanes.

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: xgmii
   :end-before: -- docs-end: xgmii
   :dedent:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: xgmii-instances
   :end-before: -- docs-end: xgmii-instances
   :dedent:

**When to use this:** 4 lanes for 10G XGMII; 8 lanes for 25G, 40G, 100G, 200G and 400G interfaces.

* Size the signals with ``data_length`` and ``ctrl_length`` instead of numbers.
* Give the source and the monitor the same ``lanes`` and ``link_rate_mbps``.

**Full example:** ``test_xgmii``

**See also:** :doc:`../ethernet/xgmii`

Use an AXI-Stream MAC client with backpressure
----------------------------------------------

**Goal:** frames on an AXI-Stream bus, with a sink that holds ``tready`` low on some clocks.

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: axis-mac
   :end-before: -- docs-end: axis-mac
   :dedent:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: axis-mac-instances
   :end-before: -- docs-end: axis-mac-instances
   :dedent:

**When to use this:** for designs that take or give Ethernet frames on AXI-Stream, such as the client
side of a MAC core.

* Frame data starts at the destination address, as with every other interface.
* Connect the monitor to the same ``tready`` as the sink; it only observes.
* Change the backpressure during a test with ``set_ready_pattern``.

**Full example:** ``test_axis_mac``

**See also:** :doc:`../ethernet/axis_mac`

Run one testbench at several rates
----------------------------------

**Goal:** reuse a testbench for different lane counts and link rates.

.. literalinclude:: ../../examples/cookbook/run.py
   :caption: examples/cookbook/run.py
   :language: python
   :start-after: # docs-start: interface-configs
   :end-before: # docs-end: interface-configs

**When to use this:** when the DUT supports several rates and every test should run at each of them.

* Each configuration sets the testbench generics and reruns every test case.
* ``python run.py --list`` shows the test names with the configuration names.

**Full example:** :repo-file:`examples/cookbook/run.py`

**See also:** `VUnit configurations <https://vunit.github.io/py/ui.html#configurations>`__
