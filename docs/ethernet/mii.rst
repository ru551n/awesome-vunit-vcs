MII
===

MII carries 10 and 100 Mbit/s Ethernet, one nibble per clock cycle.

When to use it
--------------

Use the MII components when your design has a 10 or 100 Mbit/s MII port.

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`mii_source`, :vhdl:`mii_monitor`, :vhdl:`mii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 100`` (default) or ``10``
   * - Clocking
     - Rising edge of ``clk``: 25 MHz at 100 Mbit/s, 2.5 MHz at 10 Mbit/s
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.MII``
   * - Tested on
     - GHDL, NVC, at both rates

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor, protocol checker
     - MII signal
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``TX_CLK`` / ``RX_CLK``
   * - ``data``
     - ``out std_ulogic_vector(3 downto 0)``
     - ``in std_ulogic_vector(3 downto 0)``
     - ``TXD`` / ``RXD``
   * - ``dv``
     - ``out std_ulogic``
     - ``in std_ulogic``
     - ``TX_EN`` / ``RX_DV``
   * - ``er``
     - ``out std_ulogic``
     - ``in std_ulogic := '0'``
     - ``TX_ER`` / ``RX_ER``

Create the components
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: vhdl
   :caption: A 10 Mbit/s source and monitor

   constant source : mii_source_t := new_mii_source(link_rate_mbps => 10);
   constant monitor : mii_monitor_t := new_mii_monitor(link_rate_mbps => 10,
                                                       protocol_checker => default_mii_protocol_checker);

Send and receive frames
~~~~~~~~~~~~~~~~~~~~~~~

Everything else works as on :doc:`gmii`. The :doc:`../getting_started/quickstart` works for MII if you
replace ``gmii`` with ``mii``, the data width with 4 and the clock period with 40 ns.

Common options
--------------

The parameters of :doc:`gmii` apply. ``link_rate_mbps`` must be 10 or 100; any other rate is a failure.

Good to know
------------

* Nibbles are sent least significant nibble first.
* An odd number of preamble nibbles is fine: 15 nibbles count as 7 preamble octets.
* A frame that ends with half an octet is reported as ``ETH_TERMINATION``, and its FCS fails too.
* The source always sends whole octets. To test a half octet, drive the pins directly.
* ``CRS`` and ``COL`` (half duplex) are not monitored or driven.
* ``RX_ER`` without ``RX_DV`` is reported as ``ETH_CARRIER``.

Related recipes
---------------

* :doc:`../cookbook/beyond_gmii`: *MII at 10 or 100 Mbit/s*, *Run the same test at several rates*

API reference
-------------

* VHDL: :vhdl:`mii_pkg.new_mii_source`, :vhdl:`mii_pkg.new_mii_monitor`,
  :vhdl:`mii_pkg.new_mii_protocol_checker`, and the whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
