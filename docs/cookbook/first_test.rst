Your first Ethernet test
========================

Say you have a design that passes Ethernet frames through, and you want to know that every frame
comes out the way it went in. In this article we build that test from nothing. We start with the
smallest test that passes and add one idea at a time: first a frame and a check, then statistics and
a capture you can open in Wireshark. At the end, under *Going further*, we look at other ways to read
what a monitor received.

The design under test is as simple as it gets: one register stage on a GMII bus. That keeps the focus
on the testbench.

.. list-table:: Where the code in this article lives
   :header-rows: 1
   :widths: 30 20 50

   * - File
     - Language
     - What it holds
   * - ``run.py``
     - Python
     - The VUnit run script: which libraries and packages to compile.
   * - ``tb_cookbook.vhd``
     - VHDL
     - The testbench: signals, component handles, test cases and the design under test.

This article needs no Python code of your own. The run script is the only Python file.

Step 1: add the packages to the run script (Python)
---------------------------------------------------

A VUnit project starts with its run script, ``run.py``. Besides VUnit's own libraries, it adds two
packages by name: the Python bridge, which the components use internally, and awesome-vunit-vcs.

.. literalinclude:: ../../examples/quickstart/run.py
   :caption: examples/quickstart/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

There are no paths to installed VHDL files: VUnit finds both packages wherever they were installed.
Keep ``add_verification_components()`` and ``allow_setup=True``; the components need both.

Everything from here on is VHDL, in the testbench file.

Step 2: the testbench skeleton (VHDL)
-------------------------------------

One context clause at the top of the file brings in the components and everything from VUnit they
need:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

The architecture declares a clock and the signals on both sides of the design under test:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: signals
   :end-before: -- docs-end: signals
   :dedent:

Step 3: create a source and a monitor (VHDL)
--------------------------------------------

Every component is described by a :term:`handle`, a constant in the architecture. We need one for the
:term:`source` that drives the design's input and one for the :term:`monitor` that watches its output:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

The monitor gets ``default_gmii_protocol_checker``. The :term:`protocol checker` checks the traffic
against the Ethernet rules, such as a correct :term:`FCS`. A monitor without one rebuilds frames but
checks nothing, so always give it one.

The handles go to the entities, which we instantiate next to the design under test:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: instances
   :end-before: -- docs-end: instances
   :dedent:

Step 4: the test structure (VHDL)
---------------------------------

The main process follows VUnit's usual structure, with one ``run`` branch per test case so VUnit can
run and report each one on its own:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: test-structure
   :end-before: -- docs-end: test-structure
   :dedent:

The process declares the variables the test cases below use. You only need the ones for the steps you
use:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: variables
   :end-before: -- docs-end: variables
   :dedent:

We also add a small helper to the process. It waits until both components have finished their work:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: wait-helper
   :end-before: -- docs-end: wait-helper
   :dedent:

Step 5: send a frame and check it (VHDL)
----------------------------------------

Now the first real test. The frame is a constant: two addresses, an EtherType and a payload.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: frame
   :end-before: -- docs-end: frame
   :dedent:

The test tells the monitor which frame to expect, sends that frame and waits:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: send-frame
   :end-before: -- docs-end: send-frame
   :dedent:

A lot happens behind these three lines. The frame we give is the :term:`frame data`, from the
destination address to the end of the payload. The source adds the preamble, SFD, padding and FCS and
drives the pins. The monitor samples the design's output, rebuilds the frame and compares it with what
we queued. ``blocking => false`` queues the expectation and returns at once, which is why it comes
before the send. Without the final wait, the test could end before the frame reached the monitor.

Run it:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/cookbook/run.py "*test_send_and_check_a_frame"
   pass lib.tb_cookbook.test_send_and_check_a_frame (0.2 s)
   ==== Summary ========================================================
   pass lib.tb_cookbook.test_send_and_check_a_frame (0.2 s)
   =====================================================================
   pass 1 of 1
   All passed!

That's a complete, passing test. Each step below adds one idea to it.

Step 6: build the frame from its header fields (VHDL)
-----------------------------------------------------

Writing a frame as one long vector gets tedious when a test only changes one field. The same frame can
be given as its parts:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: header-fields
   :end-before: -- docs-end: header-fields
   :dedent:

The addresses are 48 bits and the EtherType 16 bits.

Step 7: check the statistics (VHDL)
-----------------------------------

At the end of a test we often want totals: how many frames, how many were good, how many octets. The
monitor keeps count and can write a summary to the log:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: statistics
   :end-before: -- docs-end: statistics
   :dedent:

Run the test with ``-v`` to see the summary in the log:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/cookbook/run.py -v "*test_statistics"
   1340000000 fs - awesome_vunit_vcs:gmii_monitor:1 - INFO - awesome_vunit_vcs:gmii_monitor:1 statistics
                   frames: total=2 good=2 bad=0
                   octets: wire=144 frame=128 payload=92
                   frame size: min=64 max=64 mean=64.0 octets
                   inter-frame gap: min=12 max=12 mean=12.0 octets
   pass lib.tb_cookbook.test_statistics (0.2 s)

The log names the monitor ``awesome_vunit_vcs:gmii_monitor:1`` because we didn't give it a name. Pass
``id => get_id("tb:rx")`` to the constructor when you want your own.

Step 8: capture the traffic for Wireshark (VHDL)
------------------------------------------------

When something looks odd, it helps to see the traffic. A monitor writes everything it receives to a
PCAPNG file:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: capture
   :end-before: -- docs-end: capture
   :dedent:

``output_path(runner_cfg)`` is the test's own output directory, so parallel tests never overwrite each
other's files. Look for ``frames.pcapng`` under ``vunit_out/test_output``. Captures of long tests get
large, so capture the tests you are debugging.

Everything together (VHDL)
--------------------------

Here is a complete testbench built from the steps above. It sends ten frames of growing size, checks
each one, captures the traffic and checks the statistics:

.. literalinclude:: ../../examples/quickstart/tb_quickstart.vhd
   :caption: examples/quickstart/tb_quickstart.vhd
   :language: vhdl
   :start-after: -- docs-start: testbench
   :end-before: -- docs-end: testbench

Going further
-------------

The steps above are all most tests need. These add other ways to use what a monitor receives.

Wait for a frame before moving on (VHDL)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Queued expectations are fine when only the order matters. When the test must not go on before a frame
has arrived, for example before it reconfigures the design, leave out ``blocking => false``:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: blocking-check
   :end-before: -- docs-end: blocking-check
   :dedent:

Read the received frame yourself (VHDL)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When a test cares about only some fields, take the frame and check it your own way:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: pop-frame
   :end-before: -- docs-end: pop-frame
   :dedent:

Make the variable long enough for the largest frame. ``length`` tells how much was filled, and
``fcs_ok`` is false for a frame that arrived with a bad FCS.

Get every frame in a process of your own (VHDL)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A monitor also publishes every frame as a VUnit message. Any VUnit actor can subscribe, which suits a
:term:`scoreboard` in a process of its own:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: subscribe
   :end-before: -- docs-end: subscribe
   :dedent:

The subscriber is an ordinary VUnit actor, declared in the architecture next to the handles as
``constant subscriber : actor_t := new_actor("tb_cookbook:subscriber");``. ``pop_ethernet_frame`` also
reads a frame out of the message it receives.

Put monitors on both sides of the design (VHDL)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A real design does more than a register stage. With a monitor on its input as well, the log tells you
whether a bad frame went in or came out. Give each monitor a name; each can have its own protocol
checker limits:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitors
   :end-before: -- docs-end: monitors
   :dedent:

Where to go next
----------------

* :doc:`error_handling` sends broken frames on purpose and checks that they are caught.
* :doc:`beyond_gmii` runs the same test on other interfaces.
* The full examples are :repo-file:`examples/cookbook/tb_cookbook.vhd` and
  :repo-file:`examples/quickstart/tb_quickstart.vhd`.
