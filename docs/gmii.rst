GMII
====

GMII is the reference implementation of the Ethernet components. A ``gmii_monitor`` passively
observes one direction of a GMII interface and reconstructs, checks, counts and captures the frames
on it. A ``gmii_source`` drives one direction with frames a test sends. The handles and procedures
are shared by all Ethernet interfaces and described in :doc:`vhdl_api`.

Interface
---------

GMII carries one octet per clock cycle. Both components use the rising edge of ``clk``.

.. list-table::
   :header-rows: 1

   * - Port
     - Monitor
     - Source
     - GMII signal
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``GTX_CLK`` or ``RX_CLK``
   * - ``data``
     - ``in std_ulogic_vector(7 downto 0)``
     - ``out std_ulogic_vector(7 downto 0)``
     - ``TXD`` or ``RXD``
   * - ``dv``
     - ``in std_ulogic``
     - ``out std_ulogic``
     - ``TX_EN`` or ``RX_DV``
   * - ``er``
     - ``in std_ulogic := '0'``
     - ``out std_ulogic``
     - ``TX_ER`` or ``RX_ER``

The handle is the only generic: ``monitor : ethernet_monitor_t`` or ``source : ethernet_source_t``.

Creating the components
-----------------------

.. code-block:: vhdl

   constant source : ethernet_source_t := new_gmii_source;
   constant monitor : ethernet_monitor_t := new_gmii_monitor;

``new_gmii_monitor`` and ``new_gmii_source`` take the options of :ref:`new_ethernet_monitor
<vhdl-new-ethernet-monitor>` and :ref:`new_ethernet_source <vhdl-new-ethernet-source>` without
``phy``. ``link_rate_mbps`` is 1000 by default. Set it to 2500 for the overclocked GMII some FPGA
MACs use; it only affects the utilization statistics, since all timing comes from the simulation.

The monitor
-----------

The monitor samples ``data``, ``dv`` and ``er`` on every rising edge and never drives them. A sample
is recorded when ``dv`` is asserted or the sampled values change, so a long idle period costs one
sample and inter-frame gaps keep their exact timing. Metavalues (``U``, ``X``, ``Z``, ``W``,
``-``) on ``data`` while ``dv`` is asserted, or on ``dv`` and ``er``, are reported as
``eth_metavalue`` violations instead of being read as ``0``.

The samples are sent to Python in batches of up to ``batch_length`` samples, and at the end of
every frame when ``flush_at_frame_end`` is true (the default), so a violation is logged close to
the simulation time of the frame. Python reconstructs the frames, checks preamble, SFD, FCS, frame
size, PHY errors and inter-frame gaps, updates the statistics and writes any captures.

Violations are logged as errors on the checker of the monitor, which has the identity of the
monitor. By default the first error stops the simulation, as any VUnit check failure does.

At ``test_runner_cleanup`` the monitor reports a frame that is still being received and expected
frames that never arrived, and closes its captures. Call ``wait_until_idle`` on the source and the
monitor before ending a test.

The source
----------

The source transmits frames in the order the test sends them, back to back with the IFG of each
frame after it. Python builds the octets of a frame (preamble, SFD, padding, FCS) and the error
positions; the source drives one octet per rising edge of ``clk``. ``dv``, ``data`` and ``er`` are
``'0'`` between frames.

The arguments of ``send_ethernet_frame`` can describe traffic the standard forbids, which is how
the protocol checks of a DUT are tested:

.. code-block:: vhdl

   send_ethernet_frame(net, source, frame, fcs => fcs_bad);          -- inverted FCS
   send_ethernet_frame(net, source, frame, pad => false);            -- no padding: a runt
   send_ethernet_frame(net, source, frame, preamble_octets => 5);    -- short preamble
   send_ethernet_frame(net, source, frame, sfd => x"D4");            -- wrong SFD
   send_ethernet_frame(net, source, frame, error_offsets => (0 => 20)); -- er on frame octet 20
   send_ethernet_frame(net, source, frame, ifg_octets => 8);         -- short IFG after the frame

Example
-------

A source drives a line that a monitor observes, using only the installed packages. This is
``examples/external_project/tb_gmii_monitor.vhd``, which runs in CI:

.. literalinclude:: ../examples/external_project/tb_gmii_monitor.vhd
   :language: vhdl
   :lines: 5-

``tests/vhdl/tb_gmii.vhd`` in the repository covers every check, two monitors on one line, PCAPNG
capture, Scapy packets and randomized traffic.
