Python guide
============

The Python side of awesome-vunit-vcs owns the verification semantics: frames, checks, statistics,
captures and packets. It is used in two ways.

* **Standalone**, without a simulator: build frames and malformed traffic, run samples through the
  same pipeline a VHDL monitor uses, and test your own checks with ``pytest`` and Hypothesis.
* **Inside a simulation**, behind the VHDL components: every monitor and source has a Python
  backend object, and a testbench extends it with Python code of its own.

Everything a test needs is one import:

.. code-block:: python

   from awesome_vunit_vcs import ethernet as eth

Every example on this page is a file in the repository that the test suite runs. Times are integers
in femtoseconds, sizes are octets and rates are bits per second; ``eth.fs("8 ns")`` and
``eth.bps("2.5G")`` convert readable strings. Every invalid argument raises
:class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`.

.. contents:: On this page
   :local:
   :depth: 2

Standalone
----------

Frames and malformed traffic
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A :class:`~awesome_vunit_vcs.ethernet.api.Frame` is the octets from the destination address up to
and including the FCS. It is the only frame type: you build one with ``Frame.from_payload``,
``Frame.from_bytes`` or ``Frame.from_packet``, and monitors return received frames, which also carry
their time and the violations found on them. Frames are immutable values that compare and hash by
content, so a received frame equals the frame that was sent.

``frame.to_wire()`` builds what a transmitter puts on the wire. Deliberate errors are data: a
:class:`~awesome_vunit_vcs.ethernet.api.WireOptions` value describes the FCS, padding, preamble,
SFD, error signal and gap, and :func:`~awesome_vunit_vcs.ethernet.api.expected_violations` names
the checks a monitor reports for it.

.. literalinclude:: ../examples/python/build_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Error offsets always count from the first octet after the SFD; negative offsets reach into the SFD
and the preamble. The VHDL ``frame_options`` use the same convention.

Decoding samples on any interface
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

An :class:`~awesome_vunit_vcs.ethernet.interfaces.Interface` is a value too: ``eth.GMII``,
``eth.MII``, ``eth.XGMII(lanes=8, rate="100G")`` and ``with_rate`` for other rates.
``interface.encode(frames)`` returns the :class:`~awesome_vunit_vcs.ethernet.interfaces.Samples` a
VHDL monitor records (sample words and their times), and
:func:`~awesome_vunit_vcs.ethernet.api.decode` runs them through the monitor pipeline.

.. literalinclude:: ../examples/python/decode_samples.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

The round trip is exact: a frame sent with default options is received padded to the minimum frame
size, ``frame.padded()``.

Checks and statistics
~~~~~~~~~~~~~~~~~~~~~

A :class:`~awesome_vunit_vcs.ethernet.api.Monitor` keeps its state across calls: feed it samples or
frames, and it returns the frames completed, collects every
:class:`~awesome_vunit_vcs.ethernet.checker.Violation` and keeps
:class:`~awesome_vunit_vcs.ethernet.metrics.Statistics`. Use it as a context manager, so a frame
still in progress is reported and captures are closed at the end.

.. literalinclude:: ../examples/python/check_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Checks are named like the VHDL check literals, in upper case: ``"ETH_FCS"``, ``"ETH_IFG"`` and so
on. ``Monitor(interface, checks=["ETH_FCS"])`` runs only some, ``checks=False`` none.

Subscribers
~~~~~~~~~~~

A subscriber is a function a monitor calls as it finds things, so a test can react while traffic is
fed instead of inspecting ``rx.frames`` and ``rx.violations`` afterwards.

.. literalinclude:: ../examples/python/monitor_subscribers.py
   :language: python
   :start-after: # docs-start: subscribers
   :end-before: # docs-end: subscribers

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Subscriber
     - Called with
   * - ``rx.on_frame``
     - Every :class:`~awesome_vunit_vcs.ethernet.api.Frame` received from now on: ``data``, ``payload``,
       ``dst``, ``src``, ``ethertype``, ``fcs_ok``, ``ok``, ``index``, ``timestamp_fs`` and the
       ``violations`` found on it.
   * - ``rx.on_violation``
     - Every :class:`~awesome_vunit_vcs.ethernet.checker.Violation` from now on: ``check``, ``message``,
       ``timestamp_fs`` and ``frame_index``. A frame's violations come before the frame.

* Both work as decorators and as plain calls, and return the function unchanged.
* Only what is fed after subscribing is delivered, so subscribe before ``feed``.
* Subscribers run in the order they subscribed. If one raises, the others still run, then the
  exception propagates out of ``feed`` or ``feed_frames``.

Captures
~~~~~~~~

:func:`~awesome_vunit_vcs.ethernet.api.write_pcapng` writes frames to a PCAPNG file Wireshark reads,
and ``Monitor.capture`` writes what a monitor receives. A capture never contains the preamble or the
SFD; timestamps are those of the first octet after the SFD, in nanoseconds by default.

.. literalinclude:: ../examples/python/capture_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Packets with Scapy
~~~~~~~~~~~~~~~~~~

Scapy is optional (``pip install awesome-vunit-vcs[scapy]``). It is not needed to monitor, check or
capture frames; it adds the protocol layers above Ethernet.

.. literalinclude:: ../examples/python/scapy_packets.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Property-based testing
----------------------

awesome-vunit-vcs does not depend on `Hypothesis <https://hypothesis.readthedocs.io>`__, but its API
is shaped for it:

* **Typed constructors with keyword arguments.** ``st.builds(eth.Frame.from_payload, ...)`` and
  ``st.builds(eth.WireOptions, ...)`` work as they are.
* **One exception.** An invalid combination raises
  :class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`, which a strategy can avoid or a
  test can reject with ``assume``.
* **The parameter space is public data.** :data:`~awesome_vunit_vcs.ethernet.limits.LIMITS` bounds
  addresses, EtherTypes, payloads, preambles, gaps, lane counts and rates, and
  :class:`~awesome_vunit_vcs.ethernet.limits.Malformation` names the deliberate errors.
* **Oracles and round trips are pure functions.** ``decode(i, i.encode([frame])).frames ==
  (frame.padded(),)`` holds on every interface, and ``expected_violations`` computes what the
  checker must report for generated malformations. :func:`~awesome_vunit_vcs.ethernet.api.supported_malformations`
  lists the malformations it predicts exactly on an interface.

Strategies are then a few lines each:

.. literalinclude:: ../examples/python/property_based.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

The repository's own property tests, in ``tests/python/test_properties.py``, go further: sequences
of frames with generated malformation parameters on every interface, statistics invariants and a
PCAPNG round trip. Its ``conftest.py`` registers a derandomized ``ci`` profile, so CI runs are
reproducible, and a ``dev`` profile that explores more (``HYPOTHESIS_PROFILE=dev``).

Inside a simulation
-------------------

The backend objects
~~~~~~~~~~~~~~~~~~~

Each VHDL monitor, protocol checker and source creates one backend object, the variable ``vc``, in
a Python session of its own (``new_session(get_id(monitor))``), so two instances never share Python
state:

* a monitor creates a :class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend`;
* a protocol checker creates a :class:`~awesome_vunit_vcs.ethernet.vunit_backend.ProtocolCheckerBackend`;
* a source creates a :class:`~awesome_vunit_vcs.ethernet.vunit_backend.SourceBackend`.

The VHDL procedures call these objects, so a normal testbench never writes Python. When a test needs
more, Python code executed in the session of a monitor uses its backend directly:

* ``vc.on_frame(subscriber)``, also a decorator (``@vc.on_frame``), calls the subscriber with every
  :class:`~awesome_vunit_vcs.ethernet.api.Frame` the monitor receives from then on;
* ``vc.frames`` is the most recent frames and ``vc.statistics`` the statistics;
* ``vc.error(check, message)`` reports a finding as a counted check error, which
  ``get_check_count`` counts and ``set_check_enabled`` disables. A VHDL monitor runs the scoreboard
  check and leaves the protocol checks to its protocol checker, so a subscriber in the session of a
  monitor reports on ``"ETH_SCOREBOARD"``.

.. _python-monitors-in-simulation:

Adding a subscriber
~~~~~~~~~~~~~~~~~~~

A subscriber in a simulation reports what it finds in one of two ways:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - In the subscriber
     - Result in VUnit
   * - ``vc.error("ETH_SCOREBOARD", message)``
     - An error on the monitor's checker. It is counted by ``get_check_count`` and dropped while
       ``set_check_enabled`` disables the check, so negative tests can count it.
   * - An exception
     - A failure on the monitor's logger naming the subscriber, which stops the test. Use it for bugs
       in the subscriber itself.

Annotate ``vc`` as :class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend` to get type
checking in the subscriber module, as below. See :doc:`ethernet/monitors` for creating the monitor in
VHDL.

This file, ``examples/gmii/python/frame_sizes.py``, runs in the session of a monitor:

.. literalinclude:: ../examples/gmii/python/frame_sizes.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

The testbench executes it with ``exec_file`` from the Python bridge and reads the result back with
``eval``, from ``examples/gmii/tb_gmii_example.vhd``:

.. literalinclude:: ../examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: elsif run("test_python_subscriber") then
   :end-before: elsif run("test_scapy_packet") then
   :dedent: 8

``exec_file``, ``exec``, ``eval_integer`` and ``new_session`` come from
``context python_bridge.python_context``, the `vunit-python-bridge
<https://github.com/ru551n/vunit-python-bridge>`__ package.

Traffic from Python functions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Python decides *what* a source sends and VHDL *when*. Simple frames come straight from VHDL
(``push_ethernet_frame``); richer ones come from a Python function the testbench names, with its
keyword arguments as a string. The arguments are parsed as Python literals and never evaluated.

.. code-block:: vhdl

   push_ethernet_packet(net, source, "my_packets:udp_to_dut", "port=1234, size=128");

A packet function returns a :class:`~awesome_vunit_vcs.ethernet.api.Frame`, the frame octets
without FCS, or a Scapy packet. A generator function yields many, for
``push_ethernet_sequence`` and ``check_ethernet_sequence``; the frames are fetched in batches, so a
long sequence costs few bridge calls. :mod:`awesome_vunit_vcs.ethernet.traffic` holds the same
machinery for Python code: :func:`~awesome_vunit_vcs.ethernet.traffic.call_packet_function`,
:func:`~awesome_vunit_vcs.ethernet.traffic.sequence` and the seeded generators.

.. literalinclude:: ../examples/python/packet_functions.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Reproducible traffic from VUnit's seed
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

VUnit gives every test run a base seed through ``runner_cfg``, and ``get_seed(runner_cfg, salt)``
derives seeds from it (``vunit/vhdl/run/src/run_api.vhd``; the string form is 16 hexadecimal
digits). Pass it to a sequence, and the source hands it to the function as its ``seed`` argument:

.. code-block:: vhdl

   push_ethernet_sequence(net, source, "my_traffic:mixed", "count=1000",
                          seed => get_string_seed(runner_cfg, "tx"));
   check_ethernet_sequence(net, monitor, "my_traffic:mixed", "count=1000",
                           seed => get_string_seed(runner_cfg, "tx"));

.. code-block:: python

   from awesome_vunit_vcs.ethernet import traffic

   def mixed(count, seed):
       rng = traffic.rng_from(seed)  # the same seed gives the same frames
       for _ in range(count):
           yield traffic.random_frame(rng, max_payload_octets=200)

The same function, arguments and seed produce the same frames, so the monitor side expects exactly
what the source sent, and a failing run repeats with the seed VUnit printed. VUnit's
``--seed`` option reruns a test with a given base seed.

The seeded generators in :mod:`awesome_vunit_vcs.ethernet.traffic` draw from the same
:data:`~awesome_vunit_vcs.ethernet.limits.LIMITS` a Hypothesis strategy builds on: one definition
of the parameter space, with Hypothesis in tests and :mod:`random` in simulations. Generation
inside a simulation deliberately does not use Hypothesis: its public API draws examples only inside
``@given`` tests, and ``strategy.example()`` is documented as unsuitable for anything but
interactive exploration.

Rules for Python in a simulation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* **Python never touches signals.** It sees what a VHDL component recorded (frames, events) and
  returns what the component should drive (symbols). Pin timing stays in VHDL.
* **Errors become VUnit failures.** A violation is logged as an error on the checker of the
  component. An exception raised by a subscriber, or while processing samples, is caught and logged
  as a failure on the logger of the component; it never ends the simulation with a Python traceback.
* **Keep subscribers fast.** They run while the monitor processes a batch of samples.

The VHDL side of the bridge
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Verification components in this repository talk to their backends only through
``awesome_vunit_vcs.vcs_python_pkg``, which isolates the bridge API. It is meant for writing new
components (see :doc:`contributing/index`); testbenches use the component procedures and, where
needed, the bridge directly as shown above. The batch encoding on the Python side is
:mod:`awesome_vunit_vcs.common.vunit_bridge`, and the report queue the backends log through is
:mod:`awesome_vunit_vcs.common.reports`.
