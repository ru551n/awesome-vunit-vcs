Using another interface
=======================

The Ethernet articles use GMII, but everything they teach works on every interface. Only three things
change: the handle type, the entity you instantiate, and the clock. The test cases stay exactly the
same.

Everything in this article is VHDL, in :repo-file:`examples/cookbook/tb_cookbook_interfaces.vhd`.

.. include:: ../_includes/vunit_names.inc

The test stays the same
-----------------------

Here is the MII version of the frame check from :doc:`first_test`. Only the handle names differ:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: mii-test
   :end-before: -- docs-end: mii-test
   :dedent:

What changes: handles, signals and clock
----------------------------------------

For MII, create the handles with the link rate, declare the four-bit signals and pick the clock to
match the rate:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: mii-handles
   :end-before: -- docs-end: mii-handles
   :dedent:

Then instantiate the MII entities instead of the GMII ones:

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: mii-instances
   :end-before: -- docs-end: mii-instances
   :dedent:

Every other interface follows the same pattern. The same testbench file shows each of them, and its
interface page lists every option:

.. list-table::
   :header-rows: 1
   :widths: 18 52 30

   * - Interface
     - What to know
     - Page
   * - MII
     - 10 or 100 Mbit/s; 2.5 or 25 MHz clock.
     - :doc:`../ethernet/mii`
   * - RGMII
     - 10, 100 or 1000 Mbit/s on both clock edges; ``data_timing => rgmii_edge_aligned`` for outputs
       registered on the clock edge.
     - :doc:`../ethernet/rgmii`
   * - RMII
     - 10 or 100 Mbit/s on a 50 MHz reference clock; ``crs_dv_toggle_octets`` emulates a PHY whose
       ``CRS_DV`` toggles.
     - :doc:`../ethernet/rmii`
   * - XGMII
     - 4 lanes for 10G, 8 lanes for 25G up to 400G; size signals with ``data_length`` and
       ``ctrl_length``.
     - :doc:`../ethernet/xgmii`
   * - AXI-Stream
     - No preamble; add an ``axis_mac_sink`` to drive ``tready`` and apply backpressure.
     - :doc:`../ethernet/axis_mac`

Run the same test at several rates
----------------------------------

When a design supports several rates, make the rates generics of the testbench and add one
configuration per set of rates in the run script (Python), on the library ``lib`` it adds the testbenches
to. VUnit then runs every test case at each:

.. literalinclude:: ../../examples/cookbook/run.py
   :caption: examples/cookbook/run.py
   :language: python
   :start-after: # docs-start: interface-configs
   :end-before: # docs-end: interface-configs
