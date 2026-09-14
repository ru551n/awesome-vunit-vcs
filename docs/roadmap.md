# Interface roadmap

VHDL handles simulation timing. Python handles Ethernet verification semantics. Every interface
below reuses the same Python core; only the VHDL frontend and the Python PHY decoder differ.

## Planned, in implementation order

| # | Interface | Link rates | Data / control per clock | Clocking | Frontend responsibility |
|---|---|---|---|---|---|
| 1 | GMII | 1G, 2.5G (overclocked) | 8-bit data, EN/DV, ER | 125 MHz (312.5 MHz at 2.5G), rising edge | One octet per cycle |
| 2 | XGMII family | 2.5G, 5G, 10G, 25G, 40G, 100G | 4 lanes: 32-bit data + 4 control; 8 lanes: 64-bit data + 8 control | Rising edge, or both edges for 4-lane XGMII | Lane words per cycle; control characters decoded in Python |
| 3 | MII | 10M, 100M | 4-bit data, DV, ER (CRS/COL optional) | 2.5 / 25 MHz | Two nibbles per octet, low nibble first |
| 4 | RGMII | 10M, 100M, 1G | 4-bit data, CTL | 125 MHz both edges at 1G; 25 / 2.5 MHz | Both-edge sampling/driving; CTL = DV on rising, DV xor ER on falling |
| 5 | RMII | 10M, 100M | 2-bit data, TX_EN, CRS_DV (RX_ER optional) | 50 MHz; 10x symbol replication at 10M | Four dibits per octet; CRS_DV toggling at end of carrier |
| 6 | AXI-Stream MAC client | any | tdata, tkeep, tlast, tuser (error) | Rising edge, tvalid/tready handshake | Frames without preamble; FCS presence configurable |

The XGMII family is one component with lane-count (4 or 8), clocking and link-rate settings, so
2.5GMII and 5GMII (IEEE 802.3bz), 25GMII, XLGMII and CGMII need no components of their own. The GMII
component likewise takes a link-rate setting, which covers the overclocked 2.5G GMII some FPGA MACs use.

## Not planned for now

Serial and PCS-level interfaces are out of scope until there is a concrete need: TBI/RTBI, SGMII,
QSGMII, USXGMII, 1000BASE-X, XAUI, RXAUI and 10GBASE-R. They would need VHDL deserialization and
alignment plus 8b/10b or 64b/66b decoding in Python. Designs using them can be verified at the
GMII/XGMII level behind the PCS.
