Packets and sequences from Python
=================================

Frames to send can be built in three layers. Python always computes preamble, SFD, padding, FCS and
errors; VHDL always decides when the pins change.

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

Frame data in VHDL
------------------

.. code-block:: vhdl

   push_ethernet_frame(net, source, frame);
   push_ethernet_frame(net, source, destination, source_address, ethertype, payload);
   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad, ifg_octets => 8));

``frame_options`` takes named parameters with defaults for a standard frame: ``fcs``, ``pad``,
``preamble_octets``, ``sfd``, ``ifg_octets`` and ``error_offsets``. See :doc:`checks` for what each one
triggers.

Packet functions
----------------

A packet function is a plain Python function that returns a frame: an ``awesome_vunit_vcs.ethernet.Frame``,
the frame data as Python octets, or any object Python can convert to octets, such as a Scapy packet.

.. literalinclude:: ../../examples/gmii/python/packets.py
   :language: python
   :start-after: from scapy.all import

.. code-block:: vhdl

   push_ethernet_packet(net, source, "packets:udp_packet", "dport=1234");

* The function is named ``"module:function"`` and imported in the simulator's Python environment; put its
  directory on ``sys.path`` or install it.
* The arguments are Python keyword arguments as a string. They are parsed as literals and never evaluated,
  so ``"dport=1234, size=128"`` works and code does not.
* ``frame_options`` applies to the returned frame as for ``push_ethernet_frame``.

Sequences
---------

A sequence function is a generator, or any function returning an iterable, of frames. A source fetches
them in batches, so there is no bridge call per frame.

.. code-block:: python

   import random

   from awesome_vunit_vcs import ethernet as eth


   def my_traffic(count: int, seed: str):
       rng = random.Random(seed)
       for _ in range(count):
           yield eth.Frame.from_payload(rng.randbytes(rng.randint(46, 1500)))

.. code-block:: vhdl

   check_ethernet_sequence(net, monitor, "my_packets:my_traffic", "count=100", seed => get_string_seed(runner_cfg));
   push_ethernet_sequence(net, source, "my_packets:my_traffic", "count=100", seed => get_string_seed(runner_cfg));

* A function with a ``seed`` parameter gets the ``seed`` of the call. The same function, arguments and seed
  give the same frames, so the source and the monitor agree, and a failing seed reproduces the test.
* ``get_string_seed(runner_cfg)`` is VUnit's seed of the test, logged with every run.
* ``count => 0`` sends until the generator is exhausted.

Ready-made random traffic
~~~~~~~~~~~~~~~~~~~~~~~~~

``awesome_vunit_vcs.ethernet.traffic:random_traffic`` generates valid frames, and optionally malformed ones
whose expected violations the monitor accounts for:

.. code-block:: vhdl

   push_ethernet_sequence(
     net, source, "awesome_vunit_vcs.ethernet.traffic:random_traffic",
     "count=100, malformations=('bad_fcs', 'runt'), malformed_fraction=0.1",
     seed => get_string_seed(runner_cfg)
   );

Items of a sequence may carry wire options (``TrafficItem``), so malformed traffic from Python keeps its bad
FCS, short preamble, errors and gaps.

Stream interface
----------------

A source is also a VUnit stream master: ``push_stream(net, as_stream(source), octet, last)`` pushes the frame
data an octet at a time, and ``last`` sends the frame with the default options. Octets pushed without
``last`` when ``wait_until_idle`` arrives are a check failure.
