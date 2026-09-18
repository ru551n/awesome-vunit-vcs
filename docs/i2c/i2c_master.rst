I2C master
==========

The :vhdl:`i2c_master` component is a controller on an I2C bus. It writes, reads, writes and then
reads after a repeated START, and sends transfers written as operations for traffic a normal
controller would not send.

.. include:: ../_includes/vunit_names.inc

Overview
--------

Use the master to test a target design: a sensor, a memory, a register block with an I2C port. Its
Python backend turns a transfer into a list of operations, a START, a byte out, a byte in or a STOP,
and the component clocks them out bit by bit with the timing of its speed mode. It honours clock
stretching, synchronizes its clock with other masters on the bus and detects a lost arbitration. The
acknowledge bits and the bytes read go back to the caller.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`i2c_master`
   * - Speed modes
     - Standard-mode (100 kHz), Fast-mode (400 kHz), Fast-mode Plus (1 MHz), with every time
       replaceable
   * - Addressing
     - 7-bit and 10-bit
   * - Bus features
     - Clock stretching, clock synchronization, arbitration, SMBus PEC
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
     - inout
     - ``std_logic``
     - SCL, driven ``'0'`` or released ``'Z'``
   * - ``sda``
     - inout
     - ``std_logic``
     - SDA, driven ``'0'`` or released ``'Z'``

The lines are resolved ``std_logic`` because several components drive them; the testbench pulls them
up with ``'H'``. The master reads them with ``to_x01``, so ``'H'`` is a 1. A metavalue on SDA where the
master samples it is a check failure on its checker. The :term:`handle` is the only generic:
``master : i2c_master_t``.

Constructor parameters
----------------------

:vhdl:`i2c_master_pkg.new_i2c_master`:

.. list-table::
   :header-rows: 1
   :widths: 20 20 20 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``speed``
     - ``i2c_speed_t``
     - ``i2c_standard_mode``
     - ``i2c_standard_mode``, ``i2c_fast_mode`` or ``i2c_fast_mode_plus``
   * - ``t_low``, ``t_high``
     - ``delay_length``
     - ``0 ns``
     - SCL low and high period
   * - ``t_hd_dat``
     - ``delay_length``
     - ``0 ns``
     - From SCL falling to driving SDA
   * - ``t_su_sta``, ``t_hd_sta``
     - ``delay_length``
     - ``0 ns``
     - Setup of a repeated START, hold of a START
   * - ``t_su_sto``
     - ``delay_length``
     - ``0 ns``
     - Setup of a STOP
   * - ``t_buf``
     - ``delay_length``
     - ``0 ns``
     - Bus free time the master waits after a STOP before a START
   * - ``stretch_timeout``
     - ``delay_length``
     - ``25 ms``
     - How long the master waits for SCL to rise after releasing it
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - See :ref:`i2c-quick-start` and the family page

A time of 0 ns keeps the value of the speed mode:

.. list-table::
   :header-rows: 1
   :widths: 25 25 25 25

   * - Time
     - Standard-mode
     - Fast-mode
     - Fast-mode Plus
   * - ``t_low`` / ``t_high``
     - 5 us / 5 us
     - 1.3 us / 1.2 us
     - 500 ns / 500 ns
   * - ``t_hd_dat``
     - 1 us
     - 300 ns
     - 100 ns
   * - ``t_su_sta``, ``t_hd_sta``, ``t_su_sto``
     - 5 us
     - 700 ns
     - 300 ns
   * - ``t_buf``
     - 5 us
     - 1.3 us
     - 500 ns

With them the master runs at the highest SCL frequency of the mode and meets every minimum of the
specification. Make a time shorter to test how a target copes, or longer for a slow bus.

Procedures
----------

Data is a ``std_ulogic_vector`` of whole bytes, leftmost byte first, such as ``x"10CAFE"``. Addresses
are ``natural``: 7-bit, or 10-bit with ``ten_bit => true``.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`i2c_write <i2c_master_pkg.i2c_write>`
     - Writes the bytes. Without a status it does not block, and a byte that is not acknowledged is a
       check failure. With ``status`` it blocks and returns the status instead. ``pec => true``
       appends an SMBus PEC, ``stop => false`` releases the bus without a STOP, and empty data sends
       the address alone.
   * - :vhdl:`i2c_read <i2c_master_pkg.i2c_read>`, :vhdl:`await_i2c_read_reply <i2c_master_pkg.await_i2c_read_reply>`
     - Reads ``data'length / 8`` bytes, acknowledging all but the last. ``pec => true`` reads and
       checks one more byte as the PEC.
   * - :vhdl:`i2c_write_read <i2c_master_pkg.i2c_write_read>`
     - Writes, then reads after a repeated START, as a register read does.
   * - :vhdl:`i2c_transfer <i2c_master_pkg.i2c_transfer>`, :vhdl:`await_i2c_transfer_reply <i2c_master_pkg.await_i2c_transfer_reply>`
     - A transfer written as operations; returns an :vhdl:`i2c_result_t <i2c_master_pkg.i2c_result_t>`
       with the status, the bytes read and every acknowledge bit.
   * - ``reset``
     - See the family page.

A read or write-read without ``status`` blocks and treats a status other than ``i2c_ok`` as a check
failure. A byte that is not acknowledged ends a transfer with a STOP. The status is an
:vhdl:`i2c_status_t <i2c_pkg.i2c_status_t>`: ``i2c_ok``, ``i2c_address_nack``, ``i2c_data_nack``,
``i2c_arbitration_lost``, ``i2c_pec_error`` or ``i2c_scl_timeout``.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: eeprom
   :end-before: -- docs-end: eeprom
   :dedent:

Transfers written as operations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:vhdl:`i2c_master_pkg.i2c_transfer` takes the operations as a string, separated by spaces:

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Operation
     - Meaning
   * - ``S``
     - A START, or a repeated START inside a transaction
   * - ``P``
     - A STOP
   * - ``0xA0`` or ``160``
     - Write a byte and clock its acknowledge bit
   * - ``R``, ``RN``
     - Read a byte and acknowledge it, or not
   * - ``B101``
     - Write 1 to 8 bits, most significant first, without an acknowledge bit

A NACK does not end such a transfer, nothing is a check failure, and the result has every acknowledge
bit, 1 for ACK. Without a final ``P`` the master releases the bus without a STOP; its next START is a
repeated START on the bus.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: operations
   :end-before: -- docs-end: operations
   :dedent:

SMBus PEC
~~~~~~~~~

With ``pec => true`` a write ends with the PEC of every byte of the transfer, address bytes included,
and a read or write-read reads one more byte and compares it with the PEC. A wrong PEC is the status
``i2c_pec_error``.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: pec
   :end-before: -- docs-end: pec
   :dedent:

Checks
------

The master reports on its checker: a byte not acknowledged, a lost arbitration or a wrong PEC in a
transfer without ``status``; SCL held low for longer than ``stretch_timeout``; a metavalue on SDA where
it samples. The bus timing is checked by an :doc:`i2c_protocol_checker`, not by the master.

Python backend
--------------

The master creates an :py:class:`~awesome_vunit_vcs.i2c.vunit_backend.I2cMasterBackend`, which takes
the times from :py:func:`~awesome_vunit_vcs.i2c.timing.master_timing` and compiles transfers with
:py:func:`~awesome_vunit_vcs.i2c.master.compile_transfer` and
:py:func:`~awesome_vunit_vcs.i2c.master.compile_ops`. It makes one bridge call to compile a transfer
and one for its result, none per bit.

.. note::

   * The master stops driving at the bit where it loses arbitration; it does not clock out the rest of
     the byte.
   * An operation string is limited by the stack of the simulator, about 32,000 characters on GHDL.
   * ``reset`` does not abort a transfer in progress; it waits for it to end.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#i2c-master>`__.
