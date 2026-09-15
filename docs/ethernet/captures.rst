Captures
========

A :term:`monitor` writes the frames it receives to a PCAPNG file that Wireshark opens directly.
:doc:`monitors` shows how to create the monitor.

Capture a test
--------------

.. code-block:: vhdl
   :caption: Start and stop a capture

   start_capture(net, monitor, output_path(runner_cfg) & "rx.pcapng");
   ...
   stop_capture(net, monitor);   -- optional: captures are closed at test_runner_cleanup

Several monitors can capture at once, each to its own file.

Choose what a capture contains
------------------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Content
     - Behaviour
   * - Frames
     - From the destination address on. Preamble and SFD are never written.
   * - FCS
     - Written by default. ``include_fcs => false`` leaves it out.
   * - Errored frames
     - Written by default, flagged as errors in Wireshark. ``include_errored => false`` leaves them out.
       Frames without an SFD are skipped.
   * - Timestamps
     - Simulation time of the first octet after the SFD.

.. code-block:: vhdl
   :caption: Capture only good frames

   start_capture(net, monitor, output_path(runner_cfg) & "good_frames.pcapng",
                 include_errored => false);

Open a capture in Wireshark
---------------------------

.. code-block:: bash
   :caption: Terminal

   wireshark vunit_out/test_output/<test>/rx.pcapng

.. tip::

   Wireshark shows simulation time as seconds since 1970. Use *View → Time Display Format → Seconds
   Since Beginning of Capture* to read it as simulation time.

Good to know
------------

* A capture grows by about the frame octets plus 32 octets per frame. Capture only the tests you
  debug.
* Use ``include_errored => false`` or ``stop_capture`` to keep long tests small.
* VUnit's ``--clean`` removes the output path, captures included.
* From Python, ``eth.write_pcapng(path, frames)`` writes frames you built yourself; see :doc:`python`.

Related recipes
---------------

* :doc:`../cookbook/first_test`: *Capture the traffic for Wireshark*
* :doc:`../cookbook/python_standalone`: *Save traffic for Wireshark*

API reference
-------------

:vhdl:`ethernet_pkg.start_capture`, :vhdl:`ethernet_pkg.stop_capture`
