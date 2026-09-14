Ethernet
========

The Ethernet family verifies designs with MII, GMII and XGMII-family interfaces. Every interface has
the same three verification components (VCs) and shares every procedure, so what you learn for one
interface applies to all of them.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - VC
     - Role
   * - ``<interface>_source``
     - Drives one direction of the interface with the frames a test pushes, including deliberately
       malformed ones.
   * - ``<interface>_monitor``
     - Observes one direction, reconstructs the frames, compares them with expected frames (the
       scoreboard), keeps statistics, publishes frames and writes captures. Never drives.
   * - ``<interface>_protocol_checker``
     - Observes one direction and checks the protocol. A monitor creates one when asked.

What's here
-----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`gmii`, :doc:`xgmii`, :doc:`mii`
     - One page per interface: pins, constructors and options
   * - :doc:`monitors`, :doc:`packets_and_sequences`
     - Receiving and sending frames
   * - :doc:`checks`, :doc:`scoreboard`, :doc:`statistics`, :doc:`captures`
     - What a monitor gives you
   * - :doc:`python`
     - Frames, monitors and subscribers in Python, and your own Hypothesis strategies
   * - :doc:`vhdl_api`
     - Every VHDL package, context and entity of the family
   * - :doc:`python_api`
     - Every public Python name of ``awesome_vunit_vcs.ethernet``

Interfaces
----------

.. list-table::
   :header-rows: 1
   :widths: 15 25 35 25

   * - Interface
     - Link rates
     - Pins
     - Page
   * - MII
     - 10M, 100M
     - ``data(3 downto 0)``, ``dv``, ``er``
     - :doc:`mii`
   * - GMII
     - 1G, 2.5G overclocked
     - ``data(7 downto 0)``, ``dv``, ``er``
     - :doc:`gmii`
   * - XGMII family
     - 2.5G to 400G
     - ``data(8 * lanes - 1 downto 0)``, ``ctrl(lanes - 1 downto 0)``
     - :doc:`xgmii`

RGMII, RMII and an AXI-Stream MAC client interface are on the :doc:`../roadmap`.

The pattern
-----------

.. code-block:: vhdl
   :caption: VHDL

   constant source : gmii_source_t := new_gmii_source;
   constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
   ...
   check_ethernet_frame(net, monitor, frame, blocking => false);  -- expect
   push_ethernet_frame(net, source, frame);                       -- send
   wait_until_idle(net, as_sync(source));
   wait_until_idle(net, as_sync(monitor));                        -- compared by now

``frame`` is the frame data from the destination address up to, not including, the FCS. Python adds
preamble, SFD, padding and FCS on transmit and checks them on receive.

Handles and identity
--------------------

Constructors take the VC configuration first, then the standard VUnit parameters ``id``, ``logger``,
``actor``, ``checker`` and ``unexpected_msg_type_policy``, all with defaults.

* Without an ``id`` a VC is named ``awesome_vunit_vcs:<vc>:<n>``, for example
  ``awesome_vunit_vcs:gmii_monitor:1``. Pass ``id => get_id("tb:rx_monitor")`` to name it after its place
  in the testbench.
* The logger, actor and checker derive from the id unless given explicitly.
* A monitor's protocol checker is named ``<monitor id>:protocol_checker``, so its errors log as, for
  example, ``tb:rx_monitor:protocol_checker``.
* ``get_id``, ``get_logger``, ``get_actor`` and ``get_checker`` return them;
  ``get_protocol_checker(monitor)`` returns a monitor's protocol checker.
* A message a VC does not handle is a check failure unless ``unexpected_msg_type_policy`` is ``ignore``.

Standard interfaces
-------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Function
     - VUnit interface
   * - ``as_sync(vc)``
     - Sync, on every VC: ``wait_until_idle`` and ``wait_for_time``.
   * - ``as_stream(source)``
     - Stream master: ``push_stream`` pushes an octet; the octet with ``last`` ends a frame.
   * - ``as_stream(monitor)``
     - Stream slave: ``pop_stream`` and ``check_stream`` read the octets of received frames.

Procedures
----------

Every procedure takes ``net`` first and has an overload for the handle of each interface. A procedure
that returns a value blocks; it also has a non-blocking form returning an ``ethernet_reference_t``, read
later with the matching ``await_<procedure>_reply``.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Page
   * - ``push_ethernet_frame``, ``frame_options``
     - :doc:`gmii` (sending), :doc:`checks` (malformed frames)
   * - ``push_ethernet_packet``, ``push_ethernet_sequence``, ``check_ethernet_sequence``
     - :doc:`packets_and_sequences`
   * - Creating and using a monitor
     - :doc:`monitors`
   * - ``check_ethernet_frame``, ``pop_ethernet_frame``
     - :doc:`scoreboard`
   * - ``set_check_enabled``, ``get_check_count``
     - :doc:`checks`
   * - ``get_statistics``, ``get_frame_count``, ``log_statistics``
     - :doc:`statistics`
   * - ``start_capture``, ``stop_capture``
     - :doc:`captures`
   * - ``reset``
     - Below

Recover a component with ``reset(net, vc)``. It works even while the clock is stopped:

.. list-table::
   :widths: 25 75

   * - Source
     - Drops queued frames and stops the frame in progress.
   * - Monitor
     - Forgets the frame in progress, waiting pops and expected frames. Keeps statistics unless
       ``clear_statistics => true``.
   * - Protocol checker
     - Forgets the frame in progress and keeps its counts.

Every declaration is listed in the :doc:`vhdl_api`.

.. toctree::
   :maxdepth: 1
   :hidden:

   monitors
   gmii
   xgmii
   mii
   checks
   scoreboard
   statistics
   captures
   packets_and_sequences
   python
   vhdl_api
   python_api
