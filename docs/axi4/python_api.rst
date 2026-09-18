Python API
==========

The same API is available as JSON in `api/python.json <../api/python.json>`__.

The public Python API of the AXI4 family, grouped by topic. :doc:`python` shows how the pieces fit
together. Times are integers in femtoseconds (``_fs``), latencies in clock cycles and sizes in bytes.

Everything a test normally needs is importable from one module::

    from awesome_vunit_vcs import axi4

The package exports ``Axi4Beat``, ``Axi4CheckId``, ``Axi4Config``, ``Axi4Error``, ``Axi4Monitor``,
``Axi4PerformanceMonitor``, ``Axi4ProtocolChecker``, ``Axi4Sample``, ``Axi4Slave``, ``Axi4Statistics``,
``Axi4Transaction``, ``Axi4ValueError``, ``Axi4Violation``, ``Buffer``, ``BurstType``, ``Channel``,
``ChannelStatistics``, ``Direction``, ``DirectionStatistics``, ``Distribution``, ``Endianness``,
``MemoryModel``, ``Permission``, ``Response``, ``SampleDecoder``, ``ShadowMemory``, ``SlaveBurst``,
``SlaveRead``, ``beat_addresses``, ``beat_lanes`` and ``crosses_4k``, documented in the modules that
define them below.

.. automodule:: awesome_vunit_vcs.axi4
   :no-members:

Bursts
------

.. automodule:: awesome_vunit_vcs.axi4.burst
   :members: BurstType, beat_addresses, beat_lanes, lane_mask, crosses_4k

Interface and sample words
--------------------------

.. automodule:: awesome_vunit_vcs.axi4.bus
   :members: Axi4Config, Channel, ControlKind, Axi4Sample, Axi4Control, AddressPayload, WriteDataPayload,
             ResponsePayload, ReadDataPayload, SampleDecoder

Transactions
------------

.. automodule:: awesome_vunit_vcs.axi4.transaction
   :members: Axi4Transaction, Axi4Beat, Direction, Response, TransactionTracker

Monitor
-------

.. automodule:: awesome_vunit_vcs.axi4.monitor
   :members: Axi4Monitor

.. automodule:: awesome_vunit_vcs.axi4.memory
   :members: ShadowMemory

Performance statistics
----------------------

.. automodule:: awesome_vunit_vcs.axi4.performance
   :members: Axi4PerformanceMonitor, Axi4Statistics, DirectionStatistics, ChannelStatistics, Distribution

Protocol checker
----------------

.. automodule:: awesome_vunit_vcs.axi4.checker
   :members: Axi4ProtocolChecker, address_violations

.. automodule:: awesome_vunit_vcs.axi4.checks
   :members: Axi4CheckId, Axi4Violation, PROTOCOL_CHECKS

Slaves and their memory
-----------------------

The memory behind the read and write slaves, VUnit's ``memory_t`` on the sparse store of
:mod:`~awesome_vunit_vcs.common.sparse_memory`, and what the slaves read, write and respond.

.. automodule:: awesome_vunit_vcs.axi4.memory_model
   :members: MemoryModel, Buffer, Permission, Endianness

.. automodule:: awesome_vunit_vcs.axi4.slave
   :members: Axi4Slave, SlaveBurst, SlaveRead

Exceptions
----------

Every invalid argument or configuration raises :class:`~awesome_vunit_vcs.axi4.errors.Axi4ValueError`,
a ``ValueError`` and an :class:`~awesome_vunit_vcs.axi4.errors.Axi4Error`, which derives from
:class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`.

.. automodule:: awesome_vunit_vcs.axi4.errors
   :members: Axi4Error, Axi4ValueError

Simulation backends
-------------------

The Python objects behind the VHDL components, ``vc`` in the Python session of each.

.. automodule:: awesome_vunit_vcs.axi4.vunit_backend
   :members: Axi4MonitorBackend, Axi4ProtocolCheckerBackend, Axi4MemoryBackend
