Quick start
===========

In five minutes: install the package, run a testbench that sends GMII frames through a design and
checks them, and open the captured traffic in Wireshark.

1. Install
----------

.. tab-set::

   .. tab-item:: From the repository (today)

      .. code-block:: bash

         git clone https://github.com/ru551n/awesome-vunit-vcs.git
         cd awesome-vunit-vcs
         python -m venv .venv && source .venv/bin/activate
         pip install -r tests/packaging/unreleased-requirements.txt
         pip install .

   .. tab-item:: From PyPI (once released)

      .. code-block:: bash

         pip install awesome-vunit-vcs

.. warning::

   The package, vunit-python-bridge and the VUnit version they need are not released yet, so install
   from the repository. Linux and macOS also need a C compiler and the Python development headers;
   see :doc:`installation`.

You also need GHDL or NVC.

2. The run script
-----------------

The packages are added by name. Neither the script nor the testbench knows where they are installed.

.. literalinclude:: ../../examples/quickstart/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

3. The testbench
----------------

A ``gmii_source`` drives the input of a one-register design, and a ``gmii_monitor`` with the default
protocol checks observes its output. The test tells the monitor which frames to expect, pushes the
same frames into the source, waits until both are idle and checks the statistics. The monitor also
writes everything it receives to a capture file.

.. literalinclude:: ../../examples/quickstart/tb_quickstart.vhd
   :language: vhdl
   :start-after: -- docs-start: testbench
   :end-before: -- docs-end: testbench

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

4. Run it
---------

.. tab-set::

   .. tab-item:: GHDL

      .. code-block:: bash

         VUNIT_SIMULATOR=ghdl python examples/quickstart/run.py

   .. tab-item:: NVC

      .. code-block:: bash

         VUNIT_SIMULATOR=nvc python examples/quickstart/run.py

The test passes, and ``log_statistics`` prints a summary like this one:

.. code-block:: text

   frames: total=10 good=10 bad=0
   octets: wire=894 frame=814 payload=634
   frame size: min=64 max=118 mean=81.4 octets
   inter-frame gap: min=12 max=12 mean=12.0 octets
   utilization: link 89.22 %, payload 63.27 %

5. Look at the traffic in Wireshark
-----------------------------------

The capture is in the output path of the test:

.. code-block:: bash

   wireshark vunit_out/test_output/lib.tb_quickstart.all_*/quickstart.pcapng

Timestamps are simulation time, and errored frames carry Wireshark's link-layer error flags. See
:doc:`../ethernet/captures`.

Next steps
----------

* Break something on purpose: :doc:`../ethernet/checks` shows how to send a bad FCS and count the
  error instead of failing the test.
* Use another interface: :doc:`../ethernet/xgmii` and :doc:`../ethernet/mii`.
* Generate traffic in Python: :doc:`../ethernet/packets_and_sequences`.
* A larger example with random frames, two monitors, a Python subscriber and Scapy is described on
  :doc:`../ethernet/gmii`.
