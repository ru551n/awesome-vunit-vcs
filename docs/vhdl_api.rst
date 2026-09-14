VHDL API
========

The Ethernet verification components (VCs) follow the conventions of VUnit's own VCs, in particular
``axi_stream_pkg`` and ``vc_pkg``: one handle type per VC created by a ``new_*`` function, the handle
as the only generic of the entity, logging through VUnit loggers and checkers, communication
through ``com`` and the standard VUnit verification component interfaces (VCIs). This page
describes how the API fits together; the :doc:`reference/vhdl/index` lists every declaration.

One context clause makes everything visible, VUnit included:

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

The context covers ``ieee.std_logic_1164``, VUnit's ``vunit_context`` and ``com_context``,
``sync_pkg``, ``stream_master_pkg``, ``stream_slave_pkg``, ``integer_array_pkg``, ``vc_pkg`` and the
Ethernet packages ``ethernet_pkg``, ``gmii_pkg``, ``mii_pkg`` and ``xgmii_pkg``.

The short path
--------------

A source in front of the design, a monitor with the default protocol checks behind it, a scoreboard
and statistics:

.. code-block:: vhdl

   constant source : gmii_source_t := new_gmii_source;
   constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
   ...
   for idx in 1 to 20 loop
     check_ethernet_frame(net, monitor, frame(idx), blocking => false);
     push_ethernet_frame(net, source, frame(idx));
   end loop;
   wait_until_idle(net, as_sync(source));
   wait_until_idle(net, as_sync(monitor));
   get_statistics(net, monitor, statistics);
   check_equal(statistics.good_frames, 20);

with ``gmii_source`` and ``gmii_monitor`` instances whose generic is the handle. ``frame(idx)`` is the
frame from the destination address up to, not including, the FCS; the source adds preamble, SFD,
padding and FCS.

Components and handles
----------------------

Every interface (``gmii``, ``mii``, ``xgmii``) has three VCs, each an entity with a handle type of its
own:

.. list-table::
   :header-rows: 1
   :widths: 22 26 52

   * - Entity
     - Handle and constructor
     - Role
   * - ``<interface>_source``
     - ``<interface>_source_t``, ``new_<interface>_source``
     - Drives one direction of the interface with the frames a test pushes.
   * - ``<interface>_monitor``
     - ``<interface>_monitor_t``, ``new_<interface>_monitor``
     - Observes one direction, reconstructs the frames, keeps statistics, runs the scoreboard,
       publishes frames and writes captures.
   * - ``<interface>_protocol_checker``
     - ``<interface>_protocol_checker_t``, ``new_<interface>_protocol_checker``
     - Observes one direction and checks the protocol. A monitor instantiates one when its handle
       has one.

Constructors take the VC configuration first (such as ``link_rate_mbps`` or XGMII ``lanes``), then
the standard parameters ``id``, ``logger``, ``actor``, ``checker`` and
``unexpected_msg_type_policy``. Every parameter has a default, so ``new_gmii_source`` alone creates a
source.

Identity
~~~~~~~~

The standard parameters are resolved like ``vc_pkg.create_std_cfg`` of VUnit:

* A null ``id`` becomes ``awesome_vunit_vcs:<vc name>:<n>``, for example
  ``awesome_vunit_vcs:gmii_monitor:1``. Pass ``id => get_id("tb:rx_monitor")`` to name a VC after its
  place in the testbench.
* A null ``logger`` is the logger of the id, a null ``actor`` a new actor of the id (an id that
  already has an actor is an error), and a null ``checker`` a new checker reporting to the logger.
* A protocol checker given to ``new_<interface>_monitor`` gets the id
  ``<monitor id>:protocol_checker``, and its logger, actor and checker derive from that id unless
  they were given explicitly. Violations then log as, for example,
  ``tb:rx_monitor:protocol_checker``.
* ``get_id``, ``get_logger``, ``get_actor`` and ``get_checker`` return them. The Python backend of a VC
  is the object ``vc`` in the Python session of its id.
* A message a VC does not handle is a check failure, ``Got unexpected message <name>``, unless
  ``unexpected_msg_type_policy`` is ``ignore``.

Interfaces
~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Function
     - Interface
   * - ``as_sync(vc)``
     - VUnit's synchronization VCI for every VC: ``wait_until_idle`` and ``wait_for_time``.
   * - ``as_stream(source)``
     - VUnit's stream master VCI: ``push_stream`` pushes one octet, and the octet with ``last`` ends a
       frame, transmitted with ``default_frame_options``.
   * - ``as_stream(monitor)``
     - VUnit's stream slave VCI: ``pop_stream`` and ``check_stream`` read the octets of received
       frames, ``last`` with the last octet of a frame.
   * - ``as_ethernet_source``, ``as_ethernet_monitor``, ``as_ethernet_protocol_checker``
     - The interface independent Ethernet VCIs of ``ethernet_pkg``. Every procedure below also has an
       overload taking the handle of each interface, so a testbench seldom needs these.
   * - ``get_protocol_checker(monitor)``
     - The protocol checker of a monitor, ``null_<interface>_protocol_checker`` when it has none.
   * - ``data_length``, ``ctrl_length``, ``lanes``
     - The port widths; entities size their ports with them.

Procedures
----------

All procedures take ``signal net : inout network_t`` first, like every ``com`` procedure. A procedure
that returns a value blocks; it also has a non-blocking overload returning an
``ethernet_reference_t``, read later with the matching ``await_<procedure>_reply``.

Source
~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Procedure
     - Effect
   * - ``push_ethernet_frame(net, source, data [, options])``
     - Transmit a frame given from the destination address up to, not including, the FCS.
   * - ``push_ethernet_frame(net, source, destination, source_address, ethertype, payload [, options])``
     - Transmit a frame given by its header fields and payload.
   * - ``push_ethernet_packet(net, source, "module:function", "key=value, ..." [, options])``
     - Transmit the frame a Python function returns, for example a Scapy packet. Arguments are
       Python literals, parsed and never evaluated.
   * - ``push_ethernet_sequence(net, source, "module:function", arguments, count, seed)``
     - Transmit the frames a Python generator yields, fetched in batches. The same function,
       arguments and seed produce the same frames.
   * - ``push_xgmii_columns``, ``push_xgmii_link_fault``
     - XGMII only: raw columns, and Sequence ordered sets of a link fault.
   * - ``reset(net, source)``
     - Drop queued frames, abort a frame in progress at a symbol boundary and forget octets pushed
       without ``last``. Returns also while the clock is stopped.

``frame_options(...)`` describes how a frame is transmitted, including traffic the standard forbids:

.. code-block:: vhdl

   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));             -- inverted FCS
   push_ethernet_frame(net, source, frame, frame_options(pad => false));               -- a runt
   push_ethernet_frame(net, source, frame, frame_options(preamble_octets => 5));       -- short preamble
   push_ethernet_frame(net, source, frame, frame_options(sfd => x"D4"));               -- wrong SFD
   push_ethernet_frame(net, source, frame, frame_options(error_offsets => (0 => 20))); -- error signal
   push_ethernet_frame(net, source, frame, frame_options(ifg_octets => 8));            -- short IFG

Error offsets count from the first octet after the SFD; negative offsets reach into the SFD and the
preamble. Interfaces with control characters transmit the Error character instead.

Monitor
~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Procedure
     - Effect
   * - ``check_ethernet_frame(net, monitor, expected [, msg, blocking])``
     - Check that the next received frame is ``expected``; a difference is an ``ETH_SCOREBOARD``
       check failure on the checker of the monitor. Blocking returns when the frame is checked.
   * - ``check_ethernet_sequence(net, monitor, "module:function", arguments, count, seed)``
     - Check the next frames against the frames of a Python generator, for example those of a
       ``push_ethernet_sequence`` with the same function, arguments and seed.
   * - ``pop_ethernet_frame(net, monitor, data, length [, fcs_ok])``
     - Wait for the next received frame and read it.
   * - ``get_statistics``, ``get_frame_count``, ``log_statistics``
     - Statistics of the frames received so far.
   * - ``start_capture``, ``stop_capture``
     - Write the received frames to a PCAPNG file for Wireshark.
   * - ``reset(net, monitor [, clear_statistics])``
     - Forget a frame in progress and ignore its rest on the line, and forget kept frames and
       expected frames. Statistics are kept unless ``clear_statistics``.

A monitor publishes every frame it receives while it has subscribers as an ``ethernet_frame_msg``;
a subscriber reads it with ``pop_ethernet_frame(msg, data, length, fcs_ok)``. Frames are kept for
pops only while a pop is pending.

Protocol checker
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Procedure
     - Effect
   * - ``set_check_enabled(net, protocol_checker, check, enabled)``
     - Enable or disable one check.
   * - ``get_check_count(net, protocol_checker, check, count)``
     - Violations a check found while enabled.
   * - ``reset(net, protocol_checker)``
     - Forget a frame in progress and ignore its rest on the line; counts are kept.

``wait_until_idle(net, as_sync(vc))`` returns when a source has transmitted everything pushed
before it, and when a monitor or protocol checker has no frame in progress, no pending pop or
blocking check, and Python has processed everything sampled so far.

Types
-----

``ethernet_fcs_mode_t`` is what a source appends to the frame data: ``fcs_append`` (padding and the
correct FCS), ``fcs_bad`` (padding and the inverted FCS) or ``fcs_none`` (nothing).

``ethernet_frame_options_t`` holds the options of a frame. Create it with ``frame_options``, whose
defaults are a frame the standard allows; ``default_frame_options`` is the same value.

``ethernet_statistics_t`` has ``total_frames``, ``good_frames``, ``bad_frames``, ``wire_octets``,
``payload_octets``, ``fcs_errors``, ``phy_error_frames``, ``runts``, ``giants``,
``min_frame_octets``, ``max_frame_octets``, ``min_ifg_octets`` and ``max_ifg_octets``. Octet counts
saturate at ``integer'high``; a minimum or maximum without a value is -1.

Checks
------

``ethernet_check_t`` names the checks of the Python checker; the log message of a violation starts
with the check ID in upper case, for example ``ETH_FCS: bad FCS on frame 27``. A protocol checker
runs the protocol checks, all enabled by default; a monitor runs ``eth_scoreboard``. A maximum limit
of 0 in ``new_<interface>_protocol_checker`` disables that limit.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Check
     - Violation
   * - ``eth_preamble``
     - Preamble length outside ``min_preamble_octets`` .. ``max_preamble_octets``, or a malformed
       preamble octet.
   * - ``eth_sfd``
     - No SFD after the preamble.
   * - ``eth_fcs``
     - The FCS does not match the frame.
   * - ``eth_runt``
     - A frame shorter than ``min_frame_octets``.
   * - ``eth_giant``
     - A frame longer than ``max_frame_octets``.
   * - ``eth_phy_error``
     - The error signal asserted during a frame.
   * - ``eth_carrier``
     - The error signal asserted outside a frame.
   * - ``eth_ifg``
     - An inter-frame gap shorter than ``min_ifg_octets``.
   * - ``eth_termination``
     - A frame that ended with an incomplete octet, or without Terminate (XGMII).
   * - ``eth_metavalue``
     - A metavalue on the data during a frame, or on the valid or error signal.
   * - ``eth_frame_state``
     - A frame already in progress when monitoring started, or still in progress when it ended.
   * - ``eth_control``
     - An invalid or misplaced control character (XGMII family).
   * - ``eth_link_fault``
     - A local or remote fault ordered set (XGMII family).
   * - ``eth_scoreboard``
     - A frame that differs from the one ``check_ethernet_frame`` expected, or expected frames not
       received before the simulation ends (monitor).
   * - ``eth_user``
     - An error Python code in the session of a VC reported with ``vc.error``.

Entities
--------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Entity
     - Ports
   * - ``gmii_source``, ``gmii_monitor``, ``gmii_protocol_checker``
     - ``clk``, ``data(7 downto 0)``, ``dv``, ``er``: ``TX_CLK``/``RX_CLK``, ``TXD``/``RXD``,
       ``TX_EN``/``RX_DV``, ``TX_ER``/``RX_ER``, on the rising edge.
   * - ``mii_source``, ``mii_monitor``, ``mii_protocol_checker``
     - The same with ``data(3 downto 0)``. ``CRS`` and ``COL`` of half duplex are not supported.
   * - ``xgmii_source``, ``xgmii_monitor``, ``xgmii_protocol_checker``
     - ``clk``, ``data(data_length(vc) - 1 downto 0)``, ``ctrl(ctrl_length(vc) - 1 downto 0)``, lane 0 in
       the low bits, on the rising edge or on both edges.

Monitors and protocol checkers only read their ports. Source outputs are ``'0'`` between frames
(GMII, MII) or Idle columns (XGMII).

Python extras
-------------

A test never needs Python, but the backend of a VC is the object ``vc`` in the Python session of its
id, reachable with the bridge's context (``library python_bridge; context python_bridge.python_context;``):

.. code-block:: vhdl

   check_equal(eval_integer("vc.last_packet()['UDP'].dport", new_session(get_id(monitor))), 1234);

The backend classes are documented in :doc:`python_api`. The changes from the earlier API are listed
in :doc:`release_notes/index`.
