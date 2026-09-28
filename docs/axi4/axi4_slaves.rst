AXI4 read and write slaves
==========================

The :vhdl:`axi4_read_slave` and :vhdl:`axi4_write_slave` components answer an AXI4 master from an
:doc:`axi4_memory`. They have the features of VUnit's ``axi_read_slave`` and ``axi_write_slave``, plus
WRAP bursts, a sparse 64-bit address space and error responses.

.. include:: ../_includes/vunit_names.inc

Overview
--------

A read slave accepts bursts on the read address channel and returns their data on the read data
channel; a write slave accepts bursts on the write address channel, takes their data and gives a write
response. Both check the permissions of every byte and, for writes, its expected value. Bursts wait in
an address FIFO, write responses in a write response FIFO, and each channel stalls with a probability
you set. The response latency is the time from the AR handshake to the first read data, and from the
last write data to the write response; a write slave writes the data to the memory right before its
response.

The slaves drive the handshakes and the timing. Which bytes each beat moves, whether the permissions
allow it, and what to respond is decided in Python, once per burst.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`axi4_read_slave`, :vhdl:`axi4_write_slave`
   * - Protocols
     - AXI4 (8-bit AxLEN) and AXI3 (4-bit AxLEN); AXI4-Lite with AxLEN tied to 0
   * - Widths
     - Data 8 to 1024 bits, address up to 64 bits, ID 0 to 31 bits
   * - Bursts
     - FIXED, INCR and WRAP, narrow and unaligned, up to 256 beats
   * - Clocking
     - Samples and drives at the rising edges of ACLK
   * - Tested on
     - GHDL, NVC

Pins
----

.. list-table::
   :header-rows: 1
   :widths: 35 35 30

   * - Ports
     - Type
     - Default when open
   * - ``aclk``
     - ``std_ulogic``
     - Must be connected
   * - ``aresetn``
     - ``std_ulogic``
     - ``'1'``. At ``'0'`` the slave drops its bursts and deasserts its VALID and READY.
   * - ``arvalid``, ``rready`` (read); ``awvalid``, ``wvalid``, ``bready`` (write)
     - ``std_ulogic`` inputs
     - Must be connected
   * - ``arready``, ``rvalid``, ``rlast`` (read); ``awready``, ``wready``, ``bvalid`` (write)
     - ``std_ulogic`` outputs
     -
   * - ``arid``, ``awid``
     - ``std_ulogic_vector(id_length - 1 downto 0)``
     - 0
   * - ``rid``, ``bid``
     - ``std_ulogic_vector(id_length - 1 downto 0)`` outputs
     -
   * - ``araddr``, ``awaddr``
     - ``std_ulogic_vector(address_length - 1 downto 0)``
     - Must be connected
   * - ``arlen``, ``awlen``
     - ``std_ulogic_vector`` of 8 (AXI4) or 4 (AXI3) bits
     - Must be connected
   * - ``arsize``, ``awsize``
     - ``std_ulogic_vector(2 downto 0)``
     - The full data width
   * - ``arburst``, ``awburst``
     - ``std_ulogic_vector(1 downto 0)``
     - ``"01"``, INCR
   * - ``rdata`` (output), ``wdata``
     - ``std_ulogic_vector(data_length - 1 downto 0)``
     - ``wdata`` must be connected
   * - ``wstrb``
     - ``std_ulogic_vector(data_length / 8 - 1 downto 0)``
     - All ones
   * - ``wlast``
     - ``std_ulogic``
     - ``'1'``
   * - ``rresp``, ``bresp``
     - ``std_ulogic_vector(1 downto 0)`` outputs
     -

The widths come from the bus of the handle, which is the only generic: ``axi_slave : axi4_slave_t``,
named like VUnit's. The ports are ``std_ulogic``, which ``std_logic`` signals connect to directly.

Constructor parameters
----------------------

Each slave entity needs a handle of its own; the two handles may share a memory (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: slaves
   :end-before: -- docs-end: slaves
   :dedent:

:vhdl:`new_axi4_slave <axi4_slave_pkg.new_axi4_slave>` takes:

.. list-table::
   :header-rows: 1
   :widths: 30 17 13 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``memory``
     - ``axi4_memory_t``
     - Required
     - The memory the slave reads or writes
   * - ``axi4_bus``
     - ``axi4_bus_t``
     - 32-bit data and addresses, no IDs
     - The widths, from :vhdl:`new_axi4_bus <axi4_pkg.new_axi4_bus>`
   * - ``address_fifo_depth``
     - ``positive``
     - ``1``
     - Bursts accepted and waiting for their data
   * - ``write_response_fifo_depth``
     - ``positive``
     - ``1``
     - Write responses waiting for BREADY
   * - ``check_4kbyte_boundary``
     - ``boolean``
     - ``true``
     - An INCR burst crossing a 4 KB boundary is a check failure
   * - ``address_stall_probability``, ``data_stall_probability``, ``write_response_stall_probability``
     - ``probability_t``
     - ``0.0``
     - The probability, each cycle, that AxREADY, RVALID or WREADY, and BVALID stay 0
   * - ``min_response_latency``, ``max_response_latency``
     - ``delay_length``
     - ``0 ns``
     - The response latency, uniform in this range
   * - ``drive_invalid``, ``drive_invalid_val``
     - ``boolean``, ``std_ulogic``
     - ``true``, ``'X'``
     - Drive this value on the R and B payload while VALID is 0, and on the RDATA lanes a beat does not
       use
   * - ``seed``
     - ``natural``
     - ``0``
     - Seeds the stalls and latencies
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     - The standard VC parameters
     - Derived
     - ``id`` defaults to ``awesome_vunit_vcs:axi4_slave:<n>``

Connect the slaves like VUnit's (VHDL). Here to the AXI4-Lite master of VUnit:

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: instances
   :end-before: -- docs-end: instances
   :dedent:

Procedures
----------

The procedures of VUnit's ``axi_slave_pkg``, for an ``axi4_slave_t``. All block until the slave has
handled them.

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Procedure
     - What it does
   * - ``set_address_fifo_depth``, ``set_write_response_fifo_depth``
     - A depth smaller than what the FIFO holds is a check failure and changes nothing
   * - ``set_address_stall_probability``, ``set_data_stall_probability``,
       ``set_write_response_stall_probability``
     - The stall probabilities
   * - ``set_response_latency(net, slave, latency)``, ``set_response_latency(net, slave, min, max)``
     - The response latency
   * - ``enable_4kbyte_boundary_check``, ``disable_4kbyte_boundary_check``
     - The 4 KB check
   * - ``get_statistics(net, slave, stat, clear)``
     - The bursts of each length, as VUnit's ``axi_statistics_t``
   * - ``enable_well_behaved_check``
     - Check that bursts are compact on the data channel, as VUnit's slaves do
   * - ``reset``
     - Drop the bursts and responses queued or in progress
   * - ``wait_until_idle``, ``wait_for_time`` on ``as_sync(slave)``
     - Idle is no burst queued or in progress and no response waiting

A test that expects data checks it in the memory after the write response (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: expected
   :end-before: -- docs-end: expected
   :dedent:

Checks
------

Failures are check failures on the checker of the slave, so a negative test counts them with
``disable_stop`` and ``get_log_count`` (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: failure
   :end-before: -- docs-end: failure
   :dedent:

.. list-table::
   :header-rows: 1
   :widths: 35 45 20

   * - Failure
     - Message
     - Response
   * - A byte the permission forbids
     - ``Reading from address ... without permission (no_access)``
     - SLVERR for that beat or write
   * - An expected byte written with another value
     - ``Writing to address ... Got 0 expected 77``
     - OKAY; the byte is written
   * - An INCR burst crossing 4 KB
     - ``Crossing 4KByte boundary. First page = 0 (4000/4096), last page = 1 (4255/4096)``
     - OKAY
   * - AxBURST ``"11"``, a beat wider than the bus, a WRAP burst of an illegal length or alignment
     - ``Unsupported burst type 0b11 (reserved) of read burst #0 for id 2``, and so on
     - SLVERR, no data moved
   * - WLAST on the wrong beat
     - ``Expected wlast='1' on last beat of burst #0 for id 2 with length 1 starting at address 0``
     - OKAY
   * - A metavalue on AxID, AxADDR, AxLEN, AxSIZE or AxBURST, or in a strobed WDATA byte
     - ``Metavalue in WDATA lane 1 of beat 0 of write burst #0 for id 0, written as 0``
     - OKAY
   * - Not well behaved, once enabled
     - ``Burst not well behaved, rready was not high during active burst``, and VUnit's other messages
     - OKAY

The rules of the protocol itself are for an :doc:`axi4_protocol_checker` on the same pins.

Statistics notes
----------------

``get_statistics`` returns VUnit's ``axi_statistics_t``: ``num_bursts``, ``min_burst_length``,
``max_burst_length`` and ``get_num_burst_with_length``. A burst counts at its address handshake. Deallocate
the result:

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: statistics
   :end-before: -- docs-end: statistics
   :dedent:

For latencies, bandwidth and backpressure put an :doc:`axi4_monitor` on the pins.

Python backend
--------------

The slaves attach to the :py:class:`~awesome_vunit_vcs.axi4.vunit_backend.Axi4MemoryBackend` of their
memory, which gives each an :py:class:`~awesome_vunit_vcs.axi4.slave.Axi4Slave`. A read slave makes
one bridge call per burst, at its AR handshake, which returns the RRESP and the lanes of every beat. A
write slave makes two: at its AW handshake, and right before its write response with the data and
strobes of every beat.

Migrating from VUnit's slaves
-----------------------------

Replace the types, constructors and entities; the procedures keep their names:

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - VUnit
     - This package
   * - ``memory_t``, ``new_memory``, ``buffer_t``
     - ``axi4_memory_t``, ``new_axi4_memory``, ``axi4_buffer_t``
   * - ``new_axi_slave(memory, ...)``
     - ``new_axi4_slave(memory, axi4_bus, ...)``, one handle per entity
   * - ``axi_read_slave``, ``axi_write_slave``
     - ``axi4_read_slave``, ``axi4_write_slave``

The exact differences:

* **Handle and generics.** The handle is the only generic; ``drive_invalid`` and ``drive_invalid_val``
  are constructor parameters. The widths come from ``axi4_bus``, so ARID, ARADDR, WDATA and the others
  must have its widths. ``new_axi4_slave`` also takes ``seed`` and the standard ``id``, ``logger``,
  ``actor``, ``checker`` and ``unexpected_msg_type_policy``.
* **Ports.** ``std_ulogic`` instead of ``std_logic``; ``aresetn`` is new; ARID, AxSIZE, AxBURST, WSTRB
  and WLAST may be left open.
* **Failures.** Check failures on the checker of the slave at level ``error``, not ``failure`` on
  ``axi_slave_logger``; tests that mock ``axi_slave_logger`` mock ``get_logger(slave)`` at ``error``.
  One message per burst and rule, where VUnit gives one per byte.
* **Responses.** A byte without permission, or an unsupported burst, gives SLVERR; VUnit's slaves always
  respond OKAY.
* **Bursts.** WRAP bursts are supported, and beats after the first of an unaligned INCR burst start at
  the aligned address, as the specification says; VUnit's slaves fail on WRAP and step the unaligned
  address. The 4 KB check applies to INCR bursts only, from the address aligned to the size.
* **Timing of the checks.** A read slave checks and reads the whole burst at its AR handshake, where
  VUnit reads each beat when it drives it. A write slave checks the data right before its write
  response, where VUnit checks each beat as it arrives. The data a read returns is the memory at its AR
  handshake.
* **Memory.** Permissions of unallocated bytes are ``default_permissions`` (``read_and_write`` unless
  set), and there is no "empty memory": the address space is the 64-bit space, or ``size_bytes``.
* **Extras.** ``reset``, ``wait_until_idle`` and ``wait_for_time``, ``aresetn``, AXI3 read slaves,
  metavalue reports, and statistics that ``clear``.

.. note::

   * Read data is taken from the memory at the AR handshake, so a write that completes between the AR
     handshake and the read data is not seen.
   * Exclusive accesses, AxLOCK, AxCACHE, AxPROT, AxQOS, AxREGION and the USER signals are not modelled;
     an exclusive access gets OKAY.
   * Each burst costs one or two bridge calls, several times the cost of VUnit's slaves in simulation
     time on the host.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#axi4-read-and-write-slaves-1>`__.
