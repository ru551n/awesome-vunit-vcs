Cookbook
========

Short recipes for the tasks a testbench does most. Each recipe shows one task with a snippet from an
example that CI runs on GHDL and NVC. What you copy works.

Every recipe has the same parts:

* **Goal**: one sentence.
* **Snippet**: the few lines that do it, taken from a tested example.
* **When to use this**, and a few tips.
* **Full example**: the file on GitHub and the command that runs it.
* **See also**: the guide pages with more details.

Running the examples
--------------------

Install the package as :doc:`../getting_started/installation` shows, then run any example from the
repository root. VUnit picks the simulator from ``VUNIT_SIMULATOR``:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/cookbook/run.py

Add a test name pattern such as ``"*capture*"`` to run one test, or ``--gui`` to open a waveform
viewer.

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
     - One short test case per common construct, and MII and XGMII at several rates.
     - GHDL, NVC
     - ``python examples/cookbook/run.py``
   * - ``examples/gmii``
     - A realistic GMII testbench: monitors on both sides of a DUT, random frames, a Python
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

Recipes
-------

.. toctree::
   :maxdepth: 2
   :caption: Setup

   setup

.. toctree::
   :maxdepth: 2
   :caption: Ethernet

   sources
   monitors
   interfaces
   python

.. toctree::
   :maxdepth: 2
   :caption: Property-based testing

   properties

.. toctree::
   :maxdepth: 2
   :caption: Flash and QSPI

   flash

.. toctree::
   :maxdepth: 2
   :caption: Python and VHDL together

   python_and_vhdl
