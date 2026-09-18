AXI4 monitor
============

The :vhdl:`axi4_monitor` component observes an AXI4 or AXI4-Lite interface and reconstructs its
transactions. It never drives a signal.

.. include:: ../_includes/vunit_names.inc

Overview
--------

At every rising edge of ACLK the monitor records the channels whose VALID is 1 or changed. Its Python
backend puts the handshakes together into transactions, per ID: a write is an AW handshake, its
``AWLEN + 1`` write data beats, which may come before the address, and a B handshake; a read is an AR
handshake and its ``ARLEN + 1`` read data beats. Transactions with different IDs complete in any order,
and read data of different IDs may interleave. For every beat the monitor computes its address and byte
lanes from the burst type (FIXED, INCR or WRAP), the size and the alignment, so narrow and unaligned
transfers give the bytes they carry.

The monitor publishes each transaction to its subscribers, keeps the last 1024 for pops, compares them
with the transactions a test expects, checks reads against a shadow memory, and measures the
performance of the interface. With a protocol checker in its handle it also instantiates an
:doc:`axi4_protocol_checker` on its pins.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`axi4_monitor`
   * - Protocols
     - AXI4 and AXI4-Lite
   * - Widths
     - Data 8 to 1024 bits, address 1 to 64 bits, ID 0 to 31 bits, USER signals of any width
   * - Bursts
     - FIXED, INCR and WRAP, narrow and unaligned, up to 256 beats
   * - Clocking
     - Samples at the rising edges of ACLK; measures the clock period itself
   * - Tested on
     - GHDL, NVC

Pins
----

Every port is an input with a default, so a signal the interface does not have can be left open.

.. list-table::
   :header-rows: 1
   :widths: 30 25 45

   * - Ports
     - Type
     - Default when open
   * - ``aclk``
     - ``std_ulogic``
     - Must be connected
   * - ``aresetn``
     - ``std_ulogic``
     - ``'1'``
   * - ``awvalid``, ``awready``, ``wvalid``, ``wready``, ``bvalid``, ``bready``, ``arvalid``,
       ``arready``, ``rvalid``, ``rready``
     - ``std_ulogic``
     - ``'0'``
   * - ``awid``, ``bid``, ``arid``, ``rid``
     - ``std_ulogic_vector(id_length - 1 downto 0)``
     - 0
   * - ``awaddr``, ``araddr``
     - ``std_ulogic_vector(address_length - 1 downto 0)``
     - 0
   * - ``awlen``, ``arlen``
     - ``std_ulogic_vector(7 downto 0)``
     - 0, a single beat
   * - ``awsize``, ``arsize``
     - ``std_ulogic_vector(2 downto 0)``
     - The full data width
   * - ``awburst``, ``arburst``
     - ``std_ulogic_vector(1 downto 0)``
     - ``"01"``, INCR
   * - ``awlock``, ``arlock``
     - ``std_ulogic``
     - ``'0'``
   * - ``awcache``, ``arcache``, ``awqos``, ``arqos``, ``awregion``, ``arregion``
     - ``std_ulogic_vector(3 downto 0)``
     - 0
   * - ``awprot``, ``arprot``
     - ``std_ulogic_vector(2 downto 0)``
     - 0
   * - ``wdata``, ``rdata``
     - ``std_ulogic_vector(data_length - 1 downto 0)``
     - 0
   * - ``wstrb``
     - ``std_ulogic_vector(data_length / 8 - 1 downto 0)``
     - All ones
   * - ``wlast``, ``rlast``
     - ``std_ulogic``
     - ``'1'``
   * - ``bresp``, ``rresp``
     - ``std_ulogic_vector(1 downto 0)``
     - ``"00"``, OKAY
   * - ``awuser``, ``wuser``, ``buser``, ``aruser``, ``ruser``
     - ``std_ulogic_vector`` of the USER width of the bus
     - 0

The widths come from the bus of the handle: ``id_length(get_bus(monitor))`` and so on. The
:term:`handle` is the only generic: ``monitor : axi4_monitor_t``. The ports are ``std_ulogic``, which
signals of type ``std_logic``, such as those of VUnit's AXI components, connect to directly.

Constructor parameters
----------------------

:vhdl:`axi4_pkg.new_axi4_bus` describes the interface:

.. list-table::
   :header-rows: 1
   :widths: 25 15 15 45

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``data_length``
     - ``positive``
     - ``32``
     - WDATA and RDATA in bits, a power of 2 from 8 to 1024; 32 or 64 for AXI4-Lite
   * - ``address_length``
     - ``positive``
     - ``32``
     - AWADDR and ARADDR in bits, up to 64
   * - ``id_length``
     - ``natural``
     - ``0``
     - The ID signals in bits, up to 31; 0 without IDs
   * - ``awuser_length``, ``wuser_length``, ``buser_length``, ``aruser_length``, ``ruser_length``
     - ``natural``
     - ``0``
     - The USER signals in bits
   * - ``lite``
     - ``boolean``
     - ``false``
     - AXI4-Lite

:vhdl:`axi4_monitor_pkg.new_axi4_monitor`:

.. list-table::
   :header-rows: 1
   :widths: 20 25 25 30

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``axi4_bus``
     - ``axi4_bus_t``
     -
     - The widths of the interface
   * - ``protocol_checker``
     - ``axi4_protocol_checker_t``
     - ``null_axi4_protocol_checker``
     - A protocol checker the monitor instantiates on its pins
   * - ``shadow_memory``
     - ``boolean``
     - ``false``
     - Check every read against the data written before it
   * - ``per_id_statistics``
     - ``boolean``
     - ``false``
     - Also keep the statistics of each ID, for the summary
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - See the family page

Procedures
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`pop_axi4_transaction <axi4_monitor_pkg.pop_axi4_transaction>`,
       :vhdl:`await_pop_axi4_transaction_reply <axi4_monitor_pkg.await_pop_axi4_transaction_reply>`
     - The oldest transaction the monitor keeps, or the next one to complete, as an
       :vhdl:`axi4_transaction_t <axi4_monitor_pkg.axi4_transaction_t>`. Deallocate its ``data`` and
       ``strobe``.
   * - :vhdl:`check_axi4_transaction <axi4_monitor_pkg.check_axi4_transaction>`
     - The next write or read to complete must have this address and data, and optionally this ID and
       response. A difference, or an expected transaction that never came, is ``AXI4_SCOREBOARD``.
   * - :vhdl:`get_axi4_statistics <axi4_monitor_pkg.get_axi4_statistics>`,
       :vhdl:`await_get_axi4_statistics_reply <axi4_monitor_pkg.await_get_axi4_statistics_reply>`
     - The :vhdl:`axi4_statistics_t <axi4_monitor_pkg.axi4_statistics_t>` of the interface
   * - :vhdl:`log_axi4_statistics <axi4_monitor_pkg.log_axi4_statistics>`
     - Log the full statistics summary on the logger of the monitor, at ``info`` or another level
   * - ``reset``
     - See the family page

``check_axi4_transaction`` takes the bytes in the order of ``axi4_transaction_t.data``: the byte lanes
of every beat, in beat order, lowest lane first. For a full-width burst from an aligned address these
are simply the bytes from ``address`` on, so ``x"78563412"`` is the 32-bit word ``x"12345678"`` at
address 0x10:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: check-transaction
   :end-before: -- docs-end: check-transaction
   :dedent:

A pop returns the transaction with its phases:

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: pop
   :end-before: -- docs-end: pop
   :dedent:

``axi4_transaction_t`` has the fields ``is_write``, ``exclusive``, ``id``, ``address`` (64 bits),
``len``, ``size``, ``burst`` (one of VUnit's ``axi_burst_type_*``), ``cache``, ``prot``, ``qos``,
``region``, ``resp`` (compare with VUnit's ``axi_resp_*``), the times ``address_time``,
``first_data_time``, ``last_data_time`` and ``response_time``, and the byte arrays ``data`` and
``strobe``. A monitor publishes every transaction as an ``axi4_transaction_msg`` to the actors that
``subscribe`` to it; read it with :vhdl:`pop_axi4_transaction(msg, transaction)
<axi4_monitor_pkg.pop_axi4_transaction>`.

Checks
------

The monitor runs ``AXI4_SCOREBOARD``:

* a transaction that differs from the one :vhdl:`check_axi4_transaction
  <axi4_monitor_pkg.check_axi4_transaction>` expects, or an expected transaction that never came when
  the test ends;
* with ``shadow_memory``, a read that returns a byte the writes before it did not leave there.

The shadow memory takes a write at its B handshake, only the bytes WSTRB selects, and only when it
succeeded: OKAY for a normal write, EXOKAY for an exclusive one. A read with an OKAY or EXOKAY response
may return, for each byte, the value at its AR handshake or a value written while it was outstanding.
Bytes never written through the interface are not checked. A write that bypasses the interface is
caught (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: shadow-memory
   :end-before: -- docs-end: shadow-memory
   :dedent:

Without a protocol checker the monitor also reports a metavalue on VALID, READY, ARESETn or the payload
of a channel while VALID is 1, ``AXI4_METAVALUE``, as a check failure on its checker; with one it leaves
metavalues to the protocol checker, so each is reported once. The other checks are those of the
:doc:`axi4_protocol_checker`.

Statistics
----------

The statistics are independent of the protocol checker. Latencies are in clock cycles, between
handshakes.

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Field of ``axi4_statistics_t``
     - Meaning
   * - ``write_transactions``, ``read_transactions``
     - Transactions completed
   * - ``write_bytes``, ``read_bytes``
     - Bytes moved: the strobed bytes of writes, the byte lanes of reads
   * - ``write_bandwidth_mbps``, ``read_bandwidth_mbps``
     - Bytes * 8 over the time observed, in Mbit/s
   * - ``max_outstanding_writes``, ``max_outstanding_reads``
     - The most transactions outstanding at once, from the address handshake to the response
   * - ``min_write_latency``, ``max_write_latency``, ``mean_write_latency``
     - From the AW to the B handshake
   * - ``min_read_latency``, ``max_read_latency``, ``mean_read_latency``
     - From the AR handshake to the last read data beat
   * - ``aw_stall_cycles``, ``w_stall_cycles``, ``b_stall_cycles``, ``ar_stall_cycles``,
       ``r_stall_cycles``
     - Backpressure: cycles with VALID 1 and READY 0 on each channel
   * - ``error_responses``
     - SLVERR and DECERR responses
   * - ``cycles``
     - Clock cycles observed

:vhdl:`log_axi4_statistics <axi4_monitor_pkg.log_axi4_statistics>` logs everything else too: for each
direction the responses, the latency distributions (address to first data, address to last data,
address to response and last write data to response) with minimum, maximum, mean, the 50th, 90th and
99th percentiles and a histogram, the time weighted mean of the outstanding transactions, and the
histograms of burst lengths, sizes and types; for each channel its handshakes, utilization and
backpressure; and with ``per_id_statistics`` the same for each ID. The summary is only logged when a
test asks for it.

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: statistics
   :end-before: -- docs-end: statistics
   :dedent:

Python backend
--------------

The monitor creates an :py:class:`~awesome_vunit_vcs.axi4.vunit_backend.Axi4MonitorBackend`, which runs
an :py:class:`~awesome_vunit_vcs.axi4.monitor.Axi4Monitor`; its statistics come from an
:py:class:`~awesome_vunit_vcs.axi4.performance.Axi4PerformanceMonitor` and its scoreboard from a
:py:class:`~awesome_vunit_vcs.axi4.memory.ShadowMemory`. At every rising edge of ACLK it records a
header word and the payload words of each channel whose VALID is 1, changed, or is a metavalue, and a
control word when ARESETn or the clock period changes; the layout is in
:py:mod:`awesome_vunit_vcs.axi4.bus`. Idle cycles cost nothing. The records go to Python in batches: when
4096 words are waiting, before a message is handled, and at the end of every transaction while the
monitor has subscribers or waiting pops.

.. note::

   * Latencies and utilization count clock cycles from the measured clock period, so they assume a
     clock that does not stop or change its period.
   * A write takes effect in the shadow memory at its B handshake; a slave that lets a read see a write
     before sending its response can be reported by mistake.
   * The VHDL transaction record has no USER signals; Python subscribers see them.
   * AXI4 has no WID: write data belongs to the writes in the order of their addresses, so interleaved
     write data shows up as ``AXI4_WLAST`` and ``AXI4_WSTRB`` violations, not as a check of its own.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#axi4-monitor>`__.
