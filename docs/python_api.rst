Python API
==========

The public Python API, grouped by topic. The names listed here are the public boundary: they are
exported by ``awesome_vunit_vcs.common``, ``awesome_vunit_vcs.ethernet`` and
``awesome_vunit_vcs.ethernet.phy`` (``__all__``), or are the documented backend classes behind the
VHDL components. :doc:`python_guide` shows how they fit together.

Times are integers in femtoseconds (``_fs``), sizes are octets (``_octets``) and rates are bits per
second (``_bps``).

Common infrastructure
---------------------

Events
~~~~~~

.. automodule:: awesome_vunit_vcs.common.events
   :members: Publisher

Reports
~~~~~~~

.. automodule:: awesome_vunit_vcs.common.reports
   :members: Severity, Report, ReportQueue, encode_reports, decode_reports

Bridge encoding
~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.common.vunit_bridge
   :members: join_time, split_time, decode_samples, encode_samples, bytes_from_unsigned

Ethernet
--------

Frames
~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.frame
   :members: fcs32, append_fcs, EthernetConfig, MacFrame, EthernetFrame, FrameDecoder

Monitor
~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.monitor
   :members: EthernetMonitor

Protocol checker
~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.checker
   :members: CheckId, Violation, ProtocolChecker

Statistics
~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.metrics
   :members: EthernetStatistics, Summary, PerformanceMonitor

Capture
~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.pcap
   :members: CaptureOptions, PcapNgWriter

Source
~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.source
   :members: FcsMode, build_wire_frame, EthernetSource

Scapy
~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.scapy_adapter
   :members: to_scapy, packet_bytes

Simulation backends
~~~~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.vunit_backend
   :members: MonitorBackend, SourceBackend

PHY decoders
~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.phy
   :no-members:

.. autofunction:: awesome_vunit_vcs.ethernet.phy.create_phy

.. automodule:: awesome_vunit_vcs.ethernet.phy.common
   :members: PhyInterface, WireFrame, PhyFrame, OctetBatch, PhyEvent, IdleEvent, FrameAssembler

.. automodule:: awesome_vunit_vcs.ethernet.phy.gmii
   :members: GmiiPhy

.. automodule:: awesome_vunit_vcs.ethernet.phy.xgmii
   :members: XgmiiPhy
