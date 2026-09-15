GMII
====

GMII carries 1 Gbit/s Ethernet, one octet per clock cycle. The components also cover the overclocked
2.5 Gbit/s GMII that some FPGA MACs use.

When to use it
--------------

Use the GMII components when your design has a GMII port, or a GMII-like port with one octet, a valid
and an error signal per clock cycle.

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`gmii_source`, :vhdl:`gmii_monitor`, :vhdl:`gmii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 1000`` (default) or ``2500``
   * - Clocking
     - Rising edge of ``clk``, one octet per cycle
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.GMII``
   * - Tested on
     - GHDL, NVC

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

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

The handle is the only generic of each entity.

Create the components
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: vhdl
   :caption: Handles in the testbench architecture

   constant source : gmii_source_t := new_gmii_source;
   constant monitor : gmii_monitor_t :=
     new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
   constant checker : gmii_protocol_checker_t := new_gmii_protocol_checker(max_frame_octets => 9018);

Every parameter has a default. Pass ``protocol_checker`` to a monitor to get the protocol checks.

Some names in the examples on these pages come from VUnit, not from this package: ``net``,
``as_sync`` and ``wait_until_idle`` from the `com library <https://vunit.github.io/com/user_guide.html>`_;
``get_id``, ``disable_stop``, ``get_log_count`` and ``reset_log_count`` from the
`logging library <https://vunit.github.io/logging/user_guide.html>`_; and ``integer_array_t`` from the
`data types <https://vunit.github.io/data_types/user_guide.html>`_. ``ethernet_context`` makes them
all visible.

Send frames
~~~~~~~~~~~

.. code-block:: vhdl
   :caption: Sending frames

   push_ethernet_frame(net, source, frame);                                   -- frame data
   push_ethernet_frame(net, source, x"020000000001", x"020000000002", x"0800", payload);
   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));     -- malformed

The source sends frames in the order you push them. ``frame`` is the :term:`frame data`; the source
adds preamble, SFD, padding and FCS. See :vhdl:`ethernet_pkg.push_ethernet_frame`.

Receive frames
~~~~~~~~~~~~~~

The monitor reads ``data``, ``dv`` and ``er`` on every rising edge. Use it as :doc:`monitors` shows:
compare frames with the :doc:`scoreboard`, count errors with :doc:`checks`, or read :doc:`statistics`.

See a complete example
~~~~~~~~~~~~~~~~~~~~~~

``examples/gmii`` verifies a register pipeline. A source drives its input, and a monitor with a protocol
checker watches each side. Its tests cover random frames with a capture, a counted FCS error, a Python
subscriber and a Scapy packet.

.. code-block:: bash
   :caption: Terminal

   python examples/gmii/run.py

.. dropdown:: tb_gmii_example.vhd

   .. literalinclude:: ../../examples/gmii/tb_gmii_example.vhd
      :caption: examples/gmii/tb_gmii_example.vhd
      :language: vhdl
      :start-after: http://mozilla.org/MPL/2.0/.

.. dropdown:: run.py

   .. literalinclude:: ../../examples/gmii/run.py
      :caption: examples/gmii/run.py
      :language: python
      :start-after: http://mozilla.org/MPL/2.0/.

.. dropdown:: The design under test, gmii_pipeline.vhd

   .. literalinclude:: ../../examples/gmii/src/gmii_pipeline.vhd
      :caption: examples/gmii/src/gmii_pipeline.vhd
      :language: vhdl
      :start-after: http://mozilla.org/MPL/2.0/.

Common options
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 20 50

   * - Parameter
     - Default
     - Meaning
   * - ``link_rate_mbps``
     - 1000
     - The rate of the link, for utilization and gap measurement.
   * - ``has_fcs``
     - true
     - False when frames on this line have no FCS.
   * - ``min_frame_octets`` (monitor)
     - 64
     - The size a transmitter pads to. ``check_ethernet_frame`` accepts padded frames.
   * - ``protocol_checker`` (monitor)
     - none
     - ``default_gmii_protocol_checker``, or a handle from ``new_gmii_protocol_checker``.
   * - ``min_preamble_octets``, ``max_preamble_octets``
     - 7, 7
     - Protocol checker limits.
   * - ``min_frame_octets``, ``max_frame_octets`` (protocol checker)
     - 64, 1518
     - Frame size limits. A maximum of 0 turns the limit off.
   * - ``min_ifg_octets``
     - 12
     - Minimum gap between frames.
   * - ``batch_length``, ``flush_at_frame_end``, ``delta_unit``
     - 4096, true, 1 ps
     - Keep the defaults unless a test needs something special.
   * - ``log_frames`` (monitor)
     - false
     - Log every received frame at debug level.
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     - derived
     - See :doc:`index`.

Good to know
------------

* Source outputs are ``'0'`` between frames.
* Give the outputs of a design without reset an initial value. Otherwise the protocol checker reports
  ``ETH_METAVALUE`` for the undefined values.
* Metavalues on ``data`` while ``dv`` is high, or on ``dv`` and ``er``, are reported, not read as
  ``'0'``.

Related recipes
---------------

* :doc:`../cookbook/first_test`: *Send a frame and check it*
* :doc:`../cookbook/error_handling`: *Send a malformed frame*
* :doc:`../cookbook/first_test`: *Put monitors on both sides of the DUT*

API reference
-------------

* VHDL: :vhdl:`gmii_pkg.new_gmii_source`, :vhdl:`gmii_pkg.new_gmii_monitor`,
  :vhdl:`gmii_pkg.new_gmii_protocol_checker`, and the whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
