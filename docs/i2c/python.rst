I2C in Python
=============

Everything the I2C components decide is made in ``awesome_vunit_vcs.i2c``: the device models of the
target, the protocol engine that addresses them, the decoding of the monitor and the checks of the
protocol checker. Write a device model of your own in Python, or use the pieces without a simulator.

.. include:: ../_includes/vunit_names.inc

Write a device model
--------------------

A device model is a subclass of :py:class:`~awesome_vunit_vcs.i2c.devices.I2cDevice` in a Python file
of your project. The target calls it once per byte; override the methods your device needs. Times are
integers in femtoseconds.

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Method
     - Called when
   * - ``responds_to(address)``
     - An address arrives; by default the device answers ``self.address``, the address of the target
   * - ``start(address, read, now_fs)``
     - The address is complete; returns whether to acknowledge it
   * - ``write(value, now_fs)``
     - The master wrote a byte; returns whether to acknowledge it
   * - ``read(now_fs)``
     - The master reads a byte; returns it
   * - ``read_ack(acked, now_fs)``
     - The master acknowledged the byte it read, or not
   * - ``end(stopped, now_fs)``
     - The transfer ended with a STOP, or with a repeated START when ``stopped`` is false
   * - ``preload(address, data)``, ``read_memory(address, length)``
     - The testbench calls :vhdl:`i2c_target_pkg.i2c_target_preload`,
       :vhdl:`i2c_target_pkg.i2c_target_check_memory` or :vhdl:`i2c_target_pkg.i2c_target_read_memory`

This temperature sensor (Python) answers register reads and does not acknowledge its address while a
conversion runs:

.. literalinclude:: ../../examples/i2c/python/sensor.py
   :caption: examples/i2c/python/sensor.py
   :language: python
   :start-after: # docs-start: sensor-model
   :end-before: # docs-end: sensor-model

The testbench (VHDL) names the class as ``"module:Class"`` and gives its arguments with the bridge's
typed ``kwarg``, and the run script puts the directory of the module on ``PYTHONPATH``, as
:ref:`i2c-quick-start` shows:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: python-model
   :end-before: -- docs-end: python-model
   :dedent:

An exception in the model is a failure on the logger of the target, with the line in your code. The
target handles addressing, acknowledge bits, the PEC and clock stretching itself, so the model sees
only the transfers to it.

Without a simulator
-------------------

The target engine, the monitor and the protocol checker work in plain Python, for unit tests of a
device model or of recorded bus traffic.

.. literalinclude:: ../../examples/python/i2c_device_model.py
   :caption: examples/python/i2c_device_model.py
   :language: python
   :start-after: # docs-start: imports
   :end-before: # docs-end: imports

:py:class:`~awesome_vunit_vcs.i2c.target.I2cTarget` takes the calls the VHDL target makes and returns a
:py:class:`~awesome_vunit_vcs.i2c.target.Directive` for each:

.. literalinclude:: ../../examples/python/i2c_device_model.py
   :caption: examples/python/i2c_device_model.py
   :language: python
   :start-after: # docs-start: target
   :end-before: # docs-end: target

:py:class:`~awesome_vunit_vcs.i2c.monitor.I2cMonitor` and
:py:class:`~awesome_vunit_vcs.i2c.checker.I2cProtocolChecker` take sample words, SCL in bit 0 and SDA
in bit 1, with their times:

.. literalinclude:: ../../examples/python/i2c_device_model.py
   :caption: examples/python/i2c_device_model.py
   :language: python
   :start-after: # docs-start: monitor
   :end-before: # docs-end: monitor

Master transfers
----------------

:py:func:`~awesome_vunit_vcs.i2c.master.compile_transfer` and
:py:func:`~awesome_vunit_vcs.i2c.master.compile_ops` build the operations the VHDL master clocks out,
and :py:meth:`Program.result <awesome_vunit_vcs.i2c.master.Program.result>` reads its results. They
are what :vhdl:`i2c_master_pkg.i2c_write` and :vhdl:`i2c_master_pkg.i2c_transfer` call.
