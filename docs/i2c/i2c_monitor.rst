I2C monitor
===========

The :vhdl:`i2c_monitor` component observes an I2C bus and reconstructs its transfers. It never drives
the bus.

.. include:: ../_includes/vunit_names.inc

Overview
--------

The monitor records every change of SCL and SDA with its time. Its Python backend finds START, repeated
START and STOP conditions, the address with its R/W bit, 10-bit addresses and the reserved addresses
such as the general call, and every data byte with its acknowledge bit. The monitor publishes each
transfer to its subscribers, keeps the last 1024 for pops, compares them with the transfers a test
expects, and counts statistics. With a protocol checker in its handle it also instantiates an
:doc:`i2c_protocol_checker` on its pins.

A *transfer* starts with a START or a repeated START and ends at the next repeated START or STOP; a
write followed by a read after a repeated START is two transfers.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`i2c_monitor`
   * - Speed modes
     - Any; the monitor samples on every change of SCL or SDA
   * - Addressing
     - 7-bit, 10-bit, general call, START byte, CBUS, Hs-mode controller codes, device ID and the other
       reserved addresses
   * - Tested on
     - GHDL, NVC

Pins
----

.. list-table::
   :header-rows: 1
   :widths: 15 15 25 45

   * - Port
     - Direction
     - Type
     - Signal
   * - ``scl``
     - in
     - ``std_ulogic``
     - SCL, read with ``to_x01``
   * - ``sda``
     - in
     - ``std_ulogic``
     - SDA, read with ``to_x01``

The :term:`handle` is the only generic: ``monitor : i2c_monitor_t``.

Constructor parameters
----------------------

:vhdl:`i2c_monitor_pkg.new_i2c_monitor`:

.. list-table::
   :header-rows: 1
   :widths: 20 25 20 35

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``protocol_checker``
     - ``i2c_protocol_checker_t``
     - ``null_i2c_protocol_checker``
     - A protocol checker the monitor instantiates on its pins
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
   * - :vhdl:`pop_i2c_transfer <i2c_monitor_pkg.pop_i2c_transfer>`,
       :vhdl:`await_pop_i2c_transfer_reply <i2c_monitor_pkg.await_pop_i2c_transfer_reply>`
     - The oldest transfer the monitor keeps, or the next one to come, as an
       :vhdl:`i2c_transfer_t <i2c_monitor_pkg.i2c_transfer_t>`. Deallocate its ``data``.
   * - :vhdl:`check_i2c_transfer <i2c_monitor_pkg.check_i2c_transfer>`
     - The next transfer must have this address, direction and data. A difference, or an expected
       transfer that never came when the test ends, is ``I2C_SCOREBOARD``.
   * - :vhdl:`get_i2c_statistics <i2c_monitor_pkg.get_i2c_statistics>`,
       :vhdl:`await_get_i2c_statistics_reply <i2c_monitor_pkg.await_get_i2c_statistics_reply>`
     - The :vhdl:`i2c_statistics_t <i2c_monitor_pkg.i2c_statistics_t>` of the bus
   * - ``reset``
     - See the family page

A monitor publishes every transfer as an ``i2c_transfer_msg`` to the actors that
``subscribe`` to it; read it with :vhdl:`pop_i2c_transfer(msg, transfer) <i2c_monitor_pkg.pop_i2c_transfer>`.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: monitor
   :end-before: -- docs-end: monitor
   :dedent:

``i2c_transfer_t`` has the fields ``address`` (-1 when the bus carried no complete address),
``is_read``, ``ten_bit``, ``repeated_start``, ``stopped`` (false when a repeated START ended it),
``address_ack``, ``nack_index`` (the first data byte not acknowledged, -1 for none; the last byte of a
read is normally not acknowledged), ``start_time`` and ``data``.

Checks
------

The monitor runs ``I2C_SCOREBOARD``. Without a protocol checker it also reports a metavalue on SCL or
SDA, ``I2C_METAVALUE``, as a check failure on its checker; with one it leaves that to the protocol
checker, so it is reported once. The other checks are those of the :doc:`i2c_protocol_checker`.

Statistics
----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Field
     - Meaning
   * - ``transactions``, ``transfers``
     - Transactions started (START to STOP) and transfers completed
   * - ``reads``, ``writes``, ``repeated_starts``
     - Transfers by R/W bit, and those that started with a repeated START
   * - ``data_bytes``
     - Data bytes, not counting address bytes
   * - ``nacks``, ``address_nacks``
     - Bytes not acknowledged, address bytes included, and transfers whose address was not acknowledged
   * - ``metavalues``
     - Samples with a metavalue on SCL or SDA
   * - ``scl_frequency_hz``, ``max_scl_frequency_hz``
     - 1 / the median and 1 / the shortest time between rising SCL edges inside transactions
   * - ``busy_time``, ``utilization_ppm``
     - Time inside transactions, and its share of the time since the monitor started, in parts per
       million
   * - ``stretch_time``
     - An estimate of clock stretching: SCL low periods longer than 1.5 times their median add the time
       beyond the median

Python backend
--------------

The monitor creates an :py:class:`~awesome_vunit_vcs.i2c.vunit_backend.I2cMonitorBackend`, which runs
an :py:class:`~awesome_vunit_vcs.i2c.monitor.I2cMonitor`. Subscribe to ``vc.monitor.transfers`` in the
session of the monitor to extend it from Python. The sample word has SCL in bit 0 and SDA in bit 1,
with bits 2 and 3 set for a metavalue on SCL and SDA; the monitor records one whenever a line changes,
and sends them to Python at every STOP and before it handles a message.

.. note::

   * The monitor cannot tell who holds SCL low, so ``stretch_time`` is an estimate.
   * A byte followed by a START or STOP instead of an acknowledge bit is taken with the SCL edge of the
     condition as its acknowledge bit; the protocol checker reports it as ``I2C_ACK_SLOT``.
   * High-speed mode and Ultra Fast-mode are not decoded.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#i2c-monitor>`__.
