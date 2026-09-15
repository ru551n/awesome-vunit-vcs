Monitors
========

A :term:`monitor` watches one direction of an interface and never drives it. It rebuilds the frames,
compares them with the frames you expect, keeps statistics and writes captures. The procedures are the
same on every interface; the examples use GMII.

Create a monitor
----------------

A monitor is a handle from ``new_<interface>_monitor`` plus an entity that takes the handle as its only
generic. Every parameter has a default, so ``new_gmii_monitor`` alone gives a 1G monitor without
protocol checks.

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :start-after: -- docs-start: monitors
   :end-before: -- docs-end: monitors
   :dedent: 2

The entity connects the handle to the pins it observes:

.. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
   :caption: examples/gmii/tb_gmii_example.vhd
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

:doc:`gmii`, :doc:`mii` and :doc:`xgmii` list the parameters of each interface.

The protocol checker a monitor creates is named after the monitor. The checks of
``tb_gmii_example:input_monitor`` log as ``tb_gmii_example:input_monitor:protocol_checker``.

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

Call ``wait_until_idle`` on the sources and then the monitors before ``test_runner_cleanup``. Then the
last frame has been received and compared.

Subscribe to frames
-------------------

While a monitor has subscribers, it publishes every frame it receives as an ``ethernet_frame_msg``:

.. literalinclude:: ../../tests/vhdl/tb_gmii_vci.vhd
   :caption: tests/vhdl/tb_gmii_vci.vhd
   :language: vhdl
   :start-after: -- docs-start: subscribe
   :end-before: -- docs-end: subscribe
   :dedent: 8

Use several monitors
--------------------

Give each monitor its own handle and entity. The usual setup is a monitor on each side of the design:
the input monitor shows what reached the design, and the output monitor checks what it produced. See
``examples/gmii``.

Monitors of different interfaces, such as an MII input and a GMII output, work the same way and never
share state.

Related recipes
---------------

* :doc:`../cookbook/first_test`: *Create a source and a monitor*

API reference
-------------

:vhdl:`gmii_pkg.new_gmii_monitor`, :vhdl:`mii_pkg.new_mii_monitor`, :vhdl:`xgmii_pkg.new_xgmii_monitor`,
and the procedures in the table above in :doc:`vhdl_api`
