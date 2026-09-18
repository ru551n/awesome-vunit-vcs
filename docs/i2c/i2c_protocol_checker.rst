I2C protocol checker
====================

The :vhdl:`i2c_protocol_checker` component checks the timing and the bit-level protocol of an I2C bus
against a speed mode. It never drives the bus.

.. include:: ../_includes/vunit_names.inc

Overview
--------

The checker records every change of SCL and SDA with its time, like the monitor, and its Python
backend measures every interval the specification limits. Each check has a stable ID, can be switched
off on its own, and counts its violations. A violation is a VUnit check failure on the checker of the
component, with the measured value, the limit and the simulation time in fs. Instantiate the checker
on a bus, or pass its handle to :vhdl:`i2c_monitor_pkg.new_i2c_monitor`.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`i2c_protocol_checker`
   * - Speed modes
     - Standard-mode, Fast-mode, Fast-mode Plus, with every limit replaceable
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

The :term:`handle` is the only generic: ``protocol_checker : i2c_protocol_checker_t``.

Constructor parameters
----------------------

:vhdl:`i2c_protocol_checker_pkg.new_i2c_protocol_checker`:

.. list-table::
   :header-rows: 1
   :widths: 25 20 15 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``speed``
     - ``i2c_speed_t``
     - ``i2c_standard_mode``
     - The speed mode whose limits apply
   * - ``f_scl_max_hz``
     - ``natural``
     - ``0``
     - The highest SCL frequency
   * - ``t_hd_sta``, ``t_low``, ``t_high``, ``t_su_sta``, ``t_hd_dat``, ``t_su_dat``, ``t_su_sto``,
       ``t_buf``
     - ``delay_length``
     - ``0 ns``
     - Minimum times, see the checks below
   * - ``t_stuck``
     - ``delay_length``
     - ``35 ms``
     - How long SCL or SDA may stay low, 0 ns for no limit
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - See the family page

A limit of 0 keeps the value of the speed mode, from the characteristics table of the specification:

.. list-table::
   :header-rows: 1
   :widths: 25 25 25 25

   * - Limit
     - Standard-mode
     - Fast-mode
     - Fast-mode Plus
   * - ``f_scl_max_hz``
     - 100 kHz
     - 400 kHz
     - 1 MHz
   * - ``t_hd_sta``
     - 4.0 us
     - 600 ns
     - 260 ns
   * - ``t_low``
     - 4.7 us
     - 1.3 us
     - 500 ns
   * - ``t_high``
     - 4.0 us
     - 600 ns
     - 260 ns
   * - ``t_su_sta``
     - 4.7 us
     - 600 ns
     - 260 ns
   * - ``t_hd_dat``
     - 0 ns
     - 0 ns
     - 0 ns
   * - ``t_su_dat``
     - 250 ns
     - 100 ns
     - 50 ns
   * - ``t_su_sto``
     - 4.0 us
     - 600 ns
     - 260 ns
   * - ``t_buf``
     - 4.7 us
     - 1.3 us
     - 500 ns

Checks
------

.. list-table::
   :header-rows: 1
   :widths: 22 58 20

   * - Check
     - I2cViolation
     - Limit
   * - ``i2c_f_scl``
     - Two rising SCL edges closer than 1 / ``f_scl_max_hz``. Intervals across a START or STOP are left
       out; the setup and hold times of the conditions apply there.
     - ``f_scl_max_hz``
   * - ``i2c_t_hd_sta``
     - SCL fell too soon after a START or repeated START
     - ``t_hd_sta``
   * - ``i2c_t_low``
     - SCL low too briefly
     - ``t_low``
   * - ``i2c_t_high``
     - SCL high too briefly, outside START and STOP
     - ``t_high``
   * - ``i2c_t_su_sta``
     - A repeated START too soon after SCL rose
     - ``t_su_sta``
   * - ``i2c_t_hd_dat``
     - SDA changed too soon after SCL fell
     - ``t_hd_dat``
   * - ``i2c_t_su_dat``
     - SDA changed too late before SCL rose
     - ``t_su_dat``
   * - ``i2c_t_su_sto``
     - A STOP too soon after SCL rose
     - ``t_su_sto``
   * - ``i2c_t_buf``
     - A START too soon after a STOP
     - ``t_buf``
   * - ``i2c_sda_stable``
     - SDA changed while SCL was high inside a byte: a START or STOP after 1 to 7 bits
     -
   * - ``i2c_ack_slot``
     - A byte without an acknowledge bit: a START or STOP right after 8 bits
     -
   * - ``i2c_metavalue``
     - ``U``, ``X``, ``Z``, ``W`` or ``-`` on SCL or SDA; a resolved ``'Z'`` means the pull-up is missing
     -
   * - ``i2c_stuck_low``
     - SCL or SDA low for longer than ``t_stuck``, reported once per low period
     - ``t_stuck``
   * - ``i2c_scoreboard``
     - Run by the monitor, see :doc:`i2c_monitor`
     -

The message starts with the check ID in upper case, for example
``I2C_T_LOW: SCL low for 1000000000 fs, less than the minimum 1300000000 fs at 20100000000 fs``. When
SCL and SDA change at the same time, the SDA change belongs to the low phase of SCL, so it is never
taken for a START or STOP.

Procedures
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`set_check_enabled <i2c_protocol_checker_pkg.set_check_enabled>`
     - Enable or disable one check; a disabled check neither reports nor counts
   * - :vhdl:`get_check_count <i2c_protocol_checker_pkg.get_check_count>`,
       :vhdl:`await_get_check_count_reply <i2c_protocol_checker_pkg.await_get_check_count_reply>`
     - The violations of one check found while it was enabled
   * - ``reset``
     - Counts to 0 and the timing history forgotten; the switches are kept

Count violations in a negative test
-----------------------------------

A negative test lets the checker report without stopping, counts, and resets the log count so the
test ends clean:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: fast-master
   :end-before: -- docs-end: fast-master
   :dedent:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: negative
   :end-before: -- docs-end: negative
   :dedent:

A violation that is not counted still fails the test at ``test_runner_cleanup``.

Python backend
--------------

The checker creates an :py:class:`~awesome_vunit_vcs.i2c.vunit_backend.I2cProtocolCheckerBackend`,
which runs an :py:class:`~awesome_vunit_vcs.i2c.checker.I2cProtocolChecker` with the limits of
:py:func:`~awesome_vunit_vcs.i2c.timing.bus_limits`. The sample word is the one of the monitor. A line
stuck low has no edges, so the component records a sample of its own after ``t_stuck`` without a
change.

.. note::

   * Only minimum times are checked; rise and fall times, the data valid times (tVD;DAT, tVD;ACK) and
     spike suppression are not, as simulated lines change in zero time.
   * Times in messages are in fs, rounded down to whole ps by the sample batch.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#i2c-protocol-checker>`__.
