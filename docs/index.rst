awesome-vunit-vcs
=================

Verification components for `VUnit <https://vunit.github.io/>`__ that feel like VUnit's own:
a handle per component, VUnit logging and checks, ``com`` messages and the standard VUnit interfaces.
Ethernet is the first family.

**VHDL handles simulation timing. Python handles verification semantics.**

The VHDL components connect to the pins of your design. Frame reconstruction, protocol checks,
statistics, Wireshark captures and packet construction happen in Python behind them, and a test never
has to write Python.

.. grid:: 1 1 2 2
   :gutter: 2

   .. grid-item-card:: Quick start
      :link: getting_started/quickstart
      :link-type: doc

      Install, run a GMII testbench and open the traffic in Wireshark, in five minutes.

   .. grid-item-card:: Ethernet guide
      :link: ethernet/index
      :link-type: doc

      Sources, monitors and protocol checkers for MII, GMII and the XGMII family.

   .. grid-item-card:: Cookbook
      :link: cookbook/index
      :link-type: doc

      Short recipes for the common tasks, each from a tested example.

   .. grid-item-card:: Property-based testing
      :link: property_testing/index
      :link-type: doc

      Let Hypothesis find the smallest input that breaks your design, inside the simulation.

Status
------

.. list-table::
   :header-rows: 1
   :widths: 20 20 20 40

   * - Interface
     - Link rates
     - Status
     - Components
   * - GMII
     - 1G, 2.5G
     - Done
     - ``gmii_source``, ``gmii_monitor``, ``gmii_protocol_checker``
   * - MII
     - 10M, 100M
     - Done
     - ``mii_source``, ``mii_monitor``, ``mii_protocol_checker``
   * - XGMII family
     - 2.5G to 400G
     - Done
     - ``xgmii_source``, ``xgmii_monitor``, ``xgmii_protocol_checker``
   * - RGMII, RMII, AXI-Stream MAC client
     -
     - Planned
     - See the :doc:`roadmap`

Tested with GHDL and NVC in CI.

.. note::

   The project is alpha software: the APIs can still change, and the package is not released on PyPI
   yet. See :doc:`getting_started/installation`.

.. toctree::
   :maxdepth: 2
   :caption: Getting started
   :hidden:

   getting_started/quickstart
   getting_started/installation
   getting_started/vunit_integration

.. toctree::
   :maxdepth: 2
   :caption: Cookbook
   :hidden:

   cookbook/index

.. toctree::
   :maxdepth: 2
   :caption: Ethernet
   :hidden:

   ethernet/index

.. toctree::
   :maxdepth: 2
   :caption: Property-based testing
   :hidden:

   property_testing/index

.. toctree::
   :maxdepth: 2
   :caption: Common
   :hidden:

   common/index

.. toctree::
   :maxdepth: 1
   :caption: Help and project
   :hidden:

   troubleshooting
   glossary
   contributing/index
   roadmap
   release_notes/index
