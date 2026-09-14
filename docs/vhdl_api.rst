VHDL API
========

The Ethernet components follow the conventions of VUnit's own verification components: a handle
created by a ``new_*`` function, logging through VUnit loggers and checkers, and communication
through ``com``. Handles and procedures are the same for every interface; an interface only adds
constructors and entities (see :doc:`gmii`).

A testbench uses everything through one context:

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

The context makes ``ethernet_pkg``, ``gmii_pkg``, VUnit's ``com_context``, ``sync_pkg`` and
``vc_pkg`` visible. The procedures below take ``signal net : inout network_t`` like all ``com``
procedures.

Handles
-------

``ethernet_monitor_t``
   A passive monitor of one direction of an interface.

``ethernet_source_t``
   An active source driving one direction of an interface.

Both are records with private fields only. Use the accessors:

.. code-block:: vhdl

   impure function get_id(monitor : ethernet_monitor_t) return id_t;
   impure function get_logger(monitor : ethernet_monitor_t) return logger_t;
   impure function get_checker(monitor : ethernet_monitor_t) return checker_t;
   impure function as_sync(monitor : ethernet_monitor_t) return sync_handle_t;

   impure function get_id(source : ethernet_source_t) return id_t;
   impure function get_logger(source : ethernet_source_t) return logger_t;
   impure function as_sync(source : ethernet_source_t) return sync_handle_t;

A monitor reports protocol violations on its checker and other messages on its logger; both have
the identity of the monitor.

Constructors
------------

GMII (``gmii_pkg``):

.. code-block:: vhdl

   impure function new_gmii_monitor(
     id : id_t := null_id;
     link_rate_mbps : positive := 1000;
     min_preamble_octets : natural := 7;
     max_preamble_octets : natural := 7;
     min_frame_octets : natural := 64;
     max_frame_octets : natural := 1518;
     min_ifg_octets : natural := 12;
     has_fcs : boolean := true;
     batch_length : positive := 4096;
     flush_at_frame_end : boolean := true;
     delta_unit : time := 1 ps;
     log_frames : boolean := false;
     unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
   ) return ethernet_monitor_t;

   impure function new_gmii_source(
     id : id_t := null_id;
     link_rate_mbps : positive := 1000;
     unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
   ) return ethernet_source_t;

They call the interface independent constructors of ``ethernet_pkg`` with ``phy => gmii``:

.. _vhdl-new-ethernet-monitor:

.. code-block:: vhdl

   impure function new_ethernet_monitor(
     phy : ethernet_phy_t;
     id : id_t := null_id;
     -- the remaining parameters as for new_gmii_monitor
   ) return ethernet_monitor_t;

.. _vhdl-new-ethernet-source:

.. code-block:: vhdl

   impure function new_ethernet_source(
     phy : ethernet_phy_t;
     id : id_t := null_id;
     link_rate_mbps : positive := 1000;
     unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
   ) return ethernet_source_t;

.. list-table:: Monitor options
   :header-rows: 1
   :widths: 25 75

   * - Parameter
     - Meaning
   * - ``id``
     - Identity of the monitor. Defaults to ``awesome_vunit_vcs:<phy>_monitor:<n>``.
   * - ``link_rate_mbps``
     - Link rate used for the utilization statistics (1000 for GMII, 2500 for overclocked GMII).
   * - ``min_preamble_octets``, ``max_preamble_octets``
     - Accepted preamble length, not counting the SFD (``eth_preamble``).
   * - ``min_frame_octets``, ``max_frame_octets``
     - Accepted frame size, counted from the destination address to the FCS (``eth_runt``,
       ``eth_giant``).
   * - ``min_ifg_octets``
     - Minimum inter-frame gap (``eth_ifg``).
   * - ``has_fcs``
     - ``false`` for frames observed without an FCS.
   * - ``batch_length``
     - Maximum number of samples sent to Python in one call.
   * - ``flush_at_frame_end``
     - Send the samples at the end of every frame, so frames are checked as soon as they end.
   * - ``delta_unit``
     - Resolution of the sample times. Must not exceed 1 us.
   * - ``log_frames``
     - Log every received frame at debug level.
   * - ``unexpected_msg_type_policy``
     - What the monitor does with a message it does not handle, as for VUnit's components.

Types
-----

.. code-block:: vhdl

   -- The interfaces with a VHDL frontend
   type ethernet_phy_t is (gmii);

   -- What a source appends to the frame data
   type ethernet_fcs_mode_t is (
     fcs_append,  -- pad (when enabled) and append the correct FCS
     fcs_bad,     -- pad (when enabled) and append the inverted FCS
     fcs_none     -- nothing: the data already ends with an FCS or deliberately has none
   );

   -- Statistics of a monitor. Octet counts saturate at integer'high and a
   -- minimum/maximum without a value is -1.
   type ethernet_statistics_t is record
     total_frames : natural;
     good_frames : natural;
     bad_frames : natural;
     wire_octets : natural;
     payload_octets : natural;
     fcs_errors : natural;
     phy_error_frames : natural;
     runts : natural;
     giants : natural;
     min_frame_octets : integer;
     max_frame_octets : integer;
     min_ifg_octets : integer;
     max_ifg_octets : integer;
   end record;

Protocol checks
---------------

``ethernet_check_t`` names the checks of the Python checker; the log message of a violation starts
with the check ID in upper case, for example ``ETH_FCS: bad FCS on frame 27``. All checks are
enabled by default.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Check
     - Violation
   * - ``eth_preamble``
     - Preamble length outside ``min_preamble_octets`` .. ``max_preamble_octets``, or a malformed
       preamble octet.
   * - ``eth_sfd``
     - No SFD after the preamble.
   * - ``eth_fcs``
     - The FCS does not match the frame.
   * - ``eth_runt``
     - A frame shorter than ``min_frame_octets``.
   * - ``eth_giant``
     - A frame longer than ``max_frame_octets``.
   * - ``eth_phy_error``
     - The error signal asserted during a frame.
   * - ``eth_carrier``
     - The error signal asserted outside a frame.
   * - ``eth_ifg``
     - An inter-frame gap shorter than ``min_ifg_octets``.
   * - ``eth_termination``
     - A frame that ended with an incomplete octet (interfaces with symbols narrower than an octet).
   * - ``eth_metavalue``
     - A metavalue on the data during a frame, or on the valid or error signal.
   * - ``eth_frame_state``
     - A frame already in progress when monitoring started, or still in progress when it ended.
   * - ``eth_control``
     - An invalid control character (interfaces that signal with control characters, such as XGMII).
   * - ``eth_link_fault``
     - A local or remote fault ordered set (XGMII family).
   * - ``eth_scoreboard``
     - A frame that differs from the one ``expect_ethernet_frame`` expected, or expected frames not
       received before the simulation ends.

Monitor procedures
------------------

``wait_until_idle(net, as_sync(monitor))`` returns when the monitor has seen the end of any frame
in progress and Python has processed everything sampled so far. The procedures that return a value
wait for that too.

.. code-block:: vhdl

   -- Enable or disable one protocol check
   procedure set_check_enabled(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     check : ethernet_check_t;
     enabled : boolean := true
   );

   -- Violations found by a check while it was enabled
   procedure get_check_count(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     check : ethernet_check_t;
     variable count : out natural
   );

   -- Frames received, good or bad
   procedure get_frame_count(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     variable count : out natural
   );

   procedure get_statistics(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     variable statistics : out ethernet_statistics_t
   );

   -- Log a human readable statistics summary on the logger of the monitor
   procedure log_statistics(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     log_level : log_level_t := info
   );

   -- Expect the next received frame to be data: the octets from the
   -- destination address up to, not including, the FCS, leftmost octet first
   procedure expect_ethernet_frame(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     data : std_ulogic_vector
   );

   -- Write the frames received from now on to a PCAPNG file (Wireshark)
   procedure start_capture(
     signal net : inout network_t;
     monitor : ethernet_monitor_t;
     file_name : string;
     include_fcs : boolean := true;
     include_errored : boolean := true
   );

   -- Close all captures of the monitor
   procedure stop_capture(
     signal net : inout network_t;
     monitor : ethernet_monitor_t
   );

A relative capture ``file_name`` is relative to the directory the simulator runs in;
``output_path(runner_cfg)`` is a good place. The capture has no preamble or SFD, the FCS when
``include_fcs`` and bad frames when ``include_errored``. Captures are also closed when the
simulation ends.

Source procedures
-----------------

A source transmits frames in the order they are sent, back to back with the IFG of each frame after
it. ``wait_until_idle(net, as_sync(source))`` returns when all frames sent before it are
transmitted.

.. code-block:: vhdl

   constant no_error_offsets : integer_vector(1 to 0) := (others => 0);

   -- Transmit data, the octets from the destination address up to, not
   -- including, the FCS, leftmost octet first
   procedure send_ethernet_frame(
     signal net : inout network_t;
     source : ethernet_source_t;
     data : std_ulogic_vector;
     fcs : ethernet_fcs_mode_t := fcs_append;
     pad : boolean := true;
     preamble_octets : natural := 7;
     sfd : std_ulogic_vector(7 downto 0) := x"D5";
     ifg_octets : natural := 12;
     error_offsets : integer_vector := no_error_offsets
   );

   -- Transmit the packet a Scapy expression builds, for example
   -- "Ether(dst='02:00:00:00:00:01')/IP()/UDP(dport=1234)". Needs the scapy extra.
   procedure send_ethernet_packet(
     signal net : inout network_t;
     source : ethernet_source_t;
     scapy_expression : string;
     fcs : ethernet_fcs_mode_t := fcs_append;
     pad : boolean := true;
     preamble_octets : natural := 7;
     sfd : std_ulogic_vector(7 downto 0) := x"D5";
     ifg_octets : natural := 12;
     error_offsets : integer_vector := no_error_offsets
   );

The arguments may describe traffic the standard forbids: a bad FCS, no padding, a short or long
preamble, a wrong SFD, a short IFG. The error signal is asserted with the octets in
``error_offsets``, which count like ``data`` and like the offsets ``eth_phy_error`` reports: 0 is
the first octet after the SFD. Negative offsets reach back into the SFD (-1) and the preamble.
Interfaces with control characters (XGMII) send the Error character instead.

Entities
--------

.. code-block:: vhdl

   entity gmii_monitor is
     generic (
       monitor : ethernet_monitor_t
     );
     port (
       clk : in std_ulogic;
       data : in std_ulogic_vector(7 downto 0);
       dv : in std_ulogic;
       er : in std_ulogic := '0'
     );
   end entity;

   entity gmii_source is
     generic (
       source : ethernet_source_t
     );
     port (
       clk : in std_ulogic;
       data : out std_ulogic_vector(7 downto 0) := (others => '0');
       dv : out std_ulogic := '0';
       er : out std_ulogic := '0'
     );
   end entity;

Python extras
-------------

A test never needs Python, but the backend of a component is the object ``vc`` in the Python
session with the identity of the component, reachable with the bridge's context
(``library python_bridge; context python_bridge.python_context;``):

.. code-block:: vhdl

   check_equal(eval_integer("vc.last_packet()['UDP'].dport", new_session(get_id(monitor))), 1234);

The backend classes are documented in :doc:`python_api`.
