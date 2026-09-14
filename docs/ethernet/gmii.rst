GMII
====

GMII carries 1 Gbit/s Ethernet, one octet per clock cycle, and is the reference implementation of the
family. The components also cover the overclocked 2.5 Gbit/s GMII some FPGA MACs use.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`gmii_source`, :vhdl:`gmii_monitor`, :vhdl:`gmii_protocol_checker`
   * - Constructors
     - :vhdl:`gmii_pkg.new_gmii_source`, :vhdl:`gmii_pkg.new_gmii_monitor`,
       :vhdl:`gmii_pkg.new_gmii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 1000`` (default) or ``2500``
   * - Clocking
     - Rising edge of ``clk``, one octet per cycle
   * - Python decoder
     - ``awesome_vunit_vcs.ethernet.GMII``
   * - Tested on
     - GHDL, NVC

Pins
----

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor, protocol checker
     - GMII signal
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``GTX_CLK`` / ``RX_CLK``
   * - ``data``
     - ``out std_ulogic_vector(7 downto 0)``
     - ``in std_ulogic_vector(7 downto 0)``
     - ``TXD`` / ``RXD``
   * - ``dv``
     - ``out std_ulogic``
     - ``in std_ulogic``
     - ``TX_EN`` / ``RX_DV``
   * - ``er``
     - ``out std_ulogic``
     - ``in std_ulogic := '0'``
     - ``TX_ER`` / ``RX_ER``

The handle is the only generic. Source outputs are ``'0'`` between frames.

Constructors
------------

.. code-block:: vhdl

   constant source : gmii_source_t := new_gmii_source;
   constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
   constant checker : gmii_protocol_checker_t := new_gmii_protocol_checker(max_frame_octets => 9018);

.. list-table::
   :header-rows: 1
   :widths: 30 20 50

   * - Parameter
     - Default
     - Meaning
   * - ``link_rate_mbps``
     - 1000
     - Used for utilization and IFG measurement; timing comes from the simulation.
   * - ``has_fcs``
     - true
     - False for frames observed without an FCS.
   * - ``min_frame_octets`` (monitor)
     - 64
     - The size a transmitter pads to, which ``check_ethernet_frame`` accepts.
   * - ``protocol_checker`` (monitor)
     - none
     - ``default_gmii_protocol_checker``, or a handle from ``new_gmii_protocol_checker``.
   * - ``min_preamble_octets``, ``max_preamble_octets``
     - 7, 7
     - Protocol checker limits.
   * - ``min_frame_octets``, ``max_frame_octets`` (protocol checker)
     - 64, 1518
     - Frame size limits; a maximum of 0 disables it.
   * - ``min_ifg_octets``
     - 12
     - Minimum gap between frames.
   * - ``batch_length``, ``flush_at_frame_end``, ``delta_unit``
     - 4096, true, 1 ps
     - Batching to Python; the defaults suit almost every test.
   * - ``log_frames`` (monitor)
     - false
     - Log every received frame at debug level.
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     - derived
     - See :doc:`index`.

The generated reference lists every parameter with its type: :vhdl:`gmii_pkg.new_gmii_monitor`.

Sending
-------

The source transmits frames in the order they are pushed, one octet per rising edge, with the IFG
of each frame after it.

.. code-block:: vhdl

   push_ethernet_frame(net, source, frame);                                   -- frame data
   push_ethernet_frame(net, source, x"020000000001", x"020000000002", x"0800", payload);
   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));     -- malformed

``frame_options`` and the checks they trigger are on :doc:`checks`; Python-generated traffic is on
:doc:`packets_and_sequences`.

Receiving
---------

The monitor samples ``data``, ``dv`` and ``er`` on every rising edge. A sample is recorded while ``dv``
is asserted or when the pins change, so a long idle period costs one sample and gaps keep their exact
timing. Samples reach Python in batches and at the end of every frame. Python reconstructs the frames,
runs the scoreboard, updates statistics and writes captures.

Metavalues (``U``, ``X``, ``Z``, ``W``, ``-``) on ``data`` while ``dv`` is asserted, or on ``dv`` and ``er``,
are ``ETH_METAVALUE`` violations rather than being read as ``'0'``. Give the outputs of a design without
reset an initial value.

Example
-------

``examples/gmii`` verifies a register pipeline with a source on its input and a monitor with a protocol
checker on each side. Its tests cover seeded random frames through the scoreboard with a PCAPNG
capture, a deliberate FCS error counted instead of failing, a Python subscriber added to a monitor, and
a Scapy packet. CI runs it on GHDL and NVC:

.. code-block:: bash

   python examples/gmii/run.py

.. dropdown:: tb_gmii_example.vhd

   .. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
      :language: vhdl
      :start-after: http://mozilla.org/MPL/2.0/.

.. dropdown:: run.py

   .. literalinclude:: ../../examples/gmii/run.py
      :language: python
      :start-after: http://mozilla.org/MPL/2.0/.

.. dropdown:: The design under test, gmii_pipeline.vhd

   .. literalinclude:: ../../examples/gmii/src/gmii_pipeline.vhd
      :language: vhdl
      :start-after: http://mozilla.org/MPL/2.0/.

``tests/vhdl/tb_gmii.vhd`` covers every check, two monitors on one line, captures, packets, sequences
and randomized traffic; ``tests/vhdl/tb_gmii_vci.vhd`` covers the VUnit conventions.

Limitations
-----------

None beyond those of every Ethernet component; see :doc:`../explanation/limitations`.
