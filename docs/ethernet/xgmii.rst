XGMII family
============

One set of components covers every interface with XGMII framing: data and control bits per lane, with
control characters marking idle, frame start and end, and errors. The interfaces differ in lane count,
clocking and link rate only.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`xgmii_source`, :vhdl:`xgmii_monitor`, :vhdl:`xgmii_protocol_checker`
   * - Constructors
     - :vhdl:`xgmii_pkg.new_xgmii_source`, :vhdl:`xgmii_pkg.new_xgmii_monitor`,
       :vhdl:`xgmii_pkg.new_xgmii_protocol_checker`
   * - Extra procedures
     - :vhdl:`xgmii_pkg.push_xgmii_columns`, :vhdl:`xgmii_pkg.push_xgmii_link_fault`
   * - Python decoder
     - ``awesome_vunit_vcs.ethernet.XGMII(lanes, rate)``
   * - Tested on
     - GHDL, NVC: 4 lanes single edge, 4 lanes both edges, 8 lanes, and 8 lanes at 200G and 400G

Configurations
--------------

.. list-table::
   :header-rows: 1

   * - Interface
     - ``lanes``
     - ``both_edges``
     - ``link_rate_mbps``
   * - XGMII
     - 4
     - true
     - 10000
   * - 32-bit single-edge XGMII
     - 4
     - false
     - 10000
   * - 64-bit XGMII (10G/25G MAC cores)
     - 8
     - false
     - 10000
   * - 2.5GMII / 5GMII
     - 4 or 8
     - false
     - 2500 / 5000
   * - 25GMII
     - 8
     - false
     - 25000
   * - XLGMII / CGMII
     - 8
     - false
     - 40000 / 100000
   * - 200GMII / 400GMII
     - 8
     - false
     - 200000 / 400000

Pins
----

.. list-table::
   :header-rows: 1

   * - Port
     - Width
     - Content
   * - ``clk``
     - 1
     - Rising edge, or both edges with ``both_edges => true``
   * - ``data``
     - ``data_length(vc)`` = 8 × ``lanes``
     - One octet per lane, lane 0 in the low octet
   * - ``ctrl``
     - ``ctrl_length(vc)`` = ``lanes``
     - One control bit per lane, lane 0 in the low bit

Size the signals with the accessor functions, so a testbench follows the handle:

.. code-block:: vhdl

   constant monitor : xgmii_monitor_t := new_xgmii_monitor(lanes => 8, link_rate_mbps => 100000,
                                                           protocol_checker => default_xgmii_protocol_checker);
   signal data : std_ulogic_vector(data_length(monitor) - 1 downto 0);
   signal ctrl : std_ulogic_vector(ctrl_length(monitor) - 1 downto 0);

Source outputs are Idle columns between frames.

Constructors
------------

The parameters are those of :doc:`gmii` plus:

.. list-table::
   :header-rows: 1
   :widths: 25 15 60

   * - Parameter
     - Default
     - Meaning
   * - ``lanes``
     - 4
     - 4 or 8.
   * - ``both_edges``
     - false
     - Transfer a column on both clock edges (4-lane XGMII).
   * - ``link_rate_mbps``
     - 10000
     - Must match the clock: the octet period used for gaps comes from it.
   * - ``allow_lane4_start`` (monitor, protocol checker)
     - false
     - Accept frames starting on lane 4 of 8 lanes.
   * - ``min_ifg_octets`` (protocol checker)
     - 5
     - The minimum gap at an XGMII receiver; Terminate counts as a gap octet.
   * - ``deficit_idle`` (source)
     - true
     - Keep the average gap at the requested one; see below.

Full list: :vhdl:`xgmii_pkg.new_xgmii_monitor`.

Control characters
------------------

.. list-table::
   :header-rows: 1
   :widths: 20 15 65

   * - Character
     - Code
     - Use
   * - Idle
     - ``0x07``
     - Between frames
   * - Start
     - ``0xFB``
     - Lane 0 (or lane 4 with ``allow_lane4_start``); replaces the first preamble octet, so 7 preamble
       octets are expected with Start included
   * - Terminate
     - ``0xFD``
     - Ends a frame
   * - Error
     - ``0xFE``
     - An error inside a frame (``eth_phy_error``) or outside (``eth_carrier``)
   * - Sequence
     - ``0x9C``
     - Lane 0, with three data octets: ``00 00 01`` local fault, ``00 00 02`` remote fault

Violations only control characters can express are ``eth_control`` (Start or Sequence on a wrong lane, an
unknown or reserved character, Terminate or data outside a frame, an incomplete ordered set),
``eth_termination`` (a frame without Terminate) and ``eth_link_fault`` (reported when a fault starts,
cleared by an Idle on lane 0 or a frame).

How the source transmits
------------------------

* Frames start on lane 0.
* The gap after a frame is rounded to whole columns. With ``deficit_idle`` it is rounded down while the
  accumulated deficit stays within ``lanes - 1`` octets, otherwise up, so the average gap equals the
  requested one and a single gap may be up to ``lanes - 1`` octets shorter.
* Error offsets transmit the Error character in place of the octet.
* After columns that do not end in Idle, the source drives Idle when nothing else is queued, so
  ``wait_until_idle`` returns only after the monitors sampled the last column.

Raw columns and link faults
---------------------------

For traffic the frame procedures cannot describe:

.. code-block:: vhdl

   -- one column per lanes octets, lane 0 of the first column leftmost
   push_xgmii_columns(net, source, data => x"FB555555", control => "1000");
   push_xgmii_link_fault(net, source, local_fault, columns => 4);

How the monitor decodes
-----------------------

VHDL samples one column per clock edge and records one sample word per lane, skipping an Idle column
equal to the previous one. Python decodes the lanes into octets: Start becomes the first preamble octet,
Error inside a frame an octet with the error flag, and Terminate ends the frame. Octet ``k`` of a column is
timed ``k`` octet periods after the column, so gaps are counted in octets whatever the clocking.

Example
-------

``tests/vhdl/tb_xgmii.vhd`` runs in all three configurations: frames of several lengths with Terminate on
every lane position, bad FCS, the Error character, Start on a wrong lane, a missing Terminate, short gaps,
link fault ordered sets, loopback, two monitors and randomized traffic. The GMII
:doc:`../getting_started/quickstart` works for XGMII with the handles above and ``data``/``ctrl`` ports.

Limitations
-----------

* The source never starts a frame on lane 4.
* The IEEE 802.3 link fault state machine, with its column counters, is not modeled.
* Low power idle (``0x06``) is accepted like Idle; its sequencing is not checked.
* Signal ordered sets (``0x5C``) are reported as unknown control characters.
