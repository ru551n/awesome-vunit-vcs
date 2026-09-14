Python API
==========

The Python infrastructure every family shares.

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
   :members: join_time, split_time, decode_samples, encode_samples, bytes_from_unsigned
