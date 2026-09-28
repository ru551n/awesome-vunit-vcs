Python API
==========

The same API is available as JSON in `api/python.json <../api/python.json>`__.

The Python API every family shares. :doc:`index` shows how to use it.

Errors
------

.. automodule:: awesome_vunit_vcs.errors
   :members: AwesomeVunitVcsError

Events
------

.. automodule:: awesome_vunit_vcs.common.events
   :members: Publisher, T, Subscriber, ErrorHandler

Reports
-------

.. automodule:: awesome_vunit_vcs.common.reports
   :members: Severity, Report, ReportQueue, encode_reports, decode_reports

Bridge encoding
---------------

.. automodule:: awesome_vunit_vcs.common.vunit_bridge
   :members: decode_text, decode_time_fs, join_time, split_time, decode_samples, encode_samples, bytes_from_unsigned

Backends
--------

The base classes of the Python objects behind the VHDL components of the I2C and AXI4 families.

.. automodule:: awesome_vunit_vcs.common.backend
   :members: VcBackend, SampleBackend, int32_array, exception_summary, VHDL_INTEGER_MAX

Sparse memory
-------------

The byte store of the flash array and the AXI4 memory.

.. automodule:: awesome_vunit_vcs.common.sparse_memory
   :members: SparseMemory, SparseMemoryError
