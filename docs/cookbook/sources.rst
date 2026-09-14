Sending frames
==============

The recipes on this page are test cases of :repo-file:`examples/cookbook/tb_cookbook.vhd`. Run one by
its name:

.. code-block:: console

   $ python examples/cookbook/run.py "*send_and_check_a_frame"

Send a frame
------------

**Goal:** transmit a frame and check that it arrives unchanged.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: send-frame
   :end-before: -- docs-end: send-frame
   :dedent:

**When to use this:** for most directed tests: you know the frame and expect it out of the DUT.

* Give the frame from the destination address up to, not including, the FCS; the source adds the rest.
* Tell the monitor what to expect before sending, with ``blocking => false``.
* End with ``wait_until_idle`` so the test doesn't finish before the frame is checked.

**Full example:** ``test_send_and_check_a_frame``

**See also:** :doc:`../ethernet/scoreboard`, :doc:`../getting_started/quickstart`

Send a frame from its header fields
-----------------------------------

**Goal:** give the addresses, the EtherType and the payload separately.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: header-fields
   :end-before: -- docs-end: header-fields
   :dedent:

**When to use this:** when a test varies one header field, such as the destination address.

* Addresses are 48 bits and the EtherType is 16 bits.

**Full example:** ``test_send_header_fields``

**See also:** :doc:`../ethernet/packets_and_sequences`

Send a malformed frame
----------------------

**Goal:** send a deliberate error, such as a bad FCS, and count the error it causes.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: malformed-frame
   :end-before: -- docs-end: malformed-frame
   :dedent:

**When to use this:** in negative tests, to show that the DUT or the checks catch bad traffic.

* ``frame_options`` takes only what you change: ``fcs``, ``pad``, ``preamble_octets``, ``sfd``,
  ``ifg_octets`` or ``error_offsets``.
* ``disable_stop`` lets the test count the error instead of stopping.
* Reset the log count after checking it; an uncounted error still fails the test.

**Full example:** ``test_count_a_malformed_frame``

**See also:** :doc:`../ethernet/checks`, :doc:`../ethernet/packets_and_sequences`

Send a packet built in Python
-----------------------------

**Goal:** let a Python function decide what to send, for example an IP packet.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: packet
   :end-before: -- docs-end: packet
   :dedent:

The function lives in an ordinary Python file:

.. literalinclude:: ../../examples/cookbook/python/cookbook_traffic.py
   :caption: examples/cookbook/python/cookbook_traffic.py
   :language: python
   :start-after: # docs-start: packet-function
   :end-before: # docs-end: packet-function

**When to use this:** when the frame content is easier to build in Python, such as IP, UDP or VLAN
headers, or packets made with Scapy.

* Name the function ``"module:function"``, and put its directory on the Python path in ``run.py``.
* Return a ``Frame``, the frame octets or a Scapy packet.

**Full example:** ``test_send_a_packet_from_python``

**See also:** :doc:`../ethernet/packets_and_sequences`, :doc:`../ethernet/python`

Send a reproducible random sequence
-----------------------------------

**Goal:** send many random frames that are the same every time the test runs with the same seed.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: sequence
   :end-before: -- docs-end: sequence
   :dedent:

.. literalinclude:: ../../examples/cookbook/python/cookbook_traffic.py
   :caption: examples/cookbook/python/cookbook_traffic.py
   :language: python
   :start-after: # docs-start: sequence-function
   :end-before: # docs-end: sequence-function

**When to use this:** for long or random traffic, where listing every frame in VHDL is impractical.

* Pass VUnit's seed, ``get_string_seed(runner_cfg)``; VUnit prints it, so a failure can be replayed.
* Give the monitor the same function and seed, and it expects exactly what is sent.

**Full example:** ``test_send_a_seeded_sequence``

**See also:** :doc:`../ethernet/packets_and_sequences`

Reset a source
--------------

**Goal:** abort what a source is doing and start clean.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: reset
   :end-before: -- docs-end: reset
   :dedent:

**When to use this:** after the DUT locks up or is reset in the middle of traffic, for example
between the examples of a property-based test.

* Reset the monitor and its protocol checker too, so they forget the aborted frame.
* ``reset`` works even while the clock is stopped.

**Full example:** ``test_reset_a_source``

**See also:** :doc:`../ethernet/monitors`
