Cookbook
========

The cookbook is where we build real tests, one step at a time. Each article starts from a problem you
are likely to have, begins with the smallest test that passes, and adds one idea per step. Every step
says whether its code goes in your VHDL testbench or in a Python file, and shows the file. Every
snippet comes from an example that CI runs on GHDL and NVC, so what you copy works.

If you haven't installed the package yet, start with :doc:`../getting_started/quickstart`.

A reading path
--------------

Read the articles in this order: each one builds on the ones before it. Within an article, the basics
come first and a *Going further* section at the end holds the more advanced material.

.. list-table::
   :header-rows: 1
   :widths: 30 12 58

   * - Article
     - Level
     - What you'll build
   * - :doc:`first_test`
     - Basic
     - A GMII test from scratch: a source, a monitor, a check, statistics, a capture, popping and subscribing.
   * - :doc:`error_handling`
     - Basic
     - Tests that send broken frames on purpose and count the errors they cause.
   * - :doc:`beyond_gmii`
     - Basic
     - A short page: move any test to MII, RGMII, RMII, XGMII or AXI-Stream.
   * - :doc:`flash_boot`
     - Basic
     - A design booting from a QSPI flash image, with content and pin timing checks.
   * - :doc:`python_traffic`
     - Intermediate
     - Python functions called from VHDL: packets, seeded traffic, reference models and subscribers.
   * - :doc:`python_standalone`
     - Intermediate
     - Frames, checks, captures and Hypothesis strategies in plain Python, without a simulator.
   * - :doc:`property_testing`
     - Advanced
     - Properties that Hypothesis tests inside the simulation, up to sequences of operations.
   * - :doc:`property_errors`
     - Advanced
     - Corner cases, timing, backpressure and designs that lock up, found with properties.

Where your code goes
--------------------

A testbench using awesome-vunit-vcs has at most three kinds of files:

.. list-table::
   :header-rows: 1
   :widths: 25 12 63

   * - File
     - Language
     - What goes in it
   * - ``run.py``
     - Python
     - The VUnit run script: adds the packages and your source files, and sets configurations. Every
       project has one.
   * - ``tb_*.vhd``
     - VHDL
     - Your testbench: signals, component handles and instances, clocks, resets and the test cases. Most
       tests need nothing else.
   * - ``python/*.py``
     - Python
     - Only when you want it: functions that build packets or traffic, reference models, subscribers
       and Hypothesis strategies. Python never reads or drives signals.

In the articles, every code block's caption is the path of the file it comes from.

Running the examples
--------------------

Install the package as :doc:`../getting_started/installation` shows, then run any example from the
repository root. VUnit picks the simulator from ``VUNIT_SIMULATOR``:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/cookbook/run.py

Add a test name pattern such as ``"*capture*"`` to run one test, ``-v`` to see its log, or ``--gui`` to
open a waveform viewer.

The examples
------------

.. list-table::
   :header-rows: 1
   :widths: 22 48 10 20

   * - Example
     - What it shows
     - Simulators
     - Run it
   * - ``examples/quickstart``
     - The smallest complete testbench: a GMII source, a register stage and a monitor.
     - GHDL, NVC
     - ``python examples/quickstart/run.py``
   * - ``examples/cookbook``
     - The tests of the Ethernet articles on GMII, and the same frame on every other interface.
     - GHDL, NVC
     - ``python examples/cookbook/run.py``
   * - ``examples/gmii``
     - A realistic GMII testbench: monitors on both sides of a design, random frames, a Python
       subscriber and Scapy.
     - GHDL, NVC
     - ``python examples/gmii/run.py``
   * - ``examples/external_project``
     - A project outside the repository that finds the installed package by name.
     - GHDL, NVC
     - ``python examples/external_project/run.py``
   * - ``examples/python``
     - The Python API without a simulator: frames, decoding, checks, captures, Scapy, Hypothesis.
     - Python only
     - ``python examples/python/build_frames.py``
   * - ``examples/property``
     - Property-based testing in simulation with Hypothesis.
     - GHDL, NVC
     - ``python examples/property/run.py``

The flash article uses the flash testbenches in ``tests/vhdl``, run with ``python tests/vhdl/run.py``.

Find a feature
--------------

Every feature is either walked through in an article or linked from one. Use this table to jump
straight to it; the last column is the page with every option.

.. list-table:: Ethernet
   :header-rows: 1
   :widths: 35 35 30

   * - Feature
     - Walked through in
     - All options
   * - Source, monitor, frame check
     - :doc:`first_test`
     - :doc:`../ethernet/monitors`
   * - Protocol checker, counting and disabling checks, limits
     - :doc:`error_handling`
     - :doc:`../ethernet/checks`
   * - Malformed frames (``frame_options``)
     - :doc:`error_handling`
     - :doc:`../ethernet/packets_and_sequences`
   * - Scoreboard, blocking checks, popping frames, subscribing
     - :doc:`first_test` (Going further)
     - :doc:`../ethernet/scoreboard`
   * - Statistics
     - :doc:`first_test`
     - :doc:`../ethernet/statistics`
   * - Captures
     - :doc:`first_test`
     - :doc:`../ethernet/captures`
   * - Reset
     - :doc:`error_handling` (Going further)
     - :doc:`../ethernet/monitors`
   * - GMII
     - Every Ethernet article
     - :doc:`../ethernet/gmii`
   * - MII, RGMII (timing modes), RMII (``CRS_DV`` toggling), XGMII (lanes, rates up to 400G),
       AXI-Stream (sink, backpressure)
     - :doc:`beyond_gmii`
     - :doc:`../ethernet/mii`, :doc:`../ethernet/rgmii`, :doc:`../ethernet/rmii`,
       :doc:`../ethernet/xgmii`, :doc:`../ethernet/axis_mac`
   * - Packets and sequences with typed arguments and seeds
     - :doc:`python_traffic`
     - :doc:`../ethernet/packets_and_sequences`, :ref:`passing-arguments`
   * - Python subscribers in a simulation
     - :doc:`python_traffic` (Going further)
     - :doc:`../ethernet/python_simulation`
   * - Python API without a simulator
     - :doc:`python_standalone`
     - :doc:`../ethernet/python`, :doc:`../ethernet/python_api`
   * - VHDL API reference
     -
     - :doc:`../ethernet/vhdl_api`

.. list-table:: Property-based testing
   :header-rows: 1
   :widths: 35 35 30

   * - Feature
     - Walked through in
     - All options
   * - Scalar and composite examples, paths
     - :doc:`property_testing`
     - :doc:`../property_testing/index`
   * - Records generated from dataclasses
     - :doc:`property_testing`
     - :doc:`../property_testing/records`
   * - Stateful properties
     - :doc:`property_testing` (Going further)
     - :doc:`../property_testing/strategies`
   * - Score, metamorphic, timing, swarm
     - :doc:`property_errors`
     - :doc:`../property_testing/strategies`
   * - Lockups
     - :doc:`property_errors` (Going further)
     - :doc:`../property_testing/index`
   * - Pins, profiles, seeds, replaying failures
     - :doc:`property_errors`
     - :doc:`../property_testing/reproducing`
   * - API reference
     -
     - :doc:`../property_testing/vhdl_api`, :doc:`../property_testing/python_api`

.. list-table:: Flash and QSPI
   :header-rows: 1
   :widths: 35 35 30

   * - Feature
     - Walked through in
     - All options
   * - Load an image, preload, boot, check content
     - :doc:`flash_boot`
     - :doc:`../flash/qspi_flash`
   * - Flash configuration (size, IDs, timing)
     - :doc:`flash_boot`
     - :doc:`../flash/configuration`
   * - Protocol checker and pin timing
     - :doc:`flash_boot`
     - :doc:`../flash/qspi_protocol_checker`
   * - Checks and errors
     - :doc:`flash_boot`
     - :doc:`../flash/checks`
   * - Reset, statistics
     - :doc:`flash_boot`
     - :doc:`../flash/statistics`
   * - QSPI master transfers and flash commands
     - :doc:`flash_boot` (Going further)
     - :doc:`../flash/qspi_master`, :doc:`../flash/commands`
   * - Flash model in Python
     - :doc:`python_standalone` (Going further)
     - :doc:`../flash/python`
   * - API reference
     -
     - :doc:`../flash/vhdl_api`, :doc:`../flash/python_api`

.. toctree::
   :hidden:
   :caption: Basic

   first_test
   error_handling
   beyond_gmii
   flash_boot

.. toctree::
   :hidden:
   :caption: Intermediate

   python_traffic
   python_standalone

.. toctree::
   :hidden:
   :caption: Advanced

   property_testing
   property_errors
