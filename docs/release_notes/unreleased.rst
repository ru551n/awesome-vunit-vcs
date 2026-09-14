The first release is being prepared. Nothing has been released yet.

* Ethernet: GMII, MII and XGMII-family sources, monitors and protocol checkers (the XGMII family
  from 2.5GMII up to 200GMII and 400GMII), with frame
  reconstruction, protocol checks, statistics, PCAPNG capture and packets from Python functions.
* Flash: a QSPI NOR flash VC with a simulator independent Python device model (SPI mode 0, x1, x2
  and x4 I/O, QPI, 3- and 4-byte addressing, continuous read, SFDP, status register and region
  protection, busy times, and erase sizes and addressing modes from the configuration), a QSPI master
  VC with a JEDEC command layer, and a QSPI protocol checker VC for the pin timing of the master.
  Every flash VC has ``reset(net, handle)``; the master's aborts a transfer in progress. Bytes can be
  given as ``std_ulogic_vector`` literals such as ``x"DEADBEEF"``, or with ``new_byte_array``.
* Installable VUnit package: ``vu.add_package("awesome-vunit-vcs")``.

VHDL API
--------

* Every interface has a source, a monitor and a protocol checker with a handle type of its own
  (``gmii_source_t``, ``gmii_monitor_t``, ``gmii_protocol_checker_t``, and the same for MII and
  XGMII), created like VUnit's own VCs: the VC configuration, then ``id``, ``logger``, ``actor``,
  ``checker`` and ``unexpected_msg_type_policy``. A default id is ``awesome_vunit_vcs:<vc name>:<n>``,
  and a protocol checker given to a monitor gets the id ``<monitor id>:protocol_checker``.
* Protocol checks run in the ``<interface>_protocol_checker`` entities, which a monitor instantiates
  when its handle has one, like ``axi_stream_monitor``.
* Sources implement VUnit's stream master VCI and monitors the stream slave VCI; every VC implements
  the sync VCI including ``wait_for_time``. Monitors publish ``ethernet_frame_msg`` and answer
  ``pop_ethernet_frame``; ``check_ethernet_frame`` can block; values have non-blocking variants.
* ``frame_options`` instead of loose frame arguments, a header-field overload of
  ``push_ethernet_frame``, and packets and reproducible sequences from Python functions:
  ``push_ethernet_packet``, ``push_ethernet_sequence`` and ``check_ethernet_sequence``.
* ``reset(net, vc)`` recovers any VC, also while the clock is stopped.
* ``ethernet_context`` is the only context clause a testbench needs.
* ``eth_user`` counts errors Python code reports with ``vc.error``.

Breaking changes to the VHDL API
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Before
     - Now
   * - ``ethernet_monitor_t``, ``ethernet_source_t`` as component handles
     - ``gmii_monitor_t``, ``gmii_source_t`` (and ``mii_*``, ``xgmii_*``). The old names are now the
       interface independent Ethernet VCIs, returned by ``as_ethernet_monitor`` and
       ``as_ethernet_source``.
   * - ``new_ethernet_monitor``, ``new_ethernet_source``, ``ethernet_phy_t``
     - Removed; use ``new_<interface>_monitor`` and ``new_<interface>_source``.
   * - ``id`` as the first constructor parameter
     - ``id`` follows the VC configuration, with ``logger``, ``actor`` and ``checker`` after it.
   * - A monitor checks the protocol
     - A monitor does not; pass ``protocol_checker => default_<interface>_protocol_checker`` or
       instantiate ``<interface>_protocol_checker``. Violations are logged by the protocol checker.
   * - ``set_check_enabled``, ``get_check_count`` on a monitor
     - Still on the monitor, forwarded to its protocol checker; a monitor without one is a failure.
   * - ``send_ethernet_frame(net, source, data, fcs => fcs_bad)``
     - ``push_ethernet_frame(net, source, data, frame_options(fcs => fcs_bad))``
   * - ``send_ethernet_packet(net, source, "Ether()/IP()")``, a Scapy expression string
     - Removed; ``push_ethernet_packet(net, source, "module:function", kwarg("key", value))`` calls a
       Python function.
   * - ``expect_ethernet_frame(net, monitor, data)``
     - ``check_ethernet_frame(net, monitor, data, blocking => false)``
   * - ``send_xgmii_columns``, ``send_xgmii_link_fault``
     - ``push_xgmii_columns``, ``push_xgmii_link_fault``
   * - ``ethernet_send_frame_msg`` and the other message types, one ``ethernet_reply_msg``
     - Verb first, such as ``push_ethernet_frame_msg``, and a ``*_reply_msg`` per request with a
       reply.
   * - ``arguments => "port=1234, size=128"`` on ``push_ethernet_packet``, ``push_ethernet_sequence``,
       ``check_ethernet_sequence`` and ``new_property``
     - Typed arguments: ``kwarg("port", 1234) & kwarg("size", 128)``, with ``kwarg_text`` for free text
       and ``kwarg_time`` for times.
   * - ``vcs_python_pkg`` with ``py_str``, ``py_bool``, ``py_int_list``, ``backend_exec`` and
       ``backend_integer``/``_boolean``/``_string``/``_integer_array``
     - ``vc_python_pkg`` with ``backend_call`` and ``backend_call_integer``/``_boolean``/``_string``/
       ``_integer_array``, ``arg_text``/``kwarg_text``, ``arg_time``/``kwarg_time`` and
       ``push_arg``/``pop_arg``; ``create_backend`` takes typed arguments.

Property-based testing
----------------------

* ``property_pkg`` runs a Hypothesis property inside one simulation: ``new_property`` names a
  Python function returning a strategy, ``next_example`` and ``report_example`` loop over the
  examples, and ``check_property`` reports the minimal counterexample Hypothesis shrank to.
* Composite examples are read by path, such as ``get_integer_vector(prop, "frames(2).payload")``,
  with ``has_field`` for optional fields.
* Records from Python dataclasses: ``awesome_vunit_vcs.records`` (``Range``, ``Length``,
  ``Choices``, ``strategy_for``, ``validate``) and ``awesome_vunit_vcs.gen_vhdl``, which generates
  VHDL record types with ``get_<name>(prop, path)`` and ``to_string`` from the same dataclasses.
* A lockup is reported with ``timed_out`` as a failure of its own, a design that does not recover
  aborts the property, each example is journaled before it runs, and the smallest failure is
  replayed first on the next run.
* ``report_score`` forwards a score of an example to ``hypothesis.target``.
* Examples in ``examples/property``: a scalar, a record with a list, a tagged union, a stateful register
  bank against a reference model, scores, a metamorphic property, timing, swarm testing and a generated
  record in one testbench, plus an Ethernet frame
  property and a lockup. The package does not depend on Hypothesis.
* Stateful properties: a strategy function may return a ``RuleBasedStateMachine`` subclass whose
  rules run steps in VHDL with ``step``; ``get_rule`` and ``report_step`` in ``property_pkg``.
* ``@pin`` keeps counterexamples as regressions, and ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE`` selects a
  quick or a long example budget. A nightly workflow runs the long profile, and CI keeps saved
  failures between runs.

Python API
----------

* One frame type for tests: ``Frame`` (``from_payload``, ``from_bytes``, ``from_packet``,
  ``to_wire``, ``padded``, ``to_scapy``), with the ``GMII``, ``MII`` and ``XGMII(...)`` interfaces,
  ``Samples``, a context-manager ``Monitor``, ``decode``, ``write_pcapng`` and ``fs``/``bps``, all
  importable from ``awesome_vunit_vcs.ethernet``.
* Malformed traffic is data: ``WireOptions`` and ``Malformation``, with ``expected_violations`` as
  the oracle of the checker and ``Limits`` as the parameter space, so property-based tests build
  their Hypothesis strategies in a few lines. The package does not depend on Hypothesis.
* ``awesome_vunit_vcs.ethernet.traffic`` calls packet functions by name with Python arguments and
  generates seeded traffic.
* In a simulation, a monitor backend offers ``vc.on_frame``, ``vc.frames``, ``vc.statistics`` and
  ``vc.error``, a counted check error.
* Every invalid argument raises ``EthernetValueError``, a ``ValueError``.
* ``AwesomeVunitVcsError``, exported from ``awesome_vunit_vcs``, is the base of every error of the
  package: ``EthernetValueError`` and ``FlashError`` derive from it.

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
* ``traffic.parse_arguments`` is removed; ``call_packet_function`` and ``sequence`` take the
  function's arguments as Python arguments. ``random_traffic`` also accepts malformation names
  separated by commas.
* ``MonitorBackend.push`` and ``ProtocolCheckerBackend.push`` take ``(samples, base_time,
  delta_unit)``; ``check_sequence``, ``start_sequence`` and ``function_symbols`` take the function's
  arguments from ``args``/``kwargs`` or ``set_arguments``; ``packet_symbols`` (a Scapy expression) is
  removed.
* ``PropertyRunner`` takes the strategy's arguments as a mapping, or later through ``start``.
* Flash: the flash VC no longer checks the pin timing of the controller by default: the
  ``protocol_checker`` parameter of ``new_flash`` and ``new_qspi_master`` defaults to
  ``null_qspi_protocol_checker``. Pass ``protocol_checker => new_qspi_protocol_checker(...)`` to check
  it. The pin limits ``t_sck_min`` to ``t_chdx`` moved from ``new_flash`` to
  ``new_qspi_protocol_checker``, and the switch that disabled every pin check is gone: leave out the
  protocol checker, or switch single rules off with ``set_check_enabled``. Violations are check
  failures on the checker of the protocol checker, ``<flash id>:protocol_checker`` unless it has an
  id of its own, and their messages start with the check ID, such as ``QSPI_CS_DESELECT``.
* Flash: ``new_flash`` and ``new_qspi_master`` end with ``protocol_checker``, ``id``, ``logger``,
  ``actor``, ``checker`` and ``unexpected_msg_type_policy``, like VUnit's own VCs. ``id`` moved from
  the first to that group.
* Flash: a message of an unknown type is a check failure ``Got unexpected message <type>`` on the
  checker of the VC, as for the Ethernet VCs, instead of a failure on its logger.
* Flash: two flashes with the same id, which would share one Python backend, are a failure on the
  logger of the second, as for the Ethernet VCs.
* Flash: ``set_check_enabled`` and ``get_check_count``, blocking and with a reference, also take a
  flash or a QSPI master and act on the protocol checker it owns.
* Flash: ``set_sck_period`` is answered with ``set_qspi_master_sck_period_reply_msg``, and the names
  of the QSPI master and protocol checker message types are words, such as ``reset qspi master``.
