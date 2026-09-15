RGMII
=====

RGMII carries 10, 100 and 1000 Mbit/s Ethernet on four data pins and one control pin, using both
edges of the clock.

When to use it
--------------

Use the RGMII components when your design has an RGMII port, for example an FPGA MAC connected to a
gigabit PHY.

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`rgmii_source`, :vhdl:`rgmii_monitor`, :vhdl:`rgmii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 1000`` (default), ``100`` or ``10``
   * - Clocking
     - Both edges of ``clk``: 125 MHz at 1000 Mbit/s, 25 MHz at 100 Mbit/s, 2.5 MHz at 10 Mbit/s
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.RGMII``
   * - Tested on
     - GHDL, NVC, at all three rates and with edge aligned data

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor, protocol checker
     - RGMII signal
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``TXC`` / ``RXC``
   * - ``data``
     - ``out std_ulogic_vector(3 downto 0)``
     - ``in std_ulogic_vector(3 downto 0)``
     - ``TD`` / ``RD``
   * - ``ctl``
     - ``out std_ulogic``
     - ``in std_ulogic``
     - ``TX_CTL`` / ``RX_CTL``

Create the components
~~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rgmii
   :end-before: -- docs-end: rgmii
   :dedent:

Match the data timing of your design
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pick ``data_timing`` by how data lines up with the clock on the line you connect to.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - ``data_timing``
     - Use it when
   * - ``rgmii_centered`` (default)
     - Data is stable around every clock edge, like the output of a transmitter with internal delay
       (RGMII-ID). The source changes data between the clock edges.
   * - ``rgmii_edge_aligned``
     - Data changes together with the clock edges, like the output of a DUT that registers its RGMII
       outputs on the clock. The source changes data on the clock edges.

.. code-block:: vhdl
   :caption: A monitor on the edge aligned output of a DUT

   constant monitor : rgmii_monitor_t := new_rgmii_monitor(data_timing => rgmii_edge_aligned,
                                                           protocol_checker => default_rgmii_protocol_checker);

Send and receive frames
~~~~~~~~~~~~~~~~~~~~~~~

Everything else works as on :doc:`gmii`: the same procedures push, check and count frames.

Common options
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Option
     - Meaning
   * - ``link_rate_mbps``
     - 10, 100 or 1000; any other rate is a failure. Give the source and the monitors the same rate.
   * - ``data_timing``
     - ``rgmii_centered`` or ``rgmii_edge_aligned``, see above. Give the monitor and its protocol
       checker the timing of the line they observe.

The other parameters are those of :doc:`gmii`.

Good to know
------------

* At 1000 Mbit/s the lower four bits of an octet are on the rising edge and the upper four bits on the
  falling edge. At 10 and 100 Mbit/s a nibble is sent per clock cycle, least significant nibble first.
* An error sets ``ctl`` low on the falling edge while it is high on the rising edge.
* A monitor created with ``default_rgmii_protocol_checker`` gives it the rate and data timing of the
  monitor.
* Give DUT outputs an initial value, or the protocol checker reports metavalues before the first frame.
* In-band status on the data pins between frames is ignored and never driven.

Related recipes
---------------

* :doc:`../cookbook/beyond_gmii`: *RGMII at 10, 100 or 1000 Mbit/s*, *Run the same test at several rates*

API reference
-------------

* VHDL: :vhdl:`rgmii_pkg.new_rgmii_source`, :vhdl:`rgmii_pkg.new_rgmii_monitor`,
  :vhdl:`rgmii_pkg.new_rgmii_protocol_checker`, :vhdl:`rgmii_pkg.rgmii_data_timing_t`, and the whole
  family in :doc:`vhdl_api`
* Python: :doc:`python_api`
