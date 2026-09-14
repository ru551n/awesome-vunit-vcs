The first release is being prepared. Nothing has been released yet.

* Ethernet: GMII and XGMII-family monitors and sources, with frame reconstruction, protocol
  checks, statistics, PCAPNG capture and optional Scapy packets.
* Installable VUnit package: ``vu.add_package("awesome-vunit-vcs")``.

Python API
----------

* One frame type for tests: ``Frame`` (``from_payload``, ``from_bytes``, ``from_packet``,
  ``to_wire``, ``padded``, ``to_scapy``), with the ``GMII``, ``MII`` and ``XGMII(...)`` interfaces,
  ``Samples``, a context-manager ``Monitor``, ``decode``, ``write_pcapng`` and ``fs``/``bps``, all
  importable from ``awesome_vunit_vcs.ethernet``.
* Malformed traffic is data: ``WireOptions`` and ``Malformation``, with ``expected_violations`` as
  the oracle of the checker and ``Limits`` as the parameter space, so property-based tests build
  their Hypothesis strategies in a few lines. The package does not depend on Hypothesis.
* ``awesome_vunit_vcs.ethernet.traffic`` calls packet functions by name with literal keyword
  arguments, which are parsed and never evaluated, and generates seeded traffic.
* In a simulation, a monitor backend offers ``vc.on_frame``, ``vc.frames``, ``vc.statistics`` and
  ``vc.error``, a counted check error.
* Every invalid argument raises ``EthernetValueError``, a ``ValueError``.

Breaking changes
~~~~~~~~~~~~~~~~

* Error offsets count from the first octet after the SFD in every public API.
  ``WireFrame.error_offsets`` used to be wire indexes; those are now ``wire_error_offsets``, as
  are ``PhyFrame.error_offsets``.
* ``MacFrame``, ``EthernetFrame``, ``PhyFrame``, ``WireFrame``, ``EthernetMonitor``,
  ``EthernetConfig``, ``EthernetStatistics``, ``FcsMode``, ``build_wire_frame``, ``create_phy`` and
  the other building blocks moved to ``awesome_vunit_vcs.ethernet.lowlevel``. Importing them from
  ``awesome_vunit_vcs.ethernet`` still works in this release, with a ``DeprecationWarning``.
  ``EthernetConfig`` and ``EthernetStatistics`` are now named ``MonitorConfig`` and ``Statistics``.
* ``MonitorBackend.statistics`` is a property; calling it still works.
