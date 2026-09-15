Statistics
==========

Every :term:`monitor` keeps statistics of the frames it receives. :doc:`monitors` shows how to create
the monitor.

.. include:: ../_includes/vunit_names.inc

Read and log statistics
-----------------------

.. code-block:: vhdl
   :caption: Check totals at the end of a test

   variable statistics : ethernet_statistics_t;
   ...
   wait_until_idle(net, as_sync(monitor));
   get_statistics(net, monitor, statistics);
   check_equal(statistics.good_frames, 20);
   check_equal(statistics.fcs_errors, 0);
   log_statistics(net, monitor);          -- info level by default

``log_statistics`` prints a summary like this one, from the :doc:`../getting_started/quickstart`:

.. code-block:: text
   :caption: log_statistics output

   frames: total=10 good=10 bad=0
   octets: wire=894 frame=814 payload=634
   errors: fcs=0 phy_frames=0 phy_symbols=0 idle=0 runt=0 giant=0 preamble=0 sfd=0 alignment=0
   frame size: min=64 max=118 mean=81.4 octets
   inter-frame gap: min=12 max=12 mean=12.0 octets
   window: 8016000000 fs, 1247505.0 frames/s, bit rate 812.375 Mbit/s
   utilization: link 89.22 %, payload 63.27 %
   size histogram: <64=0 64=4 65-127=6 128-255=0 256-511=0 512-1023=0 1024-1518=0 >1518=0

Use the fields
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Field of ``ethernet_statistics_t``
     - Meaning
   * - ``total_frames``, ``good_frames``, ``bad_frames``
     - Frames received. Good frames have a correct FCS and no PHY error.
   * - ``wire_octets``
     - Preamble, SFD and frame octets
   * - ``payload_octets``
     - Octets after the 14-octet header, excluding the FCS
   * - ``fcs_errors``
     - Frames with a bad FCS
   * - ``phy_error_frames``
     - Frames with the error signal asserted
   * - ``runts``, ``giants``
     - Frames outside the size limits
   * - ``min_frame_octets``, ``max_frame_octets``
     - Smallest and largest frame
   * - ``min_ifg_octets``, ``max_ifg_octets``
     - Shortest and longest gap between frames

Good to know
------------

* Set ``link_rate_mbps`` to the rate of the link, or utilization and bit rate are wrong.
* A minimum or maximum without a value is -1. Octet counts stop at ``integer'high``.
* ``reset(net, monitor, clear_statistics => true)`` starts the counts over.
* ``get_frame_count`` returns only the number of frames.
* In Python, ``vc.statistics`` gives the same numbers plus rates and the histogram; see :doc:`python`.

Related recipes
---------------

* :doc:`../cookbook/first_test`: *Check the statistics*

API reference
-------------

:vhdl:`ethernet_pkg.ethernet_statistics_t`, :vhdl:`ethernet_pkg.get_statistics`,
:vhdl:`ethernet_pkg.get_frame_count`, :vhdl:`ethernet_pkg.log_statistics`
