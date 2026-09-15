Testing error handling
======================

A test that only sends good frames proves half of what we want to know. A real link delivers bad FCSs,
short preambles and truncated frames, and the design has to cope with them. In this article we send a
broken frame on purpose and check that it is noticed, without that expected error failing the test.
We start with a single bad FCS and build up from there.

We continue with the GMII testbench from :doc:`first_test`: a :term:`source`, a register stage and a
:term:`monitor` with the default :term:`protocol checker`. Everything in this article is VHDL, in the
testbench file ``examples/cookbook/tb_cookbook.vhd``. No Python code is needed.

Step 1: send a frame with a bad FCS
-----------------------------------

``frame_options`` describes what to break. The smallest negative test sends one frame with a wrong
:term:`FCS` and counts the error it causes:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: malformed-frame
   :end-before: -- docs-end: malformed-frame
   :dedent:

Let's walk through it line by line:

#. A detected error normally stops a VUnit test. ``disable_stop`` tells the protocol checker's logger to
   count errors instead, so the test keeps going.
#. ``push_ethernet_frame`` sends the frame with ``fcs => fcs_bad``.
#. ``get_check_count`` asks how many FCS errors were found, and the test expects exactly one.
#. ``reset_log_count`` forgives the error we expected. VUnit fails a test at cleanup if its log still
   has errors, so any error we didn't expect still fails the test.

With ``-v`` you can see the error being reported:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/cookbook/run.py -v "*test_count_a_malformed_frame"
   596000000 fs - awesome_vunit_vcs:gmii_monitor:1:protocol_checker - ERROR - ETH_FCS: bad FCS on frame 0
                                                                              expected=0x7B01ADA8
                                                                              received=0x84FE5257
                                                                              SFD time=76000000 fs
                                                                              length=64 octets
   pass lib.tb_cookbook.test_count_a_malformed_frame (0.2 s)

The error comes from ``gmii_monitor:1:protocol_checker``. The protocol checker is named after its
monitor, so the log shows where a problem was found.

Step 2: count an error the monitor finds
----------------------------------------

The protocol checker isn't the only one reporting errors. The monitor itself reports a frame that
doesn't match the one the test expected (``eth_scoreboard``), and errors your Python code reports with
``vc.error`` (see :doc:`python_traffic`). The monitor logs those, so count them on the monitor's logger:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: mismatched-frame
   :end-before: -- docs-end: mismatched-frame
   :dedent:

The expected frame ends with ``x"00"`` where the sent one has ``x"FF"``, so the monitor reports one
mismatch. Compared with step 1, only the logger changes:

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Error
     - Logger for ``disable_stop`` and ``reset_log_count``
   * - A protocol check, such as ``eth_fcs``, ``eth_ifg`` or ``eth_runt``
     - ``get_logger(get_protocol_checker(monitor))``
   * - ``eth_scoreboard`` or ``eth_user``: a mismatch, or an error reported from Python
     - ``get_logger(monitor)``

``get_check_count(net, monitor, check, count)`` counts both kinds.

Step 3: choose what to break
----------------------------

A bad FCS is one option. ``frame_options`` takes only what you change; everything you leave out keeps a
valid default:

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Option
     - What it changes
   * - ``fcs``
     - ``fcs_bad`` sends a wrong FCS, ``fcs_none`` leaves it out.
   * - ``pad``
     - ``false`` sends short frames without padding them to the minimum size.
   * - ``preamble_octets``
     - The number of preamble octets, for a preamble that is too short or too long.
   * - ``sfd``
     - The value sent as the SFD.
   * - ``ifg_octets``
     - The gap before the frame, for an :term:`IFG` that is too short.
   * - ``error_offsets``
     - Octets, counted from the first octet after the SFD, sent with the PHY error signal set.

To test a different error, change the option in step 1 and the check you count. :doc:`../ethernet/checks`
lists which check reports each kind of error.

Step 4: turn a check off
------------------------

Sometimes a test breaks a rule on purpose but has no interest in it, for example while testing
something unrelated. Then switch the check off instead of counting:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: disable-check
   :end-before: -- docs-end: disable-check
   :dedent:

When the error *is* the point of the test, count it as in steps 1 and 2. A disabled check can't tell you the
error happened.

Step 5: set your own limits
---------------------------

The default protocol checker uses the limits of standard Ethernet. When your design allows something
else, such as VLAN-tagged frames of 1522 octets, create a protocol checker with those limits:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitors
   :end-before: -- docs-end: monitors
   :dedent:

A limit of zero switches that rule off.

Going further: recover when the design gets stuck
-------------------------------------------------

Broken traffic can leave a design, and the components around it, in the middle of a frame. ``reset``
brings a component back to a clean state:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: reset
   :end-before: -- docs-end: reset
   :dedent:

A long frame is cut off halfway. The source stops sending, and the monitor and its protocol checker
forget the half frame, so the next frame is checked as if nothing happened. Reset all three together.
``reset`` returns even when the clock has stopped, so it also works after a design that hangs.

Where to go next
----------------

* :doc:`../ethernet/checks` lists every check and what triggers it.
* :doc:`beyond_gmii` runs these tests on other interfaces.
* :doc:`property_errors` lets Hypothesis find the inputs that break a design, including ones that lock
  it up.
