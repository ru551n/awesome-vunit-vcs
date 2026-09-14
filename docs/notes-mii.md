# MII implementation notes

Facts for README.md, ARCHITECTURE.md and the docs, recorded while MII was built.

## Interface

IEEE 802.3 Clause 22 MII carries 10 Mbit/s and 100 Mbit/s Ethernet. `TX_CLK` and `RX_CLK` run at a
quarter of the bit rate, 2.5 MHz and 25 MHz. Each octet is transferred least significant nibble
first, `TXD<0>`/`RXD<0>` being its least significant bit. The MAC drives transmit signals and
samples receive signals on the rising edge.

Ports of `mii_monitor` and `mii_source`: `clk`, `data(3 downto 0)`, `dv`, `er`. Handles are the
`ethernet_monitor_t`/`ethernet_source_t` of `ethernet_pkg`, created with `new_mii_monitor` and
`new_mii_source` (`link_rate_mbps => 10` or `100`, default 100); every frame, check, statistics
and capture procedure works unchanged.

## VHDL/Python split

GMII and MII both carry one symbol per clock cycle with valid and error signals, so their sampling
and driving is shared: `monitor_symbol_interface` and `drive_symbol_interface` in `ethernet_vc_pkg`
take the data vector unconstrained. `gmii_monitor`, `gmii_source`, `mii_monitor` and `mii_source`
only check the handle and call them. The monitor records one sample word per clock cycle while `dv`
is asserted and one word per change otherwise; the source drives one word per rising edge.

Everything MII specific is in Python, `awesome_vunit_vcs/ethernet/phy/mii.py`:

* Nibbles are paired into octet words with the time of the first nibble and the error and metavalue
  flags of both nibbles. The octet period is therefore two clock cycles, so inter-frame gaps are
  measured in octets.
* The pairing is aligned on the SFD nibbles `0x5 0xD`. Any number of `0x5` nibbles may come first;
  an unpaired leading nibble is dropped instead of misaligning the frame. A frame without an SFD is
  paired from its first nibble and fails ETH_SFD.
* A frame that ends with an unpaired nibble ends with an octet word flagged `WORD_ALIGNMENT`. The
  checker reports it as ETH_TERMINATION; the incomplete octet also breaks the FCS, so ETH_FCS is
  reported too. IEEE 802.3 4.2.4.2.1 calls this an alignment error.
* The decoder keeps unpaired nibbles between batches, so frames may span batches.

## Tests

* `tests/python/test_mii.py`: hand-built nibble streams (`helpers.MiiLine`, written nibble by
  nibble, FCS from a bitwise CRC-32), including every batch split tried, odd preamble, trailing
  nibble, error and metavalue on one nibble, IFG, a frame without SFD and 10 Mbit/s timing.
* `tests/vhdl/tb_mii.vhd`, configurations `10_mbps` and `100_mbps`: nibble order on the pins, minimum
  and large frames, bad FCS, PHY error, odd preamble and trailing nibble (driven on the line directly
  with an FCS from zlib), legal and short IFG, source to monitor reconstruction, independent monitors
  and 100 randomized frames.

## References

* Nibble order, clock rates and edges: IEEE 802.3 Clause 22 (22.2.2), as summarized in
  "Ethernet: Media Independent Interface (MII)", Ethereal Wake, 2025, and in the IEEE Std 802.3-2005
  Section Two text.
* cocotbext-eth 0.1.28 `mii.py` transmits `b & 0x0F` then `b >> 4` and realigns its receiver on the
  SFD, which agrees.

## Limitations

* `CRS` and `COL` (half duplex) are neither monitored nor driven.
* A leading unpaired preamble nibble is dropped, so a preamble of 15 nibbles counts as 7 octets.
* The source cannot transmit an odd number of nibbles; tests drive the line directly for that.
* Receive-side false carrier (`RX_ER` with `RX_DV` deasserted) is reported like any error outside a
  frame on GMII.
