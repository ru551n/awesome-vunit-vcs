Packets and sequences from Python
=================================

You can build the frames to send in three ways. Pick the simplest one that fits your test.

.. list-table::
   :header-rows: 1
   :widths: 25 40 35

   * - Layer
     - Use it for
     - Procedure
   * - Frame data in VHDL
     - Simple and directed tests
     - ``push_ethernet_frame``
   * - A packet function
     - Protocol packets, for example with Scapy
     - ``push_ethernet_packet``
   * - A sequence generator
     - Long, randomized, reproducible traffic
     - ``push_ethernet_sequence``, ``check_ethernet_sequence``

Send frame data from VHDL
-------------------------

.. code-block:: vhdl
   :caption: Frames built in the testbench

   push_ethernet_frame(net, source, frame);
   push_ethernet_frame(net, source, destination, source_address, ethertype, payload);
   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad, ifg_octets => 8));

``frame_options`` has a default for every setting of a standard frame: ``fcs``, ``pad``,
``preamble_octets``, ``sfd``, ``ifg_octets`` and ``error_offsets``. :doc:`checks` shows what each one
triggers.

Send packets from a Python function
-----------------------------------

A :term:`packet function` is a plain Python function that returns a frame. It can return an
``awesome_vunit_vcs.ethernet.Frame``, the frame data, or a Scapy packet.

.. literalinclude:: ../../examples/gmii/python/packets.py
   :caption: examples/gmii/python/packets.py
   :language: python
   :start-after: from scapy.all import

.. code-block:: vhdl
   :caption: Send the packet from the testbench

   push_ethernet_packet(net, source, "packets:udp_packet", kwarg("dport", 1234));

* Name the function as ``"module:function"``. Install its module, or put its directory on
  ``PYTHONPATH``.
* Pass its arguments after the name; see :ref:`passing-arguments`. Leave them out when the function
  takes none.
* ``frame_options`` applies to the returned frame as for ``push_ethernet_frame``.

Send and expect a sequence
--------------------------

A sequence function is a generator of frames. Use it for long traffic: it is much faster than many
single pushes.

.. code-block:: python
   :caption: my_packets.py

   import random

   from awesome_vunit_vcs import ethernet as eth


   def my_traffic(count: int, seed: str):
       rng = random.Random(seed)
       for _ in range(count):
           yield eth.Frame.from_payload(rng.randbytes(rng.randint(46, 1500)))

.. code-block:: vhdl
   :caption: Expect and send the same sequence

   check_ethernet_sequence(net, monitor, "my_packets:my_traffic", kwarg("count", 100),
                           seed => get_string_seed(runner_cfg));
   push_ethernet_sequence(net, source, "my_packets:my_traffic", kwarg("count", 100),
                          seed => get_string_seed(runner_cfg));

* A function with a ``seed`` parameter gets the ``seed`` of the call. The same function, arguments and
  seed give the same frames, so the source and the monitor agree, and a failing seed repeats the test.
* ``get_string_seed(runner_cfg)`` is VUnit's seed of the test, logged with every run.
* ``count => 0`` sends until the generator is exhausted.

Use ready-made random traffic
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``awesome_vunit_vcs.ethernet.traffic:random_traffic`` generates valid frames, and optionally malformed
ones. The monitor expects the violations the malformed frames cause.

.. code-block:: vhdl
   :caption: Random traffic with 10 % malformed frames

   push_ethernet_sequence(
     net, source, "awesome_vunit_vcs.ethernet.traffic:random_traffic",
     kwarg("count", 100) & kwarg("malformations", "bad_fcs,runt") & kwarg("malformed_fraction", 0.1),
     seed => get_string_seed(runner_cfg)
   );

Your own generators can yield ``TrafficItem`` values too. Their bad FCS, short preambles, errors and
gaps are sent as given.

Push frames through the stream interface
----------------------------------------

A source is also a VUnit stream master. ``push_stream(net, as_stream(source), octet, last)`` pushes the
frame data one octet at a time, and ``last`` sends the frame with the default options.

Octets pushed without ``last`` when ``wait_until_idle`` arrives are a check failure.

Related recipes
---------------

* :doc:`../cookbook/sources`: *Send a packet built in Python*, *Send a reproducible random sequence*
* :doc:`../cookbook/python_and_vhdl`: *Call your own Python function*, *Generate traffic in Python with
  VUnit's seed*

API reference
-------------

:vhdl:`ethernet_pkg.push_ethernet_frame`, :vhdl:`ethernet_pkg.frame_options`,
:vhdl:`ethernet_pkg.push_ethernet_packet`, :vhdl:`ethernet_pkg.push_ethernet_sequence`,
:vhdl:`ethernet_pkg.check_ethernet_sequence`
