Captures
========

A monitor writes the frames it receives to a PCAPNG file that Wireshark opens directly.

.. code-block:: vhdl

   start_capture(net, monitor, output_path(runner_cfg) & "rx.pcapng");
   ...
   stop_capture(net, monitor);   -- optional: captures are closed at test_runner_cleanup

What a capture contains
-----------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Content
     - Behaviour
   * - Link type
     - Ethernet: frames start at the destination address. Preamble and SFD are never written.
   * - FCS
     - Written by default; ``include_fcs => false`` leaves it out.
   * - Errored frames
     - Written by default with Wireshark's link-layer error flags (CRC, preamble, SFD, IFG, size, symbol)
       and a comment; ``include_errored => false`` leaves them out. Frames without an SFD are skipped.
   * - Timestamps
     - Simulation time of the first octet after the SFD, at femtosecond resolution.

.. code-block:: vhdl

   start_capture(net, monitor, output_path(runner_cfg) & "good_frames.pcapng", include_errored => false);

Opening it
----------

.. code-block:: bash

   wireshark vunit_out/test_output/<test>/rx.pcapng

.. tip::

   Wireshark shows simulation time as seconds since 1970. Use *View → Time Display Format → Seconds Since
   Beginning of Capture* to read it as simulation time.

Several monitors can capture at once, each to its own file.

Disk usage
----------

A capture grows by roughly the frame octets plus 32 octets per frame. A long randomized test writes large
files, so capture only the tests where you look at the traffic, and use ``include_errored => false`` or
``stop_capture`` to bound it. VUnit's output path is cleared by ``--clean``.

From Python, ``eth.write_pcapng(path, frames)`` writes frames you built yourself; see
:doc:`../python_guide`.
