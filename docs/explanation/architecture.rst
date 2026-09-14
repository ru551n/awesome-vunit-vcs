Architecture
============

**VHDL handles simulation timing. Python handles verification semantics.**

This page describes how a verification component (VC) of awesome-vunit-vcs is split between VHDL and
Python, what crosses the boundary, and how the two halves find each other at run time. The reasons
behind these choices are on :doc:`design_decisions`, and the measurements that back them are on
:doc:`performance`.

The boundary
------------

.. code-block:: text

    VHDL (simulation time)                           Python (no notion of simulation time)
    ------------------------------------             -----------------------------------------------
    gmii_monitor / xgmii_monitor                     MonitorBackend (one per monitor, own session)
      sample the pins at the right edges               PHY decoder -> octet words (+ PHY events)
      metavalue -> sample word bits                    FrameAssembler -> PhyFrame
      record a sample when something changes           FrameDecoder -> EthernetFrame
      flush a batch: full, end of frame, idle   ---->    |-> ProtocolChecker   -> reports
      log the reports it returns                <----    |-> PerformanceMonitor
                                                         |-> PcapNgWriter
                                                         |-> scoreboard, user subscribers
    gmii_source / xgmii_source                       SourceBackend (one per source, own session)
      receive a com message                     ---->    build preamble, SFD, padding, FCS, errors
      drive one symbol or column per edge       <----    symbols as an integer_array_t

Python code runs only when a VHDL process calls it, and returns before simulation time advances. It
never reads or drives a signal, never waits for an edge and never schedules anything. VHDL never
interprets a frame. Every Ethernet decision (where a frame starts, whether its FCS is right, whether a
gap is too short) is made once, in Python, on the samples VHDL recorded with their exact simulation
times.

Consequences
~~~~~~~~~~~~

* **Sample once, fan out in Python.** The checker, the statistics, captures, the scoreboard and user
  callbacks all subscribe to the same frames. Adding a consumer never adds a sampler.
* **The Python core is simulator independent.** ``awesome_vunit_vcs.ethernet`` is plain Python, tested
  with pytest without a simulator, and usable outside VUnit (see :doc:`../python_guide`).
* **A new interface is a thin frontend.** Its VHDL defines the pin timing and a sample word, and its
  Python decoder turns sample words into the common octet stream. Handles, procedures, checks,
  statistics and capture are shared.
* **Tests stay in VHDL.** A testbench uses VHDL procedures only. Python-specific extras, such as
  inspecting a received frame with Scapy, are additive.

Anatomy of a component
----------------------

Every Ethernet VC is built from the same layers:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Layer
     - Role
   * - ``ethernet_pkg``
     - The interface independent Ethernet VCIs (``ethernet_source_t``, ``ethernet_monitor_t``,
       ``ethernet_protocol_checker_t``), ``com`` message types and the procedures a testbench calls:
       ``push_ethernet_frame``, ``check_ethernet_frame``, ``get_statistics``, ``start_capture``,
       ``reset`` and so on. Shared by every interface.
   * - ``<interface>_pkg``
     - The handle types of the interface's source, monitor and protocol checker (such as
       ``gmii_monitor_t``), their constructors with the interface options (lanes, clocking, link
       rate) and the standard parameters, accessors, and overloads of the Ethernet procedures.
   * - ``<interface>_source``, ``<interface>_monitor``, ``<interface>_protocol_checker``
     - Entities with the handle as their only generic. They own the pin timing and nothing else; a
       monitor instantiates a protocol checker when its handle has one.
   * - ``ethernet_vc_pkg``
     - The PHY-independent part of every entity: message handling, end-of-frame flushes,
       ``wait_until_idle`` replies and the final checks at ``test_runner_cleanup``. It also samples
       and drives interfaces with one symbol per clock cycle (``monitor_symbol_interface`` and
       ``drive_symbol_interface``), which GMII and MII share.
   * - ``vc_python_pkg``
     - The only VHDL file that calls the Python bridge: sessions, backend creation, sample batches
       and report logging.
   * - ``ethernet.vunit_backend``
     - ``MonitorBackend`` and ``SourceBackend``, the Python objects the entities create.
   * - ``ethernet`` core
     - Frames, PHY decoders and encoders, checker, statistics, PCAPNG writer and Scapy adapter.

The handles follow VUnit's own verification components (``uart_pkg``, ``axi_stream_pkg``): records
with private ``p_`` fields around a ``std_cfg_t`` (id, actor, logger, checker and unexpected message
policy), accessors ``get_id``, ``get_logger``, ``get_checker`` and ``as_sync``, and
``wait_until_idle(net, as_sync(vc))`` from ``sync_pkg``. A testbench pulls everything in with
``context awesome_vunit_vcs.ethernet_context``.

Sessions and identity
---------------------

Each component creates a Python session with its own identity, ``new_vc_session(get_id(vc))``, and a
backend object named ``vc`` inside it. Two monitors therefore never share Python state, and a Python
error is reported on the logger of the component that caused it. A testbench that needs a
Python-specific extra reaches the same object through the bridge, as ``vc`` in
``new_session(get_id(monitor))``.

How a component finds its Python backend
----------------------------------------

It never uses a path. ``create_backend`` runs, for example,
``from awesome_vunit_vcs.ethernet.vunit_backend import MonitorBackend`` in the session of the
component. The bridge requires the embedded interpreter to use the environment that started VUnit
(``sys.prefix`` must match the interpreter of the run script), so the import resolves to wherever pip
installed the package, as a wheel or editable. ``examples/external_project`` and ``tests/vhdl/run.py``
prove this on GHDL and NVC in CI.

The VHDL side is found the same way: ``vu.add_package("awesome-vunit-vcs")`` locates the installed
package and compiles every ``vhdl/**/*.vhd`` file into the library ``awesome_vunit_vcs``.

Sample batches
--------------

A monitor sends what it sampled as one ``integer_array_t`` of 32-bit signed integers,
``[word_0, delta_0, word_1, delta_1, ...]``, with the call
``vc.push(samples, base_time, delta_unit)``. The bridge hands the array to Python as a
NumPy array.

* **word** is the sample word of the interface. For GMII: bits 0-7 data, bit 8 dv, bit 9 er, bit 10
  metavalue on data while dv, and bit 11 metavalue on dv or er. XGMII records one word per lane, with
  the octet, the control bit and metavalue bits.
* **delta** is the time since the previous sample in units of ``delta_unit`` (1 ps by default).
  Femtosecond deltas in 32 bits would span only 2.1 µs, less than one 10 Mbit/s MII symbol.
* **The base time** is two integers, ``hi * 2**30 + lo`` femtoseconds, since VHDL integers are 32
  bits.
* **Idle is run-length compressed.** A sample is recorded when data is valid, the word changes, or
  error or metavalue bits are set. A long idle period costs one sample, and inter-frame gaps keep
  their exact timing because every sample keeps its time.
* **Several words may share one time** (delta 0). That is how a multi-lane interface such as XGMII
  records one word per lane.
* **Metavalues are never hidden.** ``U``, ``X``, ``Z``, ``W`` and ``-`` set dedicated bits, which the
  checker reports as ``ETH_METAVALUE``, instead of being mapped silently to ``0``.

A batch is flushed when it is full (``batch_length``, 4096 samples by default), at the end of every
frame (``flush_at_frame_end``), before replying to ``wait_until_idle`` and at
``test_runner_cleanup``.

The common octet stream
~~~~~~~~~~~~~~~~~~~~~~~

Each PHY decoder in ``awesome_vunit_vcs.ethernet.phy`` turns its sample words into *octet words*,
one per received octet with the time of its first symbol. Octet words carry data, valid, error,
metavalue and alignment bits, and they are the point where the interface-specific part ends.
Decoders that signal with control characters, such as XGMII, also publish ``PhyEvent`` objects
(``ETH_CONTROL``, ``ETH_TERMINATION``, ``ETH_LINK_FAULT``) next to the octet stream, for violations
octet words cannot express.

Reports
-------

Violations and messages travel back to VHDL as one string per fetch: records separated by ASCII RS
(0x1E), with the severity code and the message separated by US (0x1F). A backend call returns the
number of reports waiting, so VHDL only fetches them when there are some. Errors become check
failures on the checker of the component, and failure, warning, info and debug messages go to its
logger. Backends catch their own exceptions and turn them into failure reports with a one-line
summary, so a user sees a VUnit failure rather than a Python traceback.

What belongs where, per interface
---------------------------------

.. list-table::
   :header-rows: 1
   :widths: 18 12 35 35

   * - Interface
     - Status
     - VHDL
     - Python
   * - GMII monitor
     - Done
     - Rising edge sampling, metavalue detection, idle compression, batching, flush at end of frame,
       ``wait_until_idle``, final check at ``test_runner_cleanup``
     - Octet stream, frame assembly, preamble/SFD/FCS, runt/giant, PHY error offsets, IFG,
       statistics, PCAPNG, scoreboard, Scapy
   * - GMII source
     - Done
     - One symbol per rising edge, frames back to back
     - Preamble length, SFD, padding, FCS good/bad/none, error offsets, IFG, Scapy packets
   * - XGMII family
     - Done
     - One word per lane (octet and control bit), rising or both edges, 4 or 8 lanes; skips Idle
       columns equal to the previous one
     - Control characters (Start, Terminate, Idle, Error, Sequence), Start alignment on lane 0, link
       fault ordered sets, deficit idle on transmit, octet stream
   * - MII
     - Done
     - One nibble per rising edge, sampled and driven by the same code as GMII
     - Nibble pairing into octets aligned on the SFD, low nibble first, alignment errors, octet period
       of two clock cycles
   * - RGMII
     - Planned
     - Both-edge sampling and driving; CTL is DV on the rising edge and DV xor ER on the falling
       edge, reconstructed into data/dv/er words
     - The GMII octet stream, unchanged
   * - RMII
     - Planned
     - Dibit sampling on the 50 MHz reference clock
     - Dibit to octet assembly, 10x symbol replication at 10 Mbit/s, CRS_DV toggling at end of
       carrier
   * - AXI-Stream MAC client
     - Planned
     - tvalid/tready handshake, tkeep, tlast, tuser
     - Frames without preamble or SFD, optional FCS

Active sources
--------------

A source works the other way round: **Python decides what is transmitted, VHDL decides when pins
change.** A testbench procedure such as ``push_ethernet_frame`` sends a ``com`` message to the source
entity. The entity asks its backend to build the symbols (preamble, SFD, padding, FCS, injected
errors and the gap that follows), receives them as one ``integer_array_t`` per frame, and drives one
symbol or column per clock edge. Deliberately malformed traffic is described by the same request, so
it is as deterministic as good traffic.

Components that must answer a bus, such as a memory model that responds to an opcode, cannot batch
in advance: what they drive next depends on what they just received. Such responders may call their
backend once per transfer unit (octet or word), but never once per clock cycle; see
:doc:`../contributing/new_family`.
