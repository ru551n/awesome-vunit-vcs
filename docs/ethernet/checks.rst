Checks
======

A :term:`protocol checker` runs the protocol checks, all enabled by default. A :term:`monitor` runs
the scoreboard. :doc:`monitors` shows how to create both.

A violation is an error on the checker of the component that found it. The message starts with the
check ID in upper case:

.. code-block:: text
   :caption: A violation in the test log

   ETH_FCS: bad FCS on frame 27
   expected=0x2144DF1C
   received=0x3144DF1C

Get the protocol checks
-----------------------

.. code-block:: vhdl
   :caption: Monitors with protocol checks

   -- A monitor with the default protocol checks
   constant monitor : gmii_monitor_t :=
     new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);

   -- A monitor with a protocol checker of your own limits
   constant monitor : gmii_monitor_t := new_gmii_monitor(
     protocol_checker => new_gmii_protocol_checker(max_frame_octets => 9018)
   );

You can also instantiate a protocol checker entity on its own, without a monitor.

Look up a check
---------------

.. list-table::
   :header-rows: 1
   :widths: 20 45 20 15

   * - Check
     - Violation
     - Configured by
     - Interfaces
   * - ``eth_preamble``
     - Preamble length outside the limits, or a malformed preamble octet
     - ``min_preamble_octets``, ``max_preamble_octets``
     - all
   * - ``eth_sfd``
     - No SFD after the preamble
     -
     - all
   * - ``eth_fcs``
     - The FCS does not match the frame
     - ``has_fcs``
     - all
   * - ``eth_runt``
     - A frame shorter than the minimum
     - ``min_frame_octets``
     - all
   * - ``eth_giant``
     - A frame longer than the maximum
     - ``max_frame_octets`` (0 turns it off)
     - all
   * - ``eth_phy_error``
     - The error signal or Error character during a frame
     -
     - all
   * - ``eth_carrier``
     - The error signal or Error character outside a frame
     -
     - all
   * - ``eth_ifg``
     - A gap between frames shorter than the minimum
     - ``min_ifg_octets``
     - all
   * - ``eth_termination``
     - A frame ended with an incomplete octet (MII) or without Terminate (XGMII)
     -
     - MII, XGMII
   * - ``eth_metavalue``
     - A metavalue on the data during a frame, or on the valid or error signal
     -
     - all
   * - ``eth_frame_state``
     - A frame in progress when monitoring started, or still in progress when it ended
     -
     - all
   * - ``eth_control``
     - An invalid or misplaced control character
     - ``allow_lane4_start``
     - XGMII
   * - ``eth_link_fault``
     - A local or remote fault ordered set
     -
     - XGMII
   * - ``eth_scoreboard``
     - A received frame differs from the expected one, or expected frames never arrived (monitor)
     -
     - all
   * - ``eth_user``
     - An error reported by your Python code with ``vc.error``
     -
     - all
   * - ``eth_keep``
     - ``tkeep`` not contiguous, or a partial beat before ``tlast``
     -
     - AXI-Stream MAC client
   * - ``eth_stable``
     - ``tdata``, ``tkeep``, ``tlast`` or ``tuser`` changed while ``tvalid`` waited for ``tready``
     -
     - AXI-Stream MAC client
   * - ``eth_valid``
     - ``tvalid`` went low before ``tready`` accepted the beat
     -
     - AXI-Stream MAC client

Send traffic that breaks the rules
----------------------------------

``frame_options`` makes the source send traffic the standard forbids:

.. list-table::
   :header-rows: 1
   :widths: 45 30 25

   * - Options
     - Sends
     - Triggers
   * - ``frame_options(fcs => fcs_bad)``
     - An inverted FCS
     - ``eth_fcs``
   * - ``frame_options(fcs => fcs_none)``
     - No FCS and no padding
     - ``eth_fcs``, possibly ``eth_runt``
   * - ``frame_options(pad => false)``
     - A short frame without padding
     - ``eth_runt``
   * - ``frame_options(preamble_octets => 5)``
     - A short preamble
     - ``eth_preamble``
   * - ``frame_options(sfd => x"D4")``
     - A wrong SFD
     - ``eth_sfd``
   * - ``frame_options(error_offsets => (0 => 20))``
     - The error signal on octet 20 after the SFD
     - ``eth_phy_error``
   * - ``frame_options(ifg_octets => 8)``
     - An 8-octet gap after the frame
     - ``eth_ifg`` on the next frame

Error offsets count from the first octet after the SFD. Negative offsets reach into the SFD and the
preamble. XGMII sends the Error character instead of the error signal.

Count errors instead of failing
-------------------------------

.. code-block:: vhdl
   :caption: Assert that a bad FCS is detected

   disable_stop(get_logger(get_protocol_checker(monitor)), error);

   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));
   wait_until_idle(net, as_sync(source));
   wait_until_idle(net, as_sync(monitor));

   get_check_count(net, monitor, eth_fcs, count);
   check_equal(count, 1);
   reset_log_count(get_logger(get_protocol_checker(monitor)), error);

By default the first error stops the simulation, like any VUnit check failure. To test that an error
happens, let errors through on that logger, count them, then reset the log count. An error you don't
count still fails the test at ``test_runner_cleanup``.

Turn a check off
----------------

.. code-block:: vhdl
   :caption: Turn off the gap check

   set_check_enabled(net, monitor, eth_ifg, false);

``get_check_count`` counts the violations a check found while it was enabled. On a monitor, both
procedures pass through to its protocol checker. A monitor without one reports a failure. Both also
accept the protocol checker handle itself.

Related recipes
---------------

* :doc:`../cookbook/sources`: *Send a malformed frame*
* :doc:`../cookbook/monitors`: *Turn a check off*

API reference
-------------

:vhdl:`ethernet_pkg.ethernet_check_t`, :vhdl:`ethernet_pkg.frame_options`,
:vhdl:`ethernet_pkg.set_check_enabled`, :vhdl:`ethernet_pkg.get_check_count`
