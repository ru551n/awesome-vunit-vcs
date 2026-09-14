MII
===

MII carries 10 and 100 Mbit/s Ethernet, one nibble per clock cycle, least
significant nibble of each octet first.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`mii_source`, :vhdl:`mii_monitor`, :vhdl:`mii_protocol_checker`
   * - Constructors
     - :vhdl:`mii_pkg.new_mii_source`, :vhdl:`mii_pkg.new_mii_monitor`,
       :vhdl:`mii_pkg.new_mii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 100`` (default) or ``10``
   * - Clocking
     - Rising edge of ``clk``: 25 MHz at 100 Mbit/s, 2.5 MHz at 10 Mbit/s
   * - Python decoder
     - ``awesome_vunit_vcs.ethernet.MII``
   * - Tested on
     - GHDL, NVC, at both rates

Pins
----

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

Constructors
------------

.. code-block:: vhdl

   constant source : mii_source_t := new_mii_source(link_rate_mbps => 10);
   constant monitor : mii_monitor_t := new_mii_monitor(link_rate_mbps => 10, protocol_checker => default_mii_protocol_checker);

The parameters are those of :doc:`gmii`, with ``link_rate_mbps`` 10 or 100. Every other rate is a
failure. Full list: :vhdl:`mii_pkg.new_mii_monitor`.

How nibbles become octets
-------------------------

.. list-table::
   :widths: 30 70

   * - Pairing
     - Aligned on the SFD nibbles ``0x5 0xD``; an octet takes the time of its first nibble, so gaps are
       measured in octets.
   * - Odd preamble
     - An unpaired leading preamble nibble is dropped, so 15 preamble nibbles count as 7 octets.
   * - Trailing nibble
     - A frame ending with an unpaired nibble is an ``ETH_TERMINATION`` violation (an alignment error); the incomplete octet also fails ``ETH_FCS``.
   * - Error and metavalue
     - Flags on either nibble mark the octet.
   * - Batches
     - Unpaired nibbles carry over between batches, so a frame may span batches.

Everything MII specific happens in Python; the VHDL sampling and driving is shared with GMII.

Example
-------

``tests/vhdl/tb_mii.vhd`` runs at 10 and 100 Mbit/s: nibble order on the pins, minimum and large
frames, bad FCS, PHY error, odd preamble and trailing nibble, IFG, loopback, two monitors and
randomized traffic. The GMII :doc:`../getting_started/quickstart` works for MII by replacing ``gmii``
with ``mii``, the data width with 4 and the clock period with 40 ns.

Limitations
-----------

* ``CRS`` and ``COL`` (half duplex) are neither monitored nor driven.
* The source cannot transmit an odd number of nibbles; tests of the alignment check drive the line
  directly.
* ``RX_ER`` without ``RX_DV`` is reported like any error outside a frame (``ETH_CARRIER``).
