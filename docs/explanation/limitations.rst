Known limitations
=================

awesome-vunit-vcs is alpha software. These are the known limitations of the released components,
grouped by where they apply. Planned interfaces are listed on the :doc:`../roadmap`.

All Ethernet components
-----------------------

* **The scoreboard matches in order only.** ``check_ethernet_frame`` compares received frames with
  the expected frames first in, first out. Out-of-order or filtered traffic needs a subscriber of its
  own in Python.
* **The final check does not wait.** The final check of a monitor (an unfinished frame, expected
  frames that were not received, closing captures) runs at ``test_runner_cleanup`` in zero simulation
  time. A frame still on the wire then is reported as ``ETH_FRAME_STATE``, not waited for.

  .. important::

     Call ``wait_until_idle(net, as_sync(monitor))`` before ``test_runner_cleanup``.

* **Packet functions are testbench code.** ``push_ethernet_packet`` and the sequence procedures
  import and call a Python function by name in the session of the VC. Their arguments are VHDL
  values, but the function runs with testbench trust.
* **Pops cancelled by a reset.** ``reset(net, monitor)`` cancels pending pops; a non-blocking pop
  pending at a reset must not be awaited.
* **The link rate must match the clock.** Utilization, and for XGMII the octet period used to time
  inter-frame gaps, come from ``link_rate_mbps``, not from the clock period.
* **Simulators.** GHDL and NVC are tested in CI. Questa/ModelSim, Riviera-PRO and Active-HDL are
  supported by vunit-python-bridge but not tested with these components.

GMII
----

No limitations beyond those of all Ethernet components.

MII
---

* **Half duplex.** ``CRS`` and ``COL`` are neither monitored nor driven.
* **Odd preambles.** A leading unpaired preamble nibble is dropped, so a preamble of 15 nibbles counts
  as 7 octets.
* **Odd nibble counts on transmit.** The source cannot transmit an odd number of nibbles. A test of
  the alignment check drives the line directly.
* **False carrier.** ``RX_ER`` with ``RX_DV`` deasserted is reported like any error outside a frame,
  as on GMII.

XGMII family
------------

* **Start on lane 4.** The source never starts a frame on lane 4 and has no lane-4 deficit
  alignment. The monitor accepts a Start on lane 4 only with ``allow_lane4_start => true`` (8 lanes).
* **Link fault state.** A local or remote fault is reported when it starts and cleared by an Idle on
  lane 0 or a frame. The IEEE 802.3 fault state machine, with its column counters, is not modeled.
* **Low power idle.** LPI (0x06) is accepted like Idle outside a frame; LPI assert and deassert
  sequencing is not checked.
* **Signal ordered sets.** Signal ordered sets (0x5C) are reported as unknown control characters.
* **Transmit gaps.** Gaps are rounded to whole columns. With ``deficit_idle => true`` the average gap
  equals the requested one, but a single gap may be up to ``lanes - 1`` octets shorter.

Frames without a PHY
--------------------

The Python core expects every frame to start with a preamble and an SFD; a missing SFD is an
``ETH_SFD`` violation. Frontends without a PHY layer, such as the planned AXI-Stream MAC client, need a
switch for frames that start at the destination address. It does not exist yet.
