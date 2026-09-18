awesome-vunit-vcs
=================

Verification components for `VUnit <https://vunit.github.io/>`__ that work like VUnit's own. You
connect them to the pins of your design, and they send, receive and check traffic for you. Your
testbench stays in VHDL; Python does the frame work behind the components.

**VHDL handles simulation timing. Python handles verification semantics.**

The project is alpha: the APIs can still change, and the package is not on PyPI yet.

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
   * - RGMII
     - 10M, 100M, 1G
     - Done
     - ``rgmii_source``, ``rgmii_monitor``, ``rgmii_protocol_checker``
   * - RMII
     - 10M, 100M
     - Done
     - ``rmii_source``, ``rmii_monitor``, ``rmii_protocol_checker``
   * - QSPI NOR flash
     - x1, x2, x4 lanes
     - Done
     - ``flash``, ``qspi_master``, ``qspi_protocol_checker``
   * - AXI-Stream MAC client
     - Any
     - Done
     - ``axis_mac_source``, ``axis_mac_sink``, ``axis_mac_monitor``, ``axis_mac_protocol_checker``
   * - I2C
     - 100 kHz, 400 kHz, 1 MHz
     - Done
     - ``i2c_master``, ``i2c_target``, ``i2c_monitor``, ``i2c_protocol_checker``
   * - AXI4, AXI4-Lite
     - Data 8 to 1024 bits
     - Done
     - ``axi4_monitor``, ``axi4_protocol_checker``, ``axi4_read_slave``, ``axi4_write_slave``

Every component is tested with GHDL and NVC.

Install
-------

.. code-block:: bash
   :caption: Install from the repository

   git clone https://github.com/ru551n/awesome-vunit-vcs.git
   cd awesome-vunit-vcs
   pip install -r tests/packaging/unreleased-requirements.txt
   pip install .

You also need GHDL or NVC, and on Linux or macOS a C compiler. :doc:`getting_started/installation`
has the details.

Start here
----------

.. grid:: 1 1 2 2
   :gutter: 2

   .. grid-item-card:: Quick start
      :link: getting_started/quickstart
      :link-type: doc

      Run a GMII testbench and open the traffic in Wireshark, in five minutes.

   .. grid-item-card:: Cookbook
      :link: cookbook/index
      :link-type: doc

      Short recipes for common tasks, each taken from a tested example.

Components
----------

.. grid:: 1 1 2 2
   :gutter: 2

   .. grid-item-card:: Ethernet
      :link: ethernet/index
      :link-type: doc

      Sources, monitors and protocol checkers for MII, GMII and the XGMII family.

   .. grid-item-card:: Property-based testing
      :link: property_testing/index
      :link-type: doc

      Let Hypothesis find the smallest input that breaks your design.

   .. grid-item-card:: Flash / QSPI
      :link: flash/index
      :link-type: doc

      A QSPI NOR flash model, a QSPI master and a QSPI protocol checker.

   .. grid-item-card:: I2C
      :link: i2c/index
      :link-type: doc

      An I2C master, a target with device models in Python, a monitor and a protocol checker.

   .. grid-item-card:: AXI4
      :link: axi4/index
      :link-type: doc

      An AXI4 and AXI4-Lite monitor with a shadow memory and performance statistics, a protocol
      checker, and read and write slaves on a sparse memory.

   .. grid-item-card:: Common
      :link: common/index
      :link-type: doc

      Calling your own Python code from VHDL, and the shared API.

For AI agents
-------------

Agents and other tools can read the documentation as plain Markdown:
`llms.txt <llms.txt>`__ lists every page and `llms-full.txt <llms-full.txt>`__ holds all of them. Every
page also has a Markdown version: replace ``.html`` with ``.md``. `api/vhdl.json <api/vhdl.json>`__,
`api/python.json <api/python.json>`__ and `api/examples.json <api/examples.json>`__ list every
declaration, signature and cookbook example.

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
   :caption: Flash / QSPI
   :hidden:

   flash/index

.. toctree::
   :maxdepth: 2
   :caption: I2C
   :hidden:

   i2c/index

.. toctree::
   :maxdepth: 2
   :caption: AXI4
   :hidden:

   axi4/index

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
