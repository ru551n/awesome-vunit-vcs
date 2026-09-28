I2C target
==========

The :vhdl:`i2c_target` component answers transfers at its address with a device model written in
Python: a register map, a 24Cxx serial EEPROM, or a class of your own.

.. include:: ../_includes/vunit_names.inc

Overview
--------

Use the target to test a controller design, such as a design reading a sensor or its configuration
from an EEPROM. The component shifts bits in and out; its Python backend recognizes the address,
decides on every acknowledge bit and asks the device model what each byte means. It calls Python at
every START and STOP and once per byte, never per clock edge. Clock stretching and NACK injection are
set from VHDL or Python.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`i2c_target`
   * - Speed modes
     - Any: the target follows the clock of the master
   * - Addressing
     - 7-bit, 10-bit and the general call; an EEPROM answers the addresses of its blocks
   * - Device models
     - ``"registers"``, ``"eeprom"``, ``"device"`` or ``"package.module:Class"``
   * - Bus features
     - Clock stretching, NACK injection, SMBus PEC
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
     - SCL, released ``'Z'``, or driven ``'0'`` to stretch the clock
   * - ``sda``
     - inout
     - ``std_logic``
     - SDA, driven ``'0'`` or released ``'Z'``

The target changes SDA ``t_hd_dat`` after SCL falls. A metavalue on SDA where it samples a bit is a
check failure on its checker. The :term:`handle` is the only generic: ``target : i2c_target_t``.

Constructor parameters
----------------------

:vhdl:`i2c_target_pkg.new_i2c_target`:

.. list-table::
   :header-rows: 1
   :widths: 20 20 20 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``address``
     - ``natural``
     -
     - The 7-bit address, or the 10-bit address with ``ten_bit``
   * - ``ten_bit``
     - ``boolean``
     - ``false``
     - ``address`` is a 10-bit address
   * - ``model``
     - ``string``
     - ``"registers"``
     - The device model, see below
   * - ``model_args``
     - ``arg_t``
     - ``null_arg``
     - The arguments of the model, such as ``kwarg("size_bytes", 512)``
   * - ``general_call``
     - ``boolean``
     - ``false``
     - Answer the general call address 0 as a write to the model
   * - ``pec``
     - ``boolean``
     - ``false``
     - SMBus Packet Error Checking, see below
   * - ``pec_read_bytes``
     - ``natural``
     - ``1``
     - The data bytes of a read before the PEC
   * - ``stretch``
     - ``delay_length``
     - ``0 ns``
     - Hold SCL low for this long before the acknowledge bit of every byte the target acknowledges
   * - ``t_hd_dat``
     - ``delay_length``
     - ``100 ns``
     - The delay of SDA after SCL falls
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - See the family page

Device models
~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - ``model``
     - Behavior
   * - ``"registers"``
     - :py:class:`~awesome_vunit_vcs.i2c.devices.RegisterDevice`: the first byte of a write selects a
       register, the next bytes write registers from it on, and a read returns registers from the
       selected one on. Arguments: ``size_bytes`` (256), ``address_bytes`` (1, the bytes that select
       a register), ``auto_increment`` (true) and ``fill`` (0).
   * - ``"eeprom"``
     - :py:class:`~awesome_vunit_vcs.i2c.devices.Eeprom24`, a 24Cxx: page writes that wrap within the
       page, a write cycle started by the STOP during which the address is not acknowledged, and
       sequential reads that wrap at the end of the memory. Parts larger than their address bytes
       reach, such as a 24C16, answer one address per block. Arguments: ``size_bytes`` (256),
       ``page_bytes`` (8), ``address_bytes`` (1 or 2), ``t_wr_fs`` (5 ms, given with ``kwarg_time``)
       and ``fill`` (0xFF).
   * - ``"device"``
     - :py:class:`~awesome_vunit_vcs.i2c.devices.I2cDevice`: acknowledges everything and reads 0xFF.
   * - ``"package.module:Class"``
     - Your subclass of :py:class:`~awesome_vunit_vcs.i2c.devices.I2cDevice`, imported by name in the
       simulator; see :doc:`python`.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

Procedures
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`set_i2c_target_stretch <i2c_target_pkg.set_i2c_target_stretch>`
     - Stretch SCL for this long before every acknowledge bit from now on, 0 ns to stop
   * - :vhdl:`inject_i2c_target_nack <i2c_target_pkg.inject_i2c_target_nack>`
     - Do not acknowledge byte ``byte_index`` of the next transfer to the target: 0 is the address
       byte, a 10-bit address takes bytes 0 and 1. The model still sees the byte.
   * - :vhdl:`i2c_target_preload <i2c_target_pkg.i2c_target_preload>`
     - Write the memory of the model directly
   * - :vhdl:`i2c_target_check_memory <i2c_target_pkg.i2c_target_check_memory>`
     - Compare the memory of the model; a difference is a check failure on the checker of the target
   * - :vhdl:`i2c_target_read_memory <i2c_target_pkg.i2c_target_read_memory>`,
       :vhdl:`await_i2c_target_read_memory_reply <i2c_target_pkg.await_i2c_target_read_memory_reply>`
     - Read the memory of the model
   * - ``reset``
     - See the family page

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stretch-nack
   :end-before: -- docs-end: stretch-nack
   :dedent:

The memory procedures work on the register map and the EEPROM, and on a model of your own that
implements ``preload`` and ``read_memory``; for any other model they are a failure on the logger of
the target.

SMBus PEC
~~~~~~~~~

With ``pec => true`` the target keeps the CRC-8 (polynomial 0x07) of every byte of a transaction,
address bytes included:

* The last byte of a write that ends with a STOP is the PEC. The model sees the written bytes at the
  STOP when the PEC is right; otherwise they are dropped and the target reports ``I2C_PEC: wrong PEC``
  as a check failure on its checker. A write that ends with a repeated START, the first half of a
  write-read, reaches the model without a PEC.
* A read sends ``pec_read_bytes`` bytes of the model, then the PEC, then 0xFF.

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: smbus-handle
   :end-before: -- docs-end: smbus-handle
   :dedent:

Checks
------

The target reports on its checker a metavalue on SDA where it samples a bit, a wrong PEC, and a memory
difference found by ``i2c_target_check_memory``. A failure of the Python model, such as an exception
in your class, is a failure on its logger with the line in your code. The bus timing is checked by an
:doc:`i2c_protocol_checker`.

Python backend
--------------

The target creates an :py:class:`~awesome_vunit_vcs.i2c.vunit_backend.I2cTargetBackend`, which runs
an :py:class:`~awesome_vunit_vcs.i2c.target.I2cTarget` with the device model. Each call returns a
:py:class:`~awesome_vunit_vcs.i2c.target.Directive`: acknowledge or not, how long to stretch, and
whether to receive, transmit or ignore the next byte.

.. note::

   * One bridge call per byte and per START or STOP.
   * The target stretches the clock only before acknowledge bits.
   * A read with PEC sends a fixed number of data bytes, ``pec_read_bytes``, before the PEC.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#i2c-target>`__.
