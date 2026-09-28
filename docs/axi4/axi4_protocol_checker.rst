AXI4 protocol checker
=====================

The :vhdl:`axi4_protocol_checker` component checks the rules of the AXI4 and AXI4-Lite protocol on an
interface. It never drives a signal.

.. include:: ../_includes/vunit_names.inc

Overview
--------

The checker records the channels at every rising edge of ACLK, like the monitor, and its Python backend
checks every handshake against the rules of the specification. It follows the transactions per ID, so it
knows which beat is the last of a burst, which byte lanes a beat may strobe, and whether a response has
a transaction to answer. Each check has a stable ID, can be switched off on its own, and counts its
violations. A violation is a VUnit check failure on the checker of the component, with the channel, the
IDs, addresses and beat numbers involved, and the simulation time in fs. Instantiate the checker on an
interface, or pass its handle to :vhdl:`axi4_monitor_pkg.new_axi4_monitor`.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`axi4_protocol_checker`
   * - Protocols
     - AXI4 and AXI4-Lite, the widths of the monitor
   * - Timeout
     - 1000 clock cycles by default, 0 for none
   * - Tested on
     - GHDL, NVC

Pins
----

The pins are those of the :doc:`axi4_monitor`, with the same defaults, sized by
``get_bus(protocol_checker)``. The :term:`handle` is the only generic:
``protocol_checker : axi4_protocol_checker_t``.

Constructor parameters
----------------------

:vhdl:`axi4_protocol_checker_pkg.new_axi4_protocol_checker`:

.. list-table::
   :header-rows: 1
   :widths: 25 20 20 35

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``axi4_bus``
     - ``axi4_bus_t``
     - ``default_axi4_bus``
     - The widths of the interface; a monitor gives its checker its own bus
   * - ``timeout_cycles``
     - ``natural``
     - ``1000``
     - How many clock cycles a transaction may wait for its response, write data for its address, and
       VALID for READY; 0 for no limit
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - See the family page

Checks
------

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Check
     - Violation
   * - ``axi4_metavalue``
     - ``U``, ``X``, ``Z``, ``W`` or ``-`` on VALID, READY or ARESETn, on the payload of a channel while
       VALID is 1, on a strobed WDATA byte lane, or on an RDATA byte lane of the beat. Unused data lanes
       may carry anything.
   * - ``axi4_reset_valid``
     - VALID is 1 while ARESETn is 0, or at the first rising edge of ACLK after ARESETn rose
   * - ``axi4_stable``
     - The payload of a channel changed while VALID was 1 and READY 0; data is compared on the byte
       lanes that carry data
   * - ``axi4_valid_drop``
     - VALID fell before READY accepted the payload
   * - ``axi4_burst_type``
     - AxBURST is the reserved value ``"11"``
   * - ``axi4_burst_4k``
     - An INCR burst crosses a 4 KB address boundary
   * - ``axi4_wrap_len``
     - A WRAP burst is not 2, 4, 8 or 16 beats long
   * - ``axi4_wrap_align``
     - The start address of a WRAP burst is not aligned to the size of its beats
   * - ``axi4_len_fixed``
     - A FIXED burst is longer than 16 beats
   * - ``axi4_size``
     - AxSIZE is wider than the data bus
   * - ``axi4_cache``
     - AxCACHE sets allocate bits (3 and 2) on a non-modifiable transaction (bit 1 is 0)
   * - ``axi4_excl``
     - An exclusive access (AxLOCK 1) that is not a power of 2 bytes up to 128, not aligned to its size,
       or longer than 16 beats; or an EXOKAY response to a normal access, which includes every EXOKAY on
       AXI4-Lite
   * - ``axi4_wlast``
     - WLAST is 1 on a beat that is not the last of its burst, or 0 on the last
   * - ``axi4_rlast``
     - RLAST is 1 on a beat that is not the last of its burst, or 0 on the last
   * - ``axi4_wstrb``
     - WSTRB is 1 for a byte lane outside the lanes the address and size of the beat give it
   * - ``axi4_unexpected_resp``
     - A B handshake without a write with its ID whose data is complete, or an R handshake without an
       outstanding read with its ID
   * - ``axi4_timeout``
     - A transaction waited longer than ``timeout_cycles`` for its response, write data for its address,
       or VALID for READY; reported once each
   * - ``axi4_scoreboard``
     - Run by the monitor, see :doc:`axi4_monitor`

The message starts with the check ID in upper case, for example
``AXI4_WLAST: WLAST is 1 on beat 0 of 2 of the write ID 0 at 0x10 (2 x 4 bytes) at 35000000 fs``. The
burst length is authoritative: a transaction ends after ``AxLEN + 1`` beats whatever WLAST or RLAST
say, so a wrong LAST is reported once and the transactions after it are still followed.

Responses of different IDs may come in any order, and read data of different IDs may interleave, as
AXI4 allows. Responses with the same ID belong to the oldest transaction with that ID.

Procedures
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`set_check_enabled <axi4_protocol_checker_pkg.set_check_enabled>`
     - Enable or disable one check; a disabled check neither reports nor counts
   * - :vhdl:`get_check_count <axi4_protocol_checker_pkg.get_check_count>`,
       :vhdl:`await_get_check_count_reply <axi4_protocol_checker_pkg.await_get_check_count_reply>`
     - The violations of one check found while it was enabled
   * - ``reset``
     - Counts to 0 and the history of the interface forgotten; the switches are kept

Count violations in a negative test
-----------------------------------

A negative test lets the checker report without stopping, counts, and resets the log count so the test
ends clean (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_examples.vhd
   :caption: examples/axi4/tb_axi4_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: violation
   :end-before: -- docs-end: violation
   :dedent:

A violation that is not counted still fails the test at ``test_runner_cleanup``.

Python backend
--------------

The checker creates an :py:class:`~awesome_vunit_vcs.axi4.vunit_backend.Axi4ProtocolCheckerBackend`,
which runs an :py:class:`~awesome_vunit_vcs.axi4.checker.Axi4ProtocolChecker`. The records are those of
the monitor. They go to Python when 4096 words are waiting, before a message is handled, and every
``timeout_cycles`` clock cycles with a tick record of their own, so a transaction that never completes
is reported while the test still waits for it.

.. note::

   * Violations are reported when the records reach Python, so a log line can come up to
     ``timeout_cycles`` cycles after the violation; its message gives the time of the violation.
   * Same-ID ordering and write data interleaving cannot be seen on the pins of AXI4, which has no WID;
     they show up as ``AXI4_WLAST``, ``AXI4_RLAST`` or ``AXI4_WSTRB`` violations or as scoreboard
     differences.
   * Recommendations of the specification that are not rules, such as READY within a number of cycles,
     are covered only by ``timeout_cycles``.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#axi4-protocol-checker>`__.
