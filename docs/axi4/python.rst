AXI4 in Python
==============

Everything the AXI4 components decide is made in ``awesome_vunit_vcs.axi4``: the address and byte lanes
of every beat, the transactions, the checks and the statistics. The pieces work without a simulator, for
unit tests of your own burst arithmetic or to analyze records of an interface.

.. include:: ../_includes/vunit_names.inc

The imports of the examples below (Python):

.. literalinclude:: ../../examples/python/axi4_bursts.py
   :caption: examples/python/axi4_bursts.py
   :language: python
   :start-after: # docs-start: imports
   :end-before: # docs-end: imports

Burst arithmetic
----------------

:py:func:`~awesome_vunit_vcs.axi4.burst.beat_addresses`,
:py:func:`~awesome_vunit_vcs.axi4.burst.beat_lanes` and
:py:func:`~awesome_vunit_vcs.axi4.burst.crosses_4k` follow the formulas of the specification. They
take AxADDR, AxLEN (``length``), AxSIZE (``size``) and AxBURST as the pins carry them:

.. literalinclude:: ../../examples/python/axi4_bursts.py
   :caption: examples/python/axi4_bursts.py
   :language: python
   :start-after: # docs-start: bursts
   :end-before: # docs-end: bursts

Monitor and protocol checker without a simulator
------------------------------------------------

:py:class:`~awesome_vunit_vcs.axi4.monitor.Axi4Monitor` and
:py:class:`~awesome_vunit_vcs.axi4.checker.Axi4ProtocolChecker` take the sample words the VHDL
components record, with their times in fs. Each record is a header word and the fields of a channel,
packed 32 bits to a word; :py:mod:`awesome_vunit_vcs.axi4.bus` describes the layout. Subscribe to
``transactions`` to see every transaction as it completes:

.. literalinclude:: ../../examples/python/axi4_bursts.py
   :caption: examples/python/axi4_bursts.py
   :language: python
   :start-after: # docs-start: monitor
   :end-before: # docs-end: monitor

An :py:class:`~awesome_vunit_vcs.axi4.transaction.Axi4Transaction` has the address phase, every
:py:class:`~awesome_vunit_vcs.axi4.transaction.Axi4Beat` with its address, lanes, data and strobes, the
response and the time of every handshake. ``data()`` gives the bytes of the byte lanes in beat order and
``transferred_bytes()`` the ``(address, value)`` of every byte written or read.
:py:meth:`~awesome_vunit_vcs.axi4.performance.Axi4Statistics.summary` is the text
:vhdl:`log_axi4_statistics <axi4_monitor_pkg.log_axi4_statistics>` logs.
