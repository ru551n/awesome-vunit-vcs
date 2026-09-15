Python in a simulation
======================

A normal testbench never writes Python: the VHDL procedures do everything. Add Python code when a
check needs it, such as a reference model, or when a test needs generated traffic.

.. include:: ../_includes/vunit_names.inc

.. contents:: On this page
   :local:
   :depth: 1

Know the backend objects
------------------------

Each VHDL monitor, protocol checker and source has a :term:`backend` object called ``vc``. Each lives
in its own Python :term:`session`, so two components never share Python state.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Component
     - Backend class
   * - Monitor
     - :class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend`
   * - Protocol checker
     - :class:`~awesome_vunit_vcs.ethernet.vunit_backend.ProtocolCheckerBackend`
   * - Source
     - :class:`~awesome_vunit_vcs.ethernet.vunit_backend.SourceBackend`

In the session of a monitor, your code can use:

* ``@vc.on_frame``, to call a function with every
  :class:`~awesome_vunit_vcs.ethernet.api.Frame` the monitor receives from then on;
* ``vc.frames``, the most recent frames, and ``vc.statistics``;
* ``vc.error(check, message)``, to report a counted check error. A subscriber reports on ``"ETH_USER"``,
  the check that counts only errors reported from Python.

.. _python-monitors-in-simulation:

Add a subscriber to a monitor
-----------------------------

.. literalinclude:: ../../examples/gmii/python/frame_sizes.py
   :caption: examples/gmii/python/frame_sizes.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

This file runs in the session of a monitor. Annotate ``vc`` as
:class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend` to get type checking.

The testbench loads it with ``exec_file`` and reads the result back with ``eval``:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: elsif run("test_python_subscriber") then
   :end-before: elsif run("test_scapy_packet") then
   :dedent: 8

``exec_file``, ``exec``, ``eval_integer`` and ``new_session`` come from the Python bridge.
``ethernet_context`` already includes them, so an Ethernet testbench needs no extra context clause.

A subscriber reports problems in one of two ways:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - In the subscriber
     - Result in VUnit
   * - ``vc.error("ETH_USER", message)``
     - An error on the monitor's checker. ``get_check_count(net, monitor, eth_user, count)`` counts
       it, and ``set_check_enabled(net, monitor, eth_user, false)`` turns off only the errors your
       Python code reports. The scoreboard, ``ETH_SCOREBOARD``, is a separate check.
   * - An exception
     - A failure that stops the test. Use it for bugs in the subscriber itself.

The error is logged on the monitor's logger. *Check every received frame in Python* in
:doc:`../cookbook/python_traffic` counts one in a negative test.

Keep subscribers fast: they run while the monitor processes traffic. :doc:`monitors` shows how to
create the monitor in VHDL.

Send traffic from Python functions
----------------------------------

.. code-block:: vhdl
   :caption: Name a packet function and pass its arguments

   push_ethernet_packet(net, source, "my_packets:udp_to_dut", kwarg("port", 1234) & kwarg("size", 128));

VHDL decides when a source sends, and your Python function decides what. Pass the arguments as VHDL
values; see :ref:`passing-arguments`.

A :term:`packet function` returns a :class:`~awesome_vunit_vcs.ethernet.api.Frame`, the frame data,
or a Scapy packet. A generator function yields many frames, for ``push_ethernet_sequence`` and
``check_ethernet_sequence``. Use a generator for long traffic; it is much faster than many single
pushes.

.. literalinclude:: ../../examples/python/packet_functions.py
   :caption: examples/python/packet_functions.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

:mod:`awesome_vunit_vcs.ethernet.traffic` lets Python code call the same functions:
:func:`~awesome_vunit_vcs.ethernet.traffic.call_packet_function`,
:func:`~awesome_vunit_vcs.ethernet.traffic.sequence` and the seeded generators.

Make traffic reproducible with VUnit's seed
-------------------------------------------

.. code-block:: vhdl
   :caption: Send and expect the same seeded sequence

   push_ethernet_sequence(net, source, "my_traffic:mixed", kwarg("count", 1000),
                          seed => get_string_seed(runner_cfg, "tx"));
   check_ethernet_sequence(net, monitor, "my_traffic:mixed", kwarg("count", 1000),
                           seed => get_string_seed(runner_cfg, "tx"));

.. code-block:: python
   :caption: my_traffic.py

   from awesome_vunit_vcs.ethernet import traffic

   def mixed(count, seed):
       rng = traffic.rng_from(seed)  # the same seed gives the same frames
       for _ in range(count):
           yield traffic.random_frame(rng, max_payload_octets=200)

:func:`~awesome_vunit_vcs.ethernet.traffic.rng_from` and
:func:`~awesome_vunit_vcs.ethernet.traffic.random_frame` come with the package; ``random_frame`` returns
a random valid frame. The same function, arguments and seed give the same frames. The monitor then expects exactly what the
source sent, and a failing run repeats with the seed VUnit printed. Rerun a test with VUnit's
``--seed`` option.

The seeded generators use the same :data:`~awesome_vunit_vcs.ethernet.limits.LIMITS` as your
Hypothesis strategies.

Related recipes
---------------

* :doc:`../cookbook/python_traffic`: *Check every received frame in Python*

API reference
-------------

:class:`~awesome_vunit_vcs.ethernet.vunit_backend.MonitorBackend`,
:mod:`awesome_vunit_vcs.ethernet.traffic`, and everything else in :doc:`python_api`
