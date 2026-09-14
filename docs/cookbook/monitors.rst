Checking and receiving frames
=============================

The recipes on this page are test cases of :repo-file:`examples/cookbook/tb_cookbook.vhd` unless they
say otherwise. :doc:`../ethernet/monitors` explains monitors in full.

Wait for one frame to be checked
--------------------------------

**Goal:** block until the next frame has been received and compared.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: blocking-check
   :end-before: -- docs-end: blocking-check
   :dedent:

**When to use this:** when the test must not continue before a frame has arrived, for example before
changing the DUT's configuration.

* Queue many expectations with ``blocking => false`` instead when the order is all that matters.

**Full example:** ``test_blocking_check``

**See also:** :doc:`../ethernet/scoreboard`

Turn a check off
----------------

**Goal:** stop one protocol check.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: disable-check
   :end-before: -- docs-end: disable-check
   :dedent:

**When to use this:** when a test sends traffic that breaks a rule on purpose and you don't want to
count it.

* :doc:`../ethernet/checks` lists every check name.
* To assert that an error happened, count it instead; see :doc:`sources`, *Send a malformed frame*

**Full example:** ``test_disable_a_check``

**See also:** :doc:`../ethernet/checks`

Get the frames a monitor received
---------------------------------

**Goal:** read a received frame into a variable.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: pop-frame
   :end-before: -- docs-end: pop-frame
   :dedent:

**When to use this:** when you check a frame your own way, for example only some fields of it.

* Make the variable long enough for the largest frame; ``length`` says how much is used.
* ``fcs_ok`` is false when the frame arrived with a bad FCS.

**Full example:** ``test_pop_received_frames``

**See also:** :doc:`../ethernet/monitors`

Get every frame as a message
----------------------------

**Goal:** receive each frame a monitor reconstructs in a process of your own.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: subscribe
   :end-before: -- docs-end: subscribe
   :dedent:

**When to use this:** when a separate process, such as your own scoreboard, handles every frame.

* The subscriber is an ordinary VUnit ``com`` actor.
* ``pop_ethernet_frame(msg, ...)`` reads the frame out of the message.

**Full example:** ``test_subscribe_to_frames``

**See also:** :doc:`../ethernet/monitors`

Get statistics
--------------

**Goal:** check frame counts, sizes and gaps, and print a summary.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: statistics
   :end-before: -- docs-end: statistics
   :dedent:

**When to use this:** to check totals at the end of a test, or to log a summary while debugging.

* Fields include ``total_frames``, ``good_frames`` and ``payload_octets``.

**Full example:** ``test_statistics``

**See also:** :doc:`../ethernet/statistics`

Capture traffic for Wireshark
-----------------------------

**Goal:** write what a monitor receives to a PCAPNG file.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: capture
   :end-before: -- docs-end: capture
   :dedent:

**When to use this:** when you want to look at the traffic, or decode higher protocols, in Wireshark.

* Write into ``output_path(runner_cfg)`` so parallel tests don't overwrite each other's files.

**Good to know:** long tests produce large captures; capture only the tests you debug.

**Full example:** ``test_capture_to_pcapng``; the file is in the test's directory under
``vunit_out/test_output``.

**See also:** :doc:`../ethernet/captures`

Run Python on every received frame
----------------------------------

**Goal:** attach a Python subscriber to a monitor inside a simulation.

**When to use this:** when checking a frame needs Python, such as a reference model or packet decoding.

The recipe is in :doc:`../ethernet/monitors` and :doc:`../ethernet/python`, based on
:repo-file:`examples/gmii/python/frame_sizes.py` and the ``test_python_subscriber`` test case of
:repo-file:`examples/gmii/tb_gmii_example.vhd`.

.. code-block:: console

   $ python examples/gmii/run.py "*test_python_subscriber"

Put monitors on both sides of a DUT
-----------------------------------

**Goal:** check that frames leave the DUT as they entered it.

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitors
   :end-before: -- docs-end: monitors
   :dedent:

**When to use this:** when you verify a DUT that forwards or transforms traffic.

* Give each monitor an ``id`` so the log says which side found a problem.
* Each monitor can have its own protocol checker limits.

**Full example:** :repo-file:`examples/gmii/tb_gmii_example.vhd`

.. code-block:: console

   $ python examples/gmii/run.py

**See also:** :doc:`../ethernet/monitors`
