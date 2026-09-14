GMII
====

GMII is the reference implementation of the Ethernet verification components (VCs). A
``gmii_source`` drives one direction of a GMII interface with the frames a test pushes. A
``gmii_monitor`` passively observes one direction and reconstructs, counts, scoreboards and captures
the frames on it, and a ``gmii_protocol_checker`` checks the protocol. The procedures are shared by
all Ethernet interfaces and described in :doc:`vhdl_api`.

Interface
---------

GMII carries one octet per clock cycle. All three VCs use the rising edge of ``clk``.

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor and protocol checker
     - GMII signal
   * - ``clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``GTX_CLK`` or ``RX_CLK``
   * - ``data``
     - ``out std_ulogic_vector(7 downto 0)``
     - ``in std_ulogic_vector(7 downto 0)``
     - ``TXD`` or ``RXD``
   * - ``dv``
     - ``out std_ulogic``
     - ``in std_ulogic``
     - ``TX_EN`` or ``RX_DV``
   * - ``er``
     - ``out std_ulogic``
     - ``in std_ulogic := '0'``
     - ``TX_ER`` or ``RX_ER``

The handle is the only generic: ``source : gmii_source_t``, ``monitor : gmii_monitor_t`` or
``protocol_checker : gmii_protocol_checker_t``.

Creating the components
-----------------------

.. code-block:: vhdl

   constant source : gmii_source_t := new_gmii_source;
   constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);

``link_rate_mbps`` is 1000 by default. Set it to 2500 for the overclocked GMII some FPGA MACs use; it
only affects statistics and the IFG measurement, since all timing comes from the simulation. Name a
VC after its place in the testbench with ``id => get_id("tb:rx_monitor")``; its protocol checker
then logs as ``tb:rx_monitor:protocol_checker``.

The monitor
-----------

The monitor samples ``data``, ``dv`` and ``er`` on every rising edge and never drives them. A sample
is recorded when ``dv`` is asserted or the sampled values change, so a long idle period costs one
sample and inter-frame gaps keep their exact timing.

The samples are sent to Python in batches of up to ``batch_length`` samples, and at the end of
every frame when ``flush_at_frame_end`` is true (the default). Python reconstructs the frames,
updates the statistics, compares them with the frames ``check_ethernet_frame`` expects and writes
any captures. A difference is an ``ETH_SCOREBOARD`` error on the checker of the monitor. By default
the first error stops the simulation, as any VUnit check failure does.

A monitor does not check the protocol itself. With ``protocol_checker =>
default_gmii_protocol_checker`` it instantiates a ``gmii_protocol_checker`` on the same pins, with
the link and frame configuration of the monitor and the default limits. Pass a protocol checker
created with ``new_gmii_protocol_checker`` to choose the limits, or instantiate
``gmii_protocol_checker`` on its own.

The protocol checker
--------------------

The protocol checker checks preamble, SFD, FCS, frame size, PHY errors and inter-frame gaps.
Metavalues (``U``, ``X``, ``Z``, ``W``, ``-``) on ``data`` while ``dv`` is asserted, or on ``dv`` and
``er``, are ``eth_metavalue`` violations instead of being read as ``0``, so give the outputs of a
design without reset an initial value. Violations are errors on the checker of the protocol
checker; count them with ``get_check_count(net, get_protocol_checker(monitor), eth_fcs, count)`` and
disable a check with ``set_check_enabled``.

At ``test_runner_cleanup`` a monitor reports expected frames that never arrived and closes its
captures, and a protocol checker reports a frame still being received. Call ``wait_until_idle`` on
the source and the monitor before ending a test.

The source
----------

The source transmits frames in the order the test pushes them, back to back with the IFG of each
frame after it. Python builds the octets of a frame (preamble, SFD, padding, FCS) and the error
positions; the source drives one octet per rising edge of ``clk``. ``dv``, ``data`` and ``er`` are
``'0'`` between frames.

``frame_options`` describes traffic the standard forbids, which is how the protocol checks of a DUT
are tested:

.. code-block:: vhdl

   push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));             -- inverted FCS
   push_ethernet_frame(net, source, frame, frame_options(pad => false));               -- a runt
   push_ethernet_frame(net, source, frame, frame_options(preamble_octets => 5));       -- short preamble
   push_ethernet_frame(net, source, frame, frame_options(sfd => x"D4"));               -- wrong SFD
   push_ethernet_frame(net, source, frame, frame_options(error_offsets => (0 => 20))); -- er on octet 20
   push_ethernet_frame(net, source, frame, frame_options(ifg_octets => 8));            -- short IFG

Frames can also come from Python: ``push_ethernet_packet(net, source, "packets:udp_packet",
"dport=1234")`` transmits the frame a function returns, and ``push_ethernet_sequence`` the frames a
generator yields, reproducibly for a seed such as ``get_string_seed(runner_cfg)``. ``reset(net,
source)`` aborts a frame in progress and drops the queued ones.

Example
-------

``examples/gmii`` verifies a small DUT, a GMII register pipeline, with a source on its input and a
monitor with a protocol checker on each side. Its tests show the scoreboard with seeded random
frames, a deliberate FCS error counted instead of failing the test, statistics, a PCAPNG capture in
the test output path, a Python subscriber added to a monitor and a Scapy packet. It runs in CI with
GHDL and NVC:

.. code-block:: console

   python examples/gmii/run.py

The run script adds the packages by name:

.. literalinclude:: ../examples/gmii/run.py
   :language: python
   :lines: 5-

The testbench:

.. literalinclude:: ../examples/gmii/tb_gmii_example.vhd
   :language: vhdl
   :lines: 5-

The DUT, ``examples/gmii/src/gmii_pipeline.vhd``:

.. literalinclude:: ../examples/gmii/src/gmii_pipeline.vhd
   :language: vhdl
   :lines: 5-

A smaller example, a source driving a line that a monitor observes, is
``examples/external_project/tb_gmii_monitor.vhd``. CI runs it from the installed wheel.

``tests/vhdl/tb_gmii.vhd`` in the repository covers every check, two monitors on one line, PCAPNG
capture, packets, sequences and randomized traffic; ``tests/vhdl/tb_gmii_vci.vhd`` tests the VUnit
conventions of the three VCs.
