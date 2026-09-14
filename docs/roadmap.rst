Roadmap
=======

Every Ethernet interface reuses the same Python core. Only the VHDL frontend, which owns the pin
timing, and the Python PHY decoder differ from one interface to the next.

Ethernet interfaces
-------------------

.. list-table::
   :header-rows: 1
   :widths: 17 13 22 22 14

   * - Interface
     - Link rates
     - Data and control per clock
     - Clocking
     - Status
   * - GMII
     - 1G, 2.5G (overclocked)
     - 8-bit data, EN/DV, ER
     - 125 MHz (312.5 MHz at 2.5G), rising edge
     - Done
   * - XGMII family
     - 2.5G, 5G, 10G, 25G, 40G, 100G, 200G, 400G
     - 4 lanes: 32-bit data and 4 control bits; 8 lanes: 64-bit data and 8 control bits
     - Rising edge, or both edges for 4-lane XGMII
     - Done
   * - MII
     - 10M, 100M
     - 4-bit data, DV, ER
     - 2.5 or 25 MHz, rising edge; two nibbles per octet, low nibble first
     - Done
   * - RGMII
     - 10M, 100M, 1G
     - 4-bit data, CTL
     - 125 MHz on both edges at 1G; 25 or 2.5 MHz; CTL is DV on the rising edge and DV xor ER on the
       falling edge
     - Planned
   * - RMII
     - 10M, 100M
     - 2-bit data, TX_EN, CRS_DV (RX_ER optional)
     - 50 MHz reference clock; 10x symbol replication at 10M; four dibits per octet
     - Planned
   * - AXI-Stream MAC client
     - Any
     - tdata, tkeep, tlast, tuser (error)
     - Rising edge with the tvalid/tready handshake; frames without preamble, FCS configurable
     - Planned

The XGMII family is one component with lane count (4 or 8), clocking and link rate settings, so
2.5GMII, 5GMII, XGMII, 25GMII, XLGMII, CGMII, 200GMII and 400GMII need no components of their own.
The GMII component likewise takes a link rate, which covers the overclocked 2.5G GMII some FPGA MACs
use.

Later
~~~~~

* Correlation of transmitted and received streams, for latency metrics.

Not planned
~~~~~~~~~~~

Serial and PCS-level interfaces are out of scope until there is a concrete need: TBI/RTBI, SGMII,
QSGMII, USXGMII, 1000BASE-X, XAUI, RXAUI and 10GBASE-R. They would need VHDL deserialization and
alignment plus 8b/10b or 64b/66b decoding in Python. Designs that use them can be verified at the
GMII or XGMII level, behind the PCS.

Other VC families
-----------------

.. list-table::
   :header-rows: 1
   :widths: 25 55 20

   * - Family
     - Scope
     - Status
   * - Flash / QSPI
     - A QSPI NOR flash responder with a simulator independent Python device model: SPI mode 0, x1,
       x2 and x4 I/O, QPI, 3- and 4-byte addressing, continuous read, SFDP, status register and
       region protection, and busy times. A QSPI master with a JEDEC command layer, and a passive
       QSPI protocol checker of the master's pin timing. See :doc:`flash/index`.
     - Done

New families follow :doc:`contributing/new_family`. Ideas such as I2C, MDIO or AXI monitors are
welcome as issues or pull requests.
