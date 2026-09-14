Python guide
============

The Python side of awesome-vunit-vcs owns the verification semantics: frames, checks, statistics,
captures and packets. It is used in two ways.

* **Standalone**, without a simulator: build frames, run recorded samples through the same monitor
  pipeline a VHDL monitor uses, and test your own checks and subscribers with plain ``pytest``.
* **Inside a simulation**, behind the VHDL components: every monitor and source has a Python
  backend object, and a testbench can extend it with Python code of its own.

Every example on this page is a file in the repository that the test suite runs, so the examples
match the code. The units are the same everywhere: times are integers in femtoseconds (``_fs``),
sizes are octets (``_octets``) and rates are bits per second (``_bps``).

.. contents:: On this page
   :local:
   :depth: 2

Standalone
----------

Building frames
~~~~~~~~~~~~~~~

A frame is described by its MAC octets: the destination address up to, not including, the FCS.
:class:`~awesome_vunit_vcs.ethernet.frame.MacFrame` interprets received octets, and
:func:`~awesome_vunit_vcs.ethernet.source.build_wire_frame` builds everything a transmitter puts on
the wire, including deliberate errors.

.. literalinclude:: ../examples/python/build_frames.py
   :language: python
   :lines: 5-

``build_wire_frame`` accepts traffic the standard forbids on purpose. The arguments are the same as
those of the VHDL ``send_ethernet_frame`` procedure, which calls it.

Monitoring samples
~~~~~~~~~~~~~~~~~~

:class:`~awesome_vunit_vcs.ethernet.monitor.EthernetMonitor` is the pipeline behind a VHDL
monitor. Sample words go through the PHY decoder of the interface
(:func:`~awesome_vunit_vcs.ethernet.phy.create_phy`) into
:class:`~awesome_vunit_vcs.ethernet.frame.EthernetFrame` objects, which are published once and
consumed by every subscriber::

    sample words -> PHY decoder -> frames -+-> ProtocolChecker   -> violations
                                           +-> PerformanceMonitor -> statistics
                                           +-> PcapNgWriter       -> .pcapng file
                                           '-> your subscribers

.. literalinclude:: ../examples/python/monitor_frames.py
   :language: python
   :lines: 5-

The pieces:

* ``monitor.frames``, ``monitor.idle_events`` and ``monitor.checker.violations`` are
  :class:`~awesome_vunit_vcs.common.events.Publisher` objects. ``subscribe`` returns a function that
  unsubscribes again. A subscriber that raises does not stop delivery to the others.
* ``monitor.checker`` is a :class:`~awesome_vunit_vcs.ethernet.checker.ProtocolChecker`. Checks are
  named by :class:`~awesome_vunit_vcs.ethernet.checker.CheckId` or by their string value
  (``"ETH_FCS"``), and each can be enabled, disabled and counted. Each
  :class:`~awesome_vunit_vcs.ethernet.checker.Violation` carries the check, a message with the
  details, the time and the frame index.
* ``monitor.statistics`` is a :class:`~awesome_vunit_vcs.ethernet.metrics.PerformanceMonitor`;
  ``snapshot()`` returns an :class:`~awesome_vunit_vcs.ethernet.metrics.EthernetStatistics` with
  counts, size and gap summaries, rates and utilization, and ``summary()`` formats it for a log.
* ``monitor.start_capture`` subscribes a :class:`~awesome_vunit_vcs.ethernet.pcap.PcapNgWriter`.
  :class:`~awesome_vunit_vcs.ethernet.pcap.CaptureOptions` selects whether the FCS and errored
  frames are written. The capture never contains the preamble or the SFD; timestamps are the time of
  the first octet after the SFD, in nanoseconds by default.

Sample words are the interface specific encoding the VHDL monitors record, described in
:mod:`awesome_vunit_vcs.ethernet.phy.common`. For GMII a word is the 8 data bits with valid in bit 8
and error in bit 9, which is also what ``GmiiPhy.encode`` produces.

Packets with Scapy
~~~~~~~~~~~~~~~~~~

Scapy is optional (``pip install awesome-vunit-vcs[scapy]``). It is not needed to monitor, check or
capture frames; it adds the protocol layers above Ethernet.
:mod:`awesome_vunit_vcs.ethernet.scapy_adapter` converts in both directions.

.. literalinclude:: ../examples/python/scapy_packets.py
   :language: python
   :lines: 5-

Inside a simulation
-------------------

The backend objects
~~~~~~~~~~~~~~~~~~~

Each VHDL monitor and source creates one backend object, the variable ``vc``, in a Python session of
its own. The session has the identity of the component (``get_id(monitor)``), so two instances
never share Python state:

* a monitor creates a :class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend`, which
  holds an :class:`~awesome_vunit_vcs.ethernet.monitor.EthernetMonitor` as ``vc.monitor``;
* a source creates a :class:`~awesome_vunit_vcs.ethernet.vunit_backend.SourceBackend`, which holds
  an :class:`~awesome_vunit_vcs.ethernet.source.EthernetSource` as ``vc.source``.

The VHDL procedures (``get_statistics``, ``expect_ethernet_frame``, ``start_capture`` and the
others) call these objects, so a normal testbench never writes Python. When a test needs more, it
reaches the backend through the Python bridge, in the session of the component.

Adding a subscriber
~~~~~~~~~~~~~~~~~~~

A Python file executed in the session of a monitor can subscribe to its frames. This file is
``examples/gmii/python/frame_sizes.py``:

.. literalinclude:: ../examples/gmii/python/frame_sizes.py
   :language: python
   :lines: 5-

The testbench executes it with ``exec_file`` from the Python bridge and reads the result back with
``eval``, from ``examples/gmii/tb_gmii_example.vhd``:

.. literalinclude:: ../examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: elsif run("test_python_subscriber") then
   :end-before: elsif run("test_scapy_packet") then
   :dedent: 8

``exec_file``, ``exec``, ``eval_integer`` and ``new_session`` come from
``context python_bridge.python_context``, the `vunit-python-bridge
<https://github.com/ru551n/vunit-python-bridge>`__ package. A test can equally call a method of the
backend, for example ``eval_integer("vc.frame_count()", new_session(get_id(monitor)))``.

Rules for Python in a simulation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* **Python never touches signals.** It sees what a VHDL component recorded (frames, events) and
  returns what the component should drive (symbols). Pin timing stays in VHDL.
* **Errors become VUnit failures.** A violation is logged as an error on the checker of the monitor.
  An exception raised by a subscriber, or while processing samples, is caught and logged as a
  failure on the logger of the component, with the exception type, message and location. It never
  ends the simulation with a Python traceback.
* **Work in the session of the component.** ``new_session(get_id(monitor))`` returns that session;
  ``vc`` exists there after the component has started, at the beginning of simulation.
* **Keep subscribers fast.** They run while the monitor processes a batch of samples.

The VHDL side of the bridge
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Verification components in this repository talk to their backends only through
``awesome_vunit_vcs.vcs_python_pkg``, which isolates the bridge API: ``new_vc_session``,
``create_backend``, ``backend_exec`` and ``backend_integer``/``_boolean``/``_string``, sample
batches (``new_sample_batch``, ``record_sample``, ``flush_samples``) and ``log_reports``. It is
meant for writing new components (see ``CONTRIBUTING.md``); testbenches use the component
procedures and, where needed, the bridge directly as shown above. The batch encoding on the Python
side is :mod:`awesome_vunit_vcs.common.vunit_bridge`, and the report queue the backends use to log
through VHDL is :mod:`awesome_vunit_vcs.common.reports`.
