QSPI protocol checker
=====================

The :vhdl:`qspi_protocol_checker` component passively observes a QSPI bus and checks the pin timing the
master must meet. It never drives a pin.

When to use it
--------------

Use the protocol checker to check that a flash controller DUT, or a :doc:`qspi_master`, meets its pin
timing: SCK period, high and low time, CS setup, hold and deselect time, and the setup and hold of
the data lanes it drives. Each rule has a check ID, a minimum time, a switch and a violation count.

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`qspi_protocol_checker`
   * - Bus
     - QSPI in SPI mode 0: the device samples on the rising edge of SCK
   * - Lanes
     - Data setup and hold apply to the lanes the master drives (``m2s.io.enable``) at a rising edge,
       so x1, x2, x4 and :term:`QPI` phases are covered alike, and undriven lanes and dummy cycles are
       not checked
   * - Checked side
     - The master's pins only (``m2s``). The output delays of a device are applied by the flash, not
       checked
   * - Tested on
     - GHDL, NVC

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 12 33 30

   * - Port and field
     - Direction
     - Type
     - Signal
   * - ``m2s.sck``
     - in
     - ``std_ulogic``
     - ``CLK``
   * - ``m2s.cs_n``
     - in
     - ``std_ulogic``
     - ``/CS``
   * - ``m2s.io.value``, ``m2s.io.enable``
     - in
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` as driven by the master
   * - ``s2m.io.value``, ``s2m.io.enable``
     - in, default ``qspi_s2m_init``
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` as driven by the device; no current rule uses them

The :term:`handle` is the only generic: ``protocol_checker : qspi_protocol_checker_t``.

Create the checker
~~~~~~~~~~~~~~~~~~

The simplest way is to pass a checker as the ``protocol_checker`` parameter of
:vhdl:`flash_pkg.new_flash` or :vhdl:`qspi_master_pkg.new_qspi_master`. They instantiate it on their own
pins as ``<parent id>:protocol_checker`` (see :doc:`index`). This flash's checker requires a CS
deselect time of 30 ns:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing-handles
   :end-before: -- docs-end: timing-handles
   :dedent:

To check a bus without a flash or master of this package, instantiate the
:vhdl:`qspi_protocol_checker` entity on the bus signals instead, with its handle as the only generic.

Check the pin timing
~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing-violation
   :end-before: -- docs-end: timing-violation
   :dedent:

The master keeps CS high too briefly between two commands, and the test counts the one violation.

.. list-table::
   :header-rows: 1
   :widths: 22 30 48

   * - Check ID
     - Interval
     - Notes
   * - ``QSPI_SCK_PERIOD``
     - SCK rising edge to the next rising edge
     - Measured whatever CS is; an interval across an idle gap is longer than any limit
   * - ``QSPI_SCK_HIGH``
     - SCK rising edge to the next falling edge
     - Measured whatever CS is
   * - ``QSPI_SCK_LOW``
     - SCK falling edge to the next rising edge
     - Measured whatever CS is
   * - ``QSPI_CS_SETUP``
     - CS falling edge to the first SCK rising edge of the command
     -
   * - ``QSPI_CS_HOLD``
     - Last SCK rising edge while CS is low to the CS rising edge
     - Not measured for a command without SCK rising edges
   * - ``QSPI_CS_DESELECT``
     - CS rising edge to the next CS falling edge (:term:`tSHSL`)
     - Not measured before the first CS rising edge
   * - ``QSPI_DATA_SETUP``
     - Latest change of the value or the enable of a lane the master drives at an SCK rising edge while
       CS is low, to that edge
     - Lanes the master does not drive at the edge are not checked
   * - ``QSPI_DATA_HOLD``
     - SCK rising edge while CS is low to a change of the value or the enable of a lane the master drove
       at that edge
     - Releasing a driven lane too early breaks the hold time like changing it

A violation is a check failure on the checker of the protocol checker. The message starts with the
check ID, and times are in ns with up to three decimals:

.. code-block:: text
   :caption: A violation in the log

   QSPI_CS_DESELECT: CS high time between commands 25 ns is shorter than the 30 ns minimum

Switch rules and count violations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: switch-rule
   :end-before: -- docs-end: switch-rule
   :dedent:

This test switches the CS deselect rule off, sends the same two commands as above without a violation,
and switches the rule on again.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`set_check_enabled(net, protocol_checker, check, enabled) <qspi_protocol_checker_pkg.set_check_enabled>`
     - Switch one rule, a :vhdl:`qspi_protocol_checker_pkg.qspi_check_t`, on or off. A disabled rule
       neither reports nor counts. Not blocking; the next message to the checker sees it
   * - :vhdl:`get_check_count(net, protocol_checker, check, count) <qspi_protocol_checker_pkg.get_check_count>`
     - Blocking: the violations of a rule found while it was enabled
   * - ``get_check_count(net, protocol_checker, check, reference)`` and
       :vhdl:`await_get_check_count_reply <qspi_protocol_checker_pkg.await_get_check_count_reply>`
     - The same, non-blocking and redeemed later
   * - ``get_id``, ``get_logger``, ``get_actor``, ``get_checker``, ``as_sync``
     - The identity of the checker. ``wait_until_idle(net, as_sync(protocol_checker))`` and
       ``wait_for_time`` of ``sync_pkg`` work
   * - :vhdl:`qspi_protocol_checker_pkg.t_sck_min` to :vhdl:`qspi_protocol_checker_pkg.t_chdx`,
       :vhdl:`limit(protocol_checker, check) <qspi_protocol_checker_pkg.limit>`
     - The limits the handle was created with

The checker keeps one violation count per rule, and a count only grows while its rule is enabled. The
log counts of ``get_logger(protocol_checker)`` are the other view, and the one a negative test resets.

A flash or a QSPI master that owns a protocol checker has the same procedures,
:vhdl:`flash_pkg.set_check_enabled`, :vhdl:`flash_pkg.get_check_count`,
:vhdl:`qspi_master_pkg.set_check_enabled` and :vhdl:`qspi_master_pkg.get_check_count`. They act on
that checker.

Reset the checker
~~~~~~~~~~~~~~~~~

:vhdl:`reset(net, protocol_checker) <qspi_protocol_checker_pkg.reset>` blocks and sets every violation
count to 0. It also forgets the timing history, such as the time CS last rose, so the first command
after a reset of the bus is not measured against the edges before it. The rule switches are kept.

Common options
--------------

:vhdl:`new_qspi_protocol_checker <qspi_protocol_checker_pkg.new_qspi_protocol_checker>` takes the
minimum times of a typical 133 MHz part. A limit of ``0 ns`` disables its rule.

.. list-table::
   :header-rows: 1
   :widths: 25 20 18 37

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``t_sck_min``
     - ``delay_length``
     - 7519 ps
     - Minimum SCK period, ``QSPI_SCK_PERIOD``
   * - ``t_sck_high_min``
     - ``delay_length``
     - 3 ns
     - Minimum SCK high time, ``QSPI_SCK_HIGH``
   * - ``t_sck_low_min``
     - ``delay_length``
     - 3 ns
     - Minimum SCK low time, ``QSPI_SCK_LOW``
   * - ``t_slch``
     - ``delay_length``
     - 5 ns
     - CS low to the first SCK rising edge, ``QSPI_CS_SETUP``
   * - ``t_chsh``
     - ``delay_length``
     - 5 ns
     - Last SCK rising edge to CS high, ``QSPI_CS_HOLD``
   * - ``t_shsl``
     - ``delay_length``
     - 30 ns
     - CS high time between commands, ``QSPI_CS_DESELECT``
   * - ``t_dvch``
     - ``delay_length``
     - 2 ns
     - Data setup before the SCK rising edge, ``QSPI_DATA_SETUP``
   * - ``t_chdx``
     - ``delay_length``
     - 3 ns
     - Data hold after the SCK rising edge, ``QSPI_DATA_HOLD``
   * - ``id``
     - ``id_t``
     - ``null_id``
     - ``awesome_vunit_vcs:qspi_protocol_checker:<n>`` when not given; see :doc:`index` for the id a
       flash or master gives a checker it owns
   * - ``logger``
     - ``logger_t``
     - ``null_logger``
     - The logger of the id when not given
   * - ``actor``
     - ``actor_t``
     - ``null_actor``
     - A new actor of the id when not given
   * - ``checker``
     - ``checker_t``
     - ``null_checker``
     - A new checker on the logger when not given
   * - ``unexpected_msg_type_policy``
     - ``unexpected_msg_type_policy_t``
     - ``fail``
     - ``fail`` makes a message of an unknown type a check failure on the checker, ``Got unexpected
       message <type>``; ``ignore`` drops it

Good to know
------------

* **Minimum times only.** Every rule is a lower bound on an interval between edges. Maximum times,
  such as a maximum CS low time, are not checked.
* **The master's obligations only.** ``s2m`` is unused by the current rules: the device's output
  timing (tCLQV, tSHQZ) and bus contention are not checked.
* **SPI mode 0.** Data setup and hold are measured around the SCK rising edge.
* **Picosecond messages.** Times in messages are truncated to whole picoseconds.
* **One checker per bus.** A checker in both the master and the flash of one bus reports every
  violation twice.

Related recipes
---------------

* :doc:`../cookbook/flash_boot`: *Check the pin timing*, *Reset between scenarios*

API reference
-------------

* VHDL: :vhdl:`qspi_protocol_checker_pkg.new_qspi_protocol_checker`,
  :vhdl:`qspi_protocol_checker_pkg.qspi_check_t`, :vhdl:`qspi_protocol_checker_pkg.set_check_enabled`,
  :vhdl:`qspi_protocol_checker_pkg.get_check_count`, :vhdl:`qspi_protocol_checker_pkg.reset`, and the
  whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
