AXI4
====

The AXI4 family observes and answers AXI4 and AXI4-Lite memory-mapped interfaces, following the AMBA
AXI specification (ARM IHI 0022). Two of its verification components (:term:`VCs <VC>`) are strictly
passive: they never drive a signal, so they sit next to any master and slave, your design or VUnit's own
AXI verification components. The read and write slaves answer a master from a sparse memory.

.. include:: ../_includes/vunit_names.inc

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - VC
     - Role
   * - :vhdl:`axi4_monitor`
     - Reconstructs the transactions of the five channels per ID, for checks, pops, subscribers, a
       shadow memory scoreboard and performance statistics.
   * - :vhdl:`axi4_protocol_checker`
     - Checks the rules of the protocol: handshakes, burst types and lengths, the 4 KB boundary, WLAST
       and RLAST, write strobes, exclusive accesses, responses without a transaction, metavalues and
       timeouts.
   * - :vhdl:`axi4_read_slave`, :vhdl:`axi4_write_slave`
     - Answer a master from an ``axi4_memory_t``: VUnit's ``axi_read_slave`` and ``axi_write_slave``
       with WRAP bursts, a sparse 64-bit address space and error responses.

VUnit has AXI slaves (``axi_write_slave``, ``axi_read_slave``) and an AXI-Lite master
(``axi_lite_master``), but no monitor or protocol checker of AXI4 memory-mapped interfaces; this family
fills that gap, and has slaves of its own whose memory costs nothing until it is touched. The VHDL components only record what happens at every rising edge of ACLK. What the
records mean, from the address of every beat to latency percentiles, is decided by the Python package
``awesome_vunit_vcs.axi4``, which also works in plain ``pytest``.

What's here
-----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`axi4_monitor`, :doc:`axi4_protocol_checker`, :doc:`axi4_slaves`
     - One page per VC: pins, constructors, procedures, checks and statistics
   * - :doc:`axi4_memory`
     - The sparse memory of the slaves: buffers, permissions, expected data and images
   * - :doc:`python`
     - The burst arithmetic, monitor and protocol checker without a simulator
   * - :doc:`vhdl_api`
     - Every VHDL package, context and entity of the family
   * - :doc:`python_api`
     - Every public Python name of ``awesome_vunit_vcs.axi4``

.. _axi4-quick-start:

The pattern
-----------

A testbench needs one context clause, which also makes VUnit's verification components visible, its
AXI slaves and bus master included:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

``axi4_context`` makes ``axi4_pkg``, ``axi4_monitor_pkg``, ``axi4_protocol_checker_pkg``,
``axi4_memory_pkg`` and ``axi4_slave_pkg`` visible,
together with ``ieee.std_logic_1164``, ``ieee.numeric_std``, ``vunit_context``, ``com_context``,
VUnit's ``vc_context`` and the typed Python arguments of ``vc_python_pkg``.

Describe the interface with :vhdl:`new_axi4_bus <axi4_pkg.new_axi4_bus>` and create a monitor with a
handle in the architecture (VHDL). Here a 64-bit AXI4 interface with 4-bit IDs:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

Connect the monitor to the same signals as the master and the slave. Every port is an input:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: instances
   :end-before: -- docs-end: instances
   :dedent:

Signals the interface does not have can be left open; they take the default of the specification
(AxLEN 0, AxSIZE the full data width, AxBURST INCR, WSTRB all ones, WLAST and RLAST 1, the others 0).
A test then waits for transactions, checks them and reads the statistics:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: bursts
   :end-before: -- docs-end: bursts
   :dedent:

The run script (Python) adds VUnit's verification components, the bridge and the package:

.. literalinclude:: ../../examples/axi4/run.py
   :caption: examples/axi4/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

AXI4-Lite
---------

``new_axi4_bus(..., lite => true)`` describes an AXI4-Lite interface: every transaction is one beat of
the full data width with ID 0, and the monitor ignores the pins AXI4-Lite does not have. Here a monitor
on the AXI4-Lite interface between VUnit's ``axi_lite_master`` and its AXI slaves:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: lite-handles
   :end-before: -- docs-end: lite-handles
   :dedent:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: lite-instances
   :end-before: -- docs-end: lite-instances
   :dedent:

Handles and identity
--------------------

Constructors take the VC configuration first, then the standard VUnit parameters ``id``, ``logger``,
``actor``, ``checker`` and ``unexpected_msg_type_policy``, all with defaults. The logger, actor and
checker of a component derive from its id unless they are passed explicitly.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Constructed with
     - Id
   * - No ``id``
     - ``awesome_vunit_vcs:<vc>:<n>``, where ``<vc>`` is ``axi4_monitor``, ``axi4_protocol_checker``,
       ``axi4_slave`` or ``axi4_memory``, and ``<n>`` numbers the default ids from 1
   * - ``id => get_id("tb:monitor")``
     - ``tb:monitor``
   * - A protocol checker without an explicit ``id``, passed to ``new_axi4_monitor``
     - ``<monitor id>:protocol_checker``. The logger, actor and checker that were not passed
       explicitly are derived from this id, the checker uses up no default id, and it takes the bus of
       the monitor.

* Two VCs with the same id are a failure on the logger of the second:
  ``Two verification components have the id tb:monitor and would share one Python backend``.
* ``get_id``, ``get_logger``, ``get_actor`` and ``get_checker`` return them, and ``get_bus`` the
  :vhdl:`axi4_bus_t <axi4_pkg.axi4_bus_t>` that sizes the ports.
* A message a VC does not handle is a check failure ``Got unexpected message <name>`` on its checker
  unless ``unexpected_msg_type_policy`` is ``ignore``.

Standard interfaces
-------------------

Every VC has ``as_sync(vc)``, VUnit's sync interface: ``wait_until_idle`` returns when Python has
processed everything a monitor or checker recorded so far, or when a slave has no burst queued or in
progress, and ``wait_for_time`` delays the handling of the next message.

Procedures
----------

Every procedure takes ``net`` first. A procedure that returns nothing only sends a message, handled in
order. A procedure that returns a value blocks, and has a non-blocking form returning a reference,
read later with the matching ``await_`` procedure.

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Procedure
     - Page
   * - ``pop_axi4_transaction``, ``check_axi4_transaction``, ``get_axi4_statistics``,
       ``log_axi4_statistics``
     - :doc:`axi4_monitor`
   * - ``set_check_enabled``, ``get_check_count``
     - :doc:`axi4_protocol_checker`
   * - ``set_address_fifo_depth``, ``set_response_latency``, ``get_statistics`` and the others of VUnit's
       ``axi_slave_pkg``
     - :doc:`axi4_slaves`
   * - ``reset``
     - Below

Recover a component with ``reset(net, vc)``, for example after a reset of the design that the VCs did
not see on ARESETn:

.. list-table::
   :widths: 25 75

   * - Monitor
     - Forgets the outstanding transactions, the kept and the expected ones; cancels pending pops.
       Keeps the shadow memory, and the statistics unless ``clear_statistics => true``.
   * - Protocol checker
     - Sets its counts to 0 and forgets the history of the interface. Keeps its check switches.
   * - Read and write slaves
     - Drop the bursts and responses queued or in progress. Keep the configuration, the statistics
       and the memory.

The monitor and the protocol checker also forget the outstanding transactions when ARESETn falls; the
slaves drop their bursts while ARESETn is 0.

Every declaration is listed in the :doc:`vhdl_api`.

.. toctree::
   :maxdepth: 1
   :hidden:

   axi4_monitor
   axi4_protocol_checker
   axi4_slaves
   axi4_memory
   python
   vhdl_api
   python_api
