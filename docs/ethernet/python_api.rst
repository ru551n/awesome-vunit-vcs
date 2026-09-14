Python API
==========

The public Python API, grouped by topic. :doc:`python` and :doc:`python_simulation` show how to use it.

Everything a test normally needs is importable from one module::

    from awesome_vunit_vcs import ethernet as eth

Times are integers in femtoseconds (``_fs``), sizes are octets (``_octets``) and rates are bits per
second (``_bps``); :func:`~awesome_vunit_vcs.ethernet.units.fs` and
:func:`~awesome_vunit_vcs.ethernet.units.bps` convert strings such as ``"8 ns"`` and ``"2.5G"``.
Every invalid argument raises :class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`.

Ethernet
--------

Frames, monitors and decoding
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.api
   :members: Frame, WireOptions, FcsKind, Monitor, Result, decode, write_pcapng, expected_violations,
             supported_malformations, mac_address, DEFAULT_DESTINATION, DEFAULT_SOURCE, DEFAULT_ETHERTYPE

Interfaces and samples
~~~~~~~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.interfaces
   :members: Interface, GMII, MII, XGMII, AXIS, Samples, INTERFACE_NAMES, SupportsToWire, Encodable, to_wire_frame

Limits and malformations
~~~~~~~~~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.limits
   :members: Limits, LIMITS, Malformation

Configuration, violations and statistics
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:class:`~awesome_vunit_vcs.ethernet.frame.MonitorConfig`,
:class:`~awesome_vunit_vcs.ethernet.checker.CheckId`,
:class:`~awesome_vunit_vcs.ethernet.checker.Violation`,
:class:`~awesome_vunit_vcs.ethernet.metrics.Statistics` and
:class:`~awesome_vunit_vcs.ethernet.metrics.Summary` are importable from
``awesome_vunit_vcs.ethernet`` and documented with their modules below.

Units and errors
~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.units
   :members: fs, bps, FS_PER_SECOND, TIME_UNITS, RATE_PREFIXES

.. automodule:: awesome_vunit_vcs.ethernet.errors
   :members: EthernetValueError

Traffic
~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.traffic
   :members: TrafficItem, Packet, Seed, TrafficError, rng_from, resolve, to_frame, to_item,
             call_packet_function, sequence, batches, random_mac_address, random_frame, random_wire_options,
             random_traffic, interface_named

Low-level pipeline
------------------

.. automodule:: awesome_vunit_vcs.ethernet.lowlevel
   :no-members:

The building blocks :class:`~awesome_vunit_vcs.ethernet.api.Monitor` and the VHDL backends are made
of. ``EthernetConfig`` and ``EthernetStatistics`` are the former names of ``MonitorConfig`` and
``Statistics``.

Frame analysis
~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.frame
   :members: MonitorConfig, fcs32, append_fcs, MacFrame, EthernetFrame, FrameDecoder

Monitor pipeline
~~~~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.monitor
   :members: EthernetMonitor

.. automodule:: awesome_vunit_vcs.ethernet.checker
   :members: CheckId, Violation, ProtocolChecker

.. automodule:: awesome_vunit_vcs.ethernet.metrics
   :members: Statistics, Summary, PerformanceMonitor

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

PHY decoders
~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.ethernet.phy
   :no-members:

.. autofunction:: awesome_vunit_vcs.ethernet.phy.create_phy

.. automodule:: awesome_vunit_vcs.ethernet.phy.common
   :members: PhyInterface, WireFrame, PhyFrame, OctetBatch, PhyEvent, IdleEvent, FrameAssembler, Int32Array,
             Int64Array

.. automodule:: awesome_vunit_vcs.ethernet.phy.gmii
   :members: GmiiPhy

.. automodule:: awesome_vunit_vcs.ethernet.phy.xgmii
   :members: XgmiiPhy

.. automodule:: awesome_vunit_vcs.ethernet.phy.mii
   :members: MiiPhy

.. automodule:: awesome_vunit_vcs.ethernet.phy.axis
   :members: AxisPhy

Simulation backends
-------------------

The Python objects behind the VHDL components, ``vc`` in the Python session of each component.
Annotate it in your own modules with ``vc: MonitorBackend``.

.. automodule:: awesome_vunit_vcs.ethernet.vunit_backend
   :members: MonitorBackend, ProtocolCheckerBackend, SourceBackend
