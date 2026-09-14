awesome-vunit-vcs
=================

Verification components for `VUnit <https://vunit.github.io/>`__ that feel like VUnit's own:
a handle per component, VUnit logging and checks, ``com`` messages and the standard VUnit interfaces.
Ethernet is the first family.

**VHDL handles simulation timing. Python handles verification semantics.**

The VHDL components sample and drive the pins at the right simulation edges and exchange batched
observations with Python through the VUnit Python bridge. Frame reconstruction, protocol checks,
statistics, Wireshark captures and packet construction are simulator independent Python, and a test
never has to write Python.

.. grid:: 1 1 3 3
   :gutter: 2

   .. grid-item-card:: Quick start
      :link: getting_started/quickstart
      :link-type: doc

      Install, run a GMII testbench and open the traffic in Wireshark, in five minutes.

   .. grid-item-card:: Ethernet guide
      :link: ethernet/index
      :link-type: doc

      Sources, monitors and protocol checkers for MII, GMII and the XGMII family.

   .. grid-item-card:: API reference
      :link: reference/vhdl/index
      :link-type: doc

      Every VHDL declaration, generated from the sources, and the Python API.

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
   :caption: Examples library
   :hidden:

   cookbook/index

.. toctree::
   :maxdepth: 2
   :caption: Ethernet
   :hidden:

   ethernet/index

.. toctree::
   :maxdepth: 2
   :caption: Python
   :hidden:

   python_guide
   property_testing
   python_api

.. toctree::
   :maxdepth: 2
   :caption: VHDL API reference
   :hidden:

   reference/vhdl/index

.. toctree::
   :maxdepth: 1
   :caption: Concepts
   :hidden:

   explanation/architecture
   explanation/design_decisions
   explanation/performance
   explanation/limitations

.. toctree::
   :maxdepth: 1
   :caption: Help
   :hidden:

   troubleshooting
   glossary

.. toctree::
   :maxdepth: 1
   :caption: Project
   :hidden:

   roadmap
   release_notes/index
   contributing/index
