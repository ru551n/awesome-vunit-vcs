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

   push_ethernet_packet(net, source, "packets:udp_packet", kwarg("dport", 1234));

* The function is named ``"module:function"`` and imported in the simulator's Python environment; put its
  directory on ``sys.path`` or install it.
* Its arguments follow the name, see :ref:`passing-arguments`. Leave them out when the function takes none.
* ``frame_options`` applies to the returned frame as for ``push_ethernet_frame``.

.. _passing-arguments:

Passing arguments to Python
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Arguments are VHDL values, combined with ``&``. The function receives them as Python values.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Write
     - When
   * - ``kwarg("size", 128)``
     - A named argument: integer, real, boolean, a short name such as ``"udp"``, or an
       ``integer_vector``
   * - ``arg(1234)``
     - A positional argument, before any named ones
   * - ``kwarg_text("note", msg)``
     - Any text, such as a message or a file name, that may contain quotes or backslashes
   * - ``kwarg_time("delay", 10 ns)``
     - A simulation time; the function gets femtoseconds

.. code-block:: vhdl

   push_ethernet_packet(
     net, source, "my_packets:udp_to_dut",
     kwarg("port", 1234) & kwarg("size", 128) & kwarg_text("label", "first ""burst""")
   );

``kwarg_text`` and ``kwarg_time`` values reach the function as character codes and ``[high, low]``;
decode them with ``decode_text`` and ``decode_time_fs`` from ``awesome_vunit_vcs.common.vunit_bridge``.

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

   check_ethernet_sequence(net, monitor, "my_packets:my_traffic", kwarg("count", 100), seed => get_string_seed(runner_cfg));
   push_ethernet_sequence(net, source, "my_packets:my_traffic", kwarg("count", 100), seed => get_string_seed(runner_cfg));

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
     kwarg("count", 100) & kwarg("malformations", "bad_fcs,runt") & kwarg("malformed_fraction", 0.1),
     seed => get_string_seed(runner_cfg)
   );

Items of a sequence may carry wire options (``TrafficItem``), so malformed traffic from Python keeps its bad
FCS, short preamble, errors and gaps.

Stream interface
----------------

A source is also a VUnit stream master: ``push_stream(net, as_stream(source), octet, last)`` pushes the frame
data an octet at a time, and ``last`` sends the frame with the default options. Octets pushed without
``last`` when ``wait_until_idle`` arrives are a check failure.
