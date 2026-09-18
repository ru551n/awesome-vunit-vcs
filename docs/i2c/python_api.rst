Python API
==========

The same API is available as JSON in `api/python.json <../api/python.json>`__.

The public Python API of the I2C family, grouped by topic. :doc:`python` shows how the pieces fit
together. Times are integers in femtoseconds (``_fs``) and frequencies in Hz.

Everything a test normally needs is importable from one module::

    from awesome_vunit_vcs import i2c

The package exports ``AddressKind``, ``BusLimits``, ``Eeprom24``, ``I2cCheckId``, ``I2cDevice``,
``I2cError``, ``I2cMonitor``, ``I2cProtocolChecker``, ``I2cResult``, ``I2cStatistics``, ``I2cStatus``,
``I2cTarget``, ``I2cTransfer``, ``I2cValueError``, ``I2cViolation``, ``MasterTiming``,
``RegisterDevice``, ``SpeedMode``, ``bus_limits``, ``compile_ops``, ``compile_transfer``, ``master_timing`` and
``smbus_pec``, documented in the modules that define them below.

.. automodule:: awesome_vunit_vcs.i2c
   :no-members:

Device models
-------------

.. automodule:: awesome_vunit_vcs.i2c.devices
   :members: I2cDevice, RegisterDevice, Eeprom24

Target
------

.. automodule:: awesome_vunit_vcs.i2c.target
   :members: I2cTarget, Directive, Action

Monitor and transfers
---------------------

.. automodule:: awesome_vunit_vcs.i2c.monitor
   :members: I2cMonitor, I2cStatistics

.. automodule:: awesome_vunit_vcs.i2c.transfer
   :members: I2cTransfer, AddressKind, address_kind, TransferAssembler

.. automodule:: awesome_vunit_vcs.i2c.bus
   :members: BusDecoder, BusEvent, EventKind, SCL_BIT, SDA_BIT, SCL_METAVALUE_BIT, SDA_METAVALUE_BIT

Protocol checker
----------------

.. automodule:: awesome_vunit_vcs.i2c.checker
   :members: I2cProtocolChecker, I2cCheckId, I2cViolation, PROTOCOL_CHECKS

Timing
------

.. automodule:: awesome_vunit_vcs.i2c.timing
   :members: SpeedMode, BusLimits, MasterTiming, bus_limits, master_timing

Master
------

.. automodule:: awesome_vunit_vcs.i2c.master
   :members: compile_transfer, compile_ops, Program, I2cResult, I2cStatus, OpKind, OpRole, op_word, FLAG,
             NOT_EXECUTED, ARBITRATION_LOST, SCL_TIMEOUT

PEC
---

.. automodule:: awesome_vunit_vcs.i2c.pec
   :members: smbus_pec, pec_update

Exceptions
----------

Every invalid argument or configuration raises :class:`~awesome_vunit_vcs.i2c.errors.I2cValueError`,
a ``ValueError`` and an :class:`~awesome_vunit_vcs.i2c.errors.I2cError`, which derives from
:class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`.

.. automodule:: awesome_vunit_vcs.i2c.errors
   :members: I2cError, I2cValueError

Simulation backends
-------------------

The Python objects behind the VHDL components, ``vc`` in the Python session of each.

.. automodule:: awesome_vunit_vcs.i2c.vunit_backend
   :members: I2cMasterBackend, I2cTargetBackend, I2cMonitorBackend, I2cProtocolCheckerBackend
