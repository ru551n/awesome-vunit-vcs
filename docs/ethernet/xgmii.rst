XGMII family
============

One set of components covers every interface with XGMII framing. The interfaces differ only in lane
count, clocking and link rate.

When to use it
--------------

Use the XGMII components for 2.5G to 400G designs whose port carries data and control bits per lane.
Pick the settings for your interface:

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

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`xgmii_source`, :vhdl:`xgmii_monitor`, :vhdl:`xgmii_protocol_checker`
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.XGMII(lanes, rate)``
   * - Tested on
     - GHDL, NVC: 4 lanes on one or both edges, and 8 lanes up to 400G

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

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

Size your signals with the accessor functions, so they follow the handle:

.. code-block:: vhdl
   :caption: An 8-lane 100G monitor and its signals

   constant monitor : xgmii_monitor_t := new_xgmii_monitor(lanes => 8, link_rate_mbps => 100000,
                                                           protocol_checker => default_xgmii_protocol_checker);
   signal data : std_ulogic_vector(data_length(monitor) - 1 downto 0);
   signal ctrl : std_ulogic_vector(ctrl_length(monitor) - 1 downto 0);

Send and receive frames
~~~~~~~~~~~~~~~~~~~~~~~

Frames work exactly as on :doc:`gmii`: ``push_ethernet_frame`` on the source, and the monitor
procedures on :doc:`monitors`.

Send raw columns and link faults
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: vhdl
   :caption: Traffic that frames cannot describe

   -- one column per lanes octets, lane 0 of the first column leftmost
   push_xgmii_columns(net, source, data => x"FB555555", control => "1000");
   push_xgmii_link_fault(net, source, local_fault, columns => 4);

Use these to test how your design reacts to broken control characters or link faults.

Recognise the control characters
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

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
     - Starts a frame on lane 0, or lane 4 with ``allow_lane4_start``. It counts as the first preamble
       octet.
   * - Terminate
     - ``0xFD``
     - Ends a frame
   * - Error
     - ``0xFE``
     - An error inside a frame (``eth_phy_error``) or outside (``eth_carrier``)
   * - Sequence
     - ``0x9C``
     - On lane 0 with three data octets: ``00 00 01`` local fault, ``00 00 02`` remote fault

XGMII adds three checks: ``eth_control`` for a misplaced or unknown control character,
``eth_termination`` for a frame without Terminate, and ``eth_link_fault`` for a fault ordered set.

Common options
--------------

The parameters of :doc:`gmii` apply, plus:

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
     - Must match the clock, because gaps are measured with it.
   * - ``allow_lane4_start`` (monitor, protocol checker)
     - false
     - Accept frames that start on lane 4 of 8 lanes.
   * - ``min_ifg_octets`` (protocol checker)
     - 5
     - The minimum gap at an XGMII receiver. Terminate counts as a gap octet.
   * - ``deficit_idle`` (source)
     - true
     - Keep the average gap at the requested one.

Good to know
------------

* Source outputs are Idle columns between frames.
* The source always starts frames on lane 0.
* The source rounds each gap to whole columns. With ``deficit_idle`` the average gap is exact, and a
  single gap may be up to ``lanes - 1`` octets shorter.
* Error offsets send the Error character in place of the octet.
* Gaps are counted in octets, whatever the clocking.
* A link fault is reported when it starts. An Idle on lane 0 or a frame clears it.
* Low power idle (``0x06``) is accepted like Idle. Signal ordered sets (``0x5C``) are reported as
  ``eth_control``.

Related recipes
---------------

* :doc:`../cookbook/interfaces`: *Use XGMII, from 10G up to 400G*, *Run one testbench at several rates*

API reference
-------------

* VHDL: :vhdl:`xgmii_pkg.new_xgmii_source`, :vhdl:`xgmii_pkg.new_xgmii_monitor`,
  :vhdl:`xgmii_pkg.new_xgmii_protocol_checker`, :vhdl:`xgmii_pkg.push_xgmii_columns`,
  :vhdl:`xgmii_pkg.push_xgmii_link_fault`, and the whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
