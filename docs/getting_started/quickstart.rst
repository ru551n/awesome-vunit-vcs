Quick start
===========

In five minutes you install the package, run a testbench that sends GMII frames through a design,
and open the captured traffic in Wireshark.

1. Install the package
----------------------

.. tab-set::

   .. tab-item:: From the repository (today)

      .. code-block:: bash
         :caption: Terminal

         git clone https://github.com/ru551n/awesome-vunit-vcs.git
         cd awesome-vunit-vcs
         python -m venv .venv && source .venv/bin/activate
         pip install -r tests/packaging/unreleased-requirements.txt
         pip install .

   .. tab-item:: From PyPI (once released)

      .. code-block:: bash
         :caption: Terminal

         pip install awesome-vunit-vcs

.. warning::

   The package and its dependencies are not released yet, so install from the repository. You also
   need GHDL or NVC, and on Linux or macOS a C compiler; see :doc:`installation`.

2. Write the run script
-----------------------

.. literalinclude:: ../../examples/quickstart/run.py
   :language: python
   :caption: examples/quickstart/run.py
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

You add both packages by name. Neither the script nor the testbench needs to know where they are
installed.

3. Write the testbench
----------------------

.. literalinclude:: ../../examples/quickstart/tb_quickstart.vhd
   :language: vhdl
   :caption: examples/quickstart/tb_quickstart.vhd
   :start-after: -- docs-start: testbench
   :end-before: -- docs-end: testbench

A ``gmii_source`` drives the input of a one-register design. A ``gmii_monitor`` with the default
:term:`protocol checker` watches its output and writes a capture file. The test queues the expected
frames, sends the same frames, waits until everything is idle and checks the statistics.

What each part does:

.. list-table::
   :widths: 35 65

   * - ``context awesome_vunit_vcs.ethernet_context``
     - Everything a testbench needs, VUnit included.
   * - ``new_gmii_source``, ``new_gmii_monitor``
     - Create the handles. Every parameter has a default; the protocol checker is opt-in.
   * - ``check_ethernet_frame(..., blocking => false)``
     - Queue an expected frame for the scoreboard. A difference is an ``ETH_SCOREBOARD`` error.
   * - ``push_ethernet_frame``
     - Transmit a frame given from the destination address up to the FCS. Python adds preamble, SFD,
       padding and FCS.
   * - ``wait_until_idle``
     - Wait until the source has transmitted everything and the monitor has processed it.
   * - ``get_statistics``, ``log_statistics``
     - Read or log the statistics of the received frames.

4. Run the test
---------------

.. tab-set::

   .. tab-item:: GHDL

      .. code-block:: bash
         :caption: Terminal

         VUNIT_SIMULATOR=ghdl python examples/quickstart/run.py

   .. tab-item:: NVC

      .. code-block:: bash
         :caption: Terminal

         VUNIT_SIMULATOR=nvc python examples/quickstart/run.py

The test passes, and ``log_statistics`` prints a summary like this one:

.. code-block:: text
   :caption: Statistics in the test log

   frames: total=10 good=10 bad=0
   octets: wire=894 frame=814 payload=634
   frame size: min=64 max=118 mean=81.4 octets
   inter-frame gap: min=12 max=12 mean=12.0 octets
   utilization: link 89.22 %, payload 63.27 %

5. Open the traffic in Wireshark
--------------------------------

.. code-block:: bash
   :caption: Terminal

   wireshark vunit_out/test_output/lib.tb_quickstart.all_*/quickstart.pcapng

The capture is in the output path of the test. Timestamps are simulation time. See
:doc:`../ethernet/captures`.

Next steps
----------

.. list-table::
   :widths: 40 60

   * - Send a bad FCS and count the error
     - :doc:`../ethernet/checks`
   * - Use another interface
     - :doc:`../ethernet/xgmii`, :doc:`../ethernet/mii`
   * - Generate traffic in Python
     - :doc:`../ethernet/packets_and_sequences`
   * - Find a recipe for a common task
     - :doc:`../cookbook/index`
   * - See a larger example with two monitors, a Python subscriber and Scapy
     - :doc:`../ethernet/gmii`
