Monitors
========

A monitor observes one direction of an interface. It reconstructs the frames, compares them with the
frames a test expects, keeps statistics, publishes frames and writes captures, and it never drives the
line. This page shows how to create one and what to do with it. The procedures are the same on every
interface; the examples use GMII.

Creating a monitor
------------------

A monitor is a handle created with ``new_<interface>_monitor`` and an entity that takes the handle as its
only generic. Every constructor parameter has a default, so ``new_gmii_monitor`` alone gives a 1G monitor
without protocol checks. From ``examples/gmii/tb_gmii_example.vhd``:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitors
   :end-before: -- docs-end: monitors
   :dedent: 2

The entity connects the handle to the pins it observes:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitor-instance
   :end-before: -- docs-end: monitor-instance
   :dedent: 2

The parameters used most:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Parameter
     - Use
   * - ``protocol_checker``
     - ``null_gmii_protocol_checker`` (the default): no protocol checks.
       ``default_gmii_protocol_checker``: the standard checks.
       ``new_gmii_protocol_checker(...)``: checks with your own limits, such as ``max_frame_octets``.
   * - ``id``
     - The name in logs, for example ``get_id("tb:rx_monitor")``. Without it the monitor is
       ``awesome_vunit_vcs:gmii_monitor:<n>``.
   * - ``link_rate_mbps``
     - The rate of the link, used for gaps, rates and utilization. Must match the clock.
   * - ``has_fcs``, ``min_frame_octets``
     - What a frame on this line looks like.
   * - ``log_frames``
     - Log every received frame on the monitor's logger.

Every parameter is listed in the :doc:`vhdl_api`; :doc:`gmii`, :doc:`mii`
and :doc:`xgmii` list the parameters of each interface.

The protocol checker a monitor creates is named after the monitor: the checks of
``tb_gmii_example:input_monitor`` log as ``tb_gmii_example:input_monitor:protocol_checker``, and its
logger, actor and checker derive from that id.

What a monitor gives you
------------------------

.. list-table::
   :header-rows: 1
   :widths: 25 45 30

   * - Task
     - Procedures
     - Page
   * - Check the protocol
     - ``set_check_enabled(net, monitor, check, enabled)``, ``get_check_count(net, monitor, check, count)``
     - :doc:`checks`
   * - Compare with expected frames
     - ``check_ethernet_frame`` (blocking or not), ``check_ethernet_sequence``
     - :doc:`scoreboard`
   * - Read frames in the testbench
     - ``pop_ethernet_frame``, or ``pop_stream(net, as_stream(monitor), octet, last)``
     - :doc:`scoreboard`
   * - Get every frame as a message
     - ``subscribe(actor, get_actor(monitor))``, then ``ethernet_frame_msg``
     - Below
   * - Statistics
     - ``get_statistics``, ``get_frame_count``, ``log_statistics``
     - :doc:`statistics`
   * - Wireshark captures
     - ``start_capture``, ``stop_capture``
     - :doc:`captures`
   * - React in Python
     - ``vc.on_frame``, ``vc.error`` in the monitor's Python session
     - :ref:`python-monitors-in-simulation`
   * - Wait and recover
     - ``wait_until_idle(net, as_sync(monitor))``, ``reset(net, monitor)``
     - :doc:`index`

Call ``wait_until_idle`` on the sources and then the monitors before ``test_runner_cleanup``, so the
last frame has been received and compared.

Subscribing to frames
---------------------

While a monitor has subscribers it publishes every frame it receives as an ``ethernet_frame_msg``.
From ``tests/vhdl/tb_gmii_vci.vhd``:

.. literalinclude:: ../../tests/vhdl/tb_gmii_vci.vhd
   :language: vhdl
   :start-after: -- docs-start: subscribe
   :end-before: -- docs-end: subscribe
   :dedent: 8

Several monitors
----------------

Give each monitor its own handle and entity. Monitors on both sides of a design are the usual setup:
the input monitor proves what reached the design, and the output monitor checks what it produced, as in
``examples/gmii``. Monitors of different interfaces, for example an MII input and a GMII output, are
independent in the same way; each has its own Python session, so they never share state.
