AXI-Stream MAC client
=====================

The AXI-Stream MAC client components carry frames the way a MAC core hands them to your design: one
AXI-Stream packet per frame, starting at the destination address, without preamble or SFD.

When to use it
--------------

Use them when your design sends or receives Ethernet frames on an AXI-Stream interface, such as the
client side of an FPGA MAC or a packet processing pipeline.

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`axis_mac_source`, :vhdl:`axis_mac_sink`, :vhdl:`axis_mac_monitor`,
       :vhdl:`axis_mac_protocol_checker`
   * - Data width
     - ``bytes_per_beat => 8`` (default), any width
   * - Clocking
     - Rising edge of ``clk``; a beat moves when ``tvalid`` and ``tready`` are high
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.AXIS``
   * - Tested on
     - GHDL, NVC, at 1, 4 and 8 octets per beat, with and without backpressure

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor, protocol checker
     - Sink
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``in std_ulogic``
   * - ``tdata``
     - ``out``, ``data_length(source)`` bits
     - ``in``, ``data_length(monitor)`` bits
     -
   * - ``tkeep``
     - ``out``, ``keep_length(source)`` bits
     - ``in``, all ones when left open
     -
   * - ``tvalid``
     - ``out std_ulogic``
     - ``in std_ulogic``
     -
   * - ``tready``
     - ``in std_ulogic := '1'``
     - ``in std_ulogic := '1'``
     - ``out std_ulogic``
   * - ``tlast``
     - ``out std_ulogic``
     - ``in std_ulogic``
     -
   * - ``tuser``
     - ``out``, ``user_length(source)`` bits
     - ``in``, zeros when left open
     -

``tuser(0)`` together with ``tlast`` marks a frame as errored. Size your signals with
``data_length``, ``keep_length`` and ``user_length`` instead of numbers.

Create the components
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: vhdl
   :caption: A source, a sink with backpressure and a monitor

   constant source : axis_mac_source_t := new_axis_mac_source(bytes_per_beat => 8);
   constant sink : axis_mac_sink_t := new_axis_mac_sink(ready_high_percent => 70);
   constant monitor : axis_mac_monitor_t := new_axis_mac_monitor(
     bytes_per_beat => 8, protocol_checker => default_axis_mac_protocol_checker
   );

   signal tdata : std_ulogic_vector(data_length(source) - 1 downto 0);
   signal tkeep : std_ulogic_vector(keep_length(source) - 1 downto 0);
   signal tvalid, tready, tlast : std_ulogic;
   signal tuser : std_ulogic_vector(user_length(source) - 1 downto 0);

Connect the source to your design's input, and the sink and the monitor to its output. The monitor
only observes, so it needs the same ``tready`` as the sink.

Send and receive frames
~~~~~~~~~~~~~~~~~~~~~~~

Everything else works as on :doc:`gmii`: ``push_ethernet_frame``, ``check_ethernet_frame``,
sequences, statistics, captures and reset. Frame data starts at the destination address in every
procedure, on this interface as on the others.

Common options
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 20 50

   * - Option
     - Default
     - Use it to
   * - ``bytes_per_beat``
     - ``8``
     - Match the width of ``tkeep``. Give every component on a bus the same value.
   * - ``user_length``
     - ``1``
     - Match the width of ``tuser``.
   * - ``has_fcs``
     - ``true``
     - Set ``false`` when frames on the bus have no FCS. Source, monitor and protocol checker must agree.
   * - ``valid_low_percent``, ``seed``
     - ``0``, ``0``
     - Let the source insert clocks with ``tvalid`` low inside frames.
   * - ``ready_high_percent``, ``seed``
     - ``100``, ``0``
     - Let the sink apply backpressure. Change it during a test with ``set_ready_pattern``.
   * - ``min_frame_octets``, ``max_frame_octets``
     - ``64``, ``1518``
     - Set the protocol checker's frame limits.

Good to know
------------

* The checks are ``eth_fcs``, ``eth_runt``, ``eth_giant``, ``eth_phy_error`` and ``eth_metavalue``,
  plus three AXI-Stream rules: ``eth_keep``, ``eth_stable`` and ``eth_valid`` (see :doc:`checks`).
* There is no preamble, SFD or gap on this interface, so ``frame_options`` for those have no effect.
  ``ifg_octets`` becomes idle clocks between frames.
* Reset the source before the monitors. A source that is reset keeps ``tvalid`` low for a clock, so
  the monitors see the abandoned frame end.
* For full AMBA AXI4-Stream protocol coverage (``tid``, ``tdest``, ``tstrb``), add VUnit's
  ``axi_stream_protocol_checker`` on the same bus.

Related recipes
---------------

* :doc:`../cookbook/interfaces`: *Use an AXI-Stream MAC client with backpressure*
* :doc:`../cookbook/properties`: *Fuzz backpressure on an AXI-Stream bus*

API reference
-------------

* VHDL: :vhdl:`axis_mac_pkg.new_axis_mac_source`, :vhdl:`axis_mac_pkg.new_axis_mac_sink`,
  :vhdl:`axis_mac_pkg.new_axis_mac_monitor`, :vhdl:`axis_mac_pkg.new_axis_mac_protocol_checker`, and
  the whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
