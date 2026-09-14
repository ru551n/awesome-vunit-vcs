Flash and QSPI
==============

The recipes on this page are test cases of the flash family's own testbenches in ``tests/vhdl``, which
CI runs on GHDL and NVC. The flash family has no directory under ``examples``; run a recipe's test
bench through ``tests/vhdl/run.py`` with a test name pattern. :doc:`../flash/index` explains the
family in full.

Preload a flash image and boot from it
--------------------------------------

**Goal:** load an image file into a flash, let the DUT boot from it and check what it read.

.. literalinclude:: ../../tests/vhdl/tb_flash_boot_example.vhd
   :caption: tests/vhdl/tb_flash_boot_example.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-example
   :end-before: -- docs-end: boot-example

**When to use this:** when the DUT reads its firmware, bitstream or configuration from a QSPI NOR
flash at reset.

* ``flash_load_image`` reads Intel HEX, S-record, raw binary and JSON images, by default picking the
  format from the extension. It loads the whole file or nothing.
* Load the image before the DUT leaves reset; the procedure is a message the flash handles at once.
* Without ``protocol_checker``, the flash does not check the DUT's pin timing.

**Full example:** :repo-file:`tests/vhdl/tb_flash_boot_example.vhd`

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash_boot_example.*"

**See also:** :doc:`../flash/index`, :vhdl:`flash_pkg.flash_load_image`

Check what the DUT wrote to the flash
-------------------------------------

**Goal:** check the regions a DUT programmed or erased, and their content.

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-written-regions
   :end-before: -- docs-end: flash-written-regions
   :dedent:

A content check that fails is a check failure on the flash's checker. A test that expects one counts
it:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-content-mismatch
   :end-before: -- docs-end: flash-content-mismatch
   :dedent:

**When to use this:** at the end of a test, to check that the DUT wrote what it should and nothing
else.

* ``flash_get_written_regions`` returns ``[address, length]`` pairs, merged, since the start or the
  last ``clear_statistics``. The caller deallocates the array.
* ``flash_check_content_fill`` checks a constant region, such as an erased one, without building the
  expected bytes.

**Full example:** ``test_written_regions_reports_only_what_was_programmed`` and
``test_content_mismatch_is_a_check_failure``

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash.test_written_regions*"
   $ python tests/vhdl/run.py "lib.tb_flash.test_content_mismatch*"

**See also:** :doc:`../flash/qspi_flash`, :vhdl:`flash_pkg.flash_get_written_regions`,
:vhdl:`flash_pkg.flash_check_content`, :vhdl:`flash_pkg.flash_check_content_fill`

Check QSPI pin timing with a protocol checker
---------------------------------------------

**Goal:** check the controller's pin timing and count the violations.

Give the flash a protocol checker when you create it:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_constructors
   :end-before: -- docs-end: flash_constructors
   :dedent:

A negative test disables the stop on errors, sends traffic that breaks a rule and counts the
violations:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_protocol_violation
   :end-before: -- docs-end: flash_protocol_violation
   :dedent:

The flash and the QSPI master forward ``set_check_enabled`` and ``get_check_count`` to their
protocol checker:

.. literalinclude:: ../../tests/vhdl/tb_flash_vci.vhd
   :caption: tests/vhdl/tb_flash_vci.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-check-forwarding
   :end-before: -- docs-end: flash-check-forwarding
   :dedent:

**When to use this:** in tests of a DUT that drives a QSPI bus, to catch timing a real part would
not accept.

* Violations are check failures on the protocol checker's checker, ``<flash id>:protocol_checker``,
  not on the flash's.
* Pass the limits of your part to ``new_qspi_protocol_checker``; a limit of zero switches its rule
  off.
* Reset the error count at the end of a negative test, so an unexpected error still fails the test.

**Full example:** ``test_protocol_violation_is_reported`` and
``test_check_procedures_forward_to_the_protocol_checker``

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash.test_protocol_violation*"
   $ python tests/vhdl/run.py "lib.tb_flash_vci.test_check_procedures*"

**See also:** :doc:`../flash/qspi_protocol_checker`,
:vhdl:`qspi_protocol_checker_pkg.new_qspi_protocol_checker`, :vhdl:`flash_pkg.set_check_enabled`,
:vhdl:`flash_pkg.get_check_count`

Reset the flash family between examples
---------------------------------------

**Goal:** return the flash, the QSPI master and the protocol checker to a known state inside one
test.

The flash keeps its content and, unless asked to clear them, its statistics:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-reset-statistics
   :end-before: -- docs-end: flash-reset-statistics
   :dedent:

The master aborts the transfer in progress and releases the bus:

.. literalinclude:: ../../tests/vhdl/tb_qspi_master.vhd
   :caption: tests/vhdl/tb_qspi_master.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-master-reset
   :end-before: -- docs-end: qspi-master-reset
   :dedent:

The protocol checker clears its counts and forgets the edges it saw:

.. literalinclude:: ../../tests/vhdl/tb_qspi_protocol_checker.vhd
   :caption: tests/vhdl/tb_qspi_protocol_checker.vhd
   :language: vhdl
   :start-after: -- docs-start: protocol-checker-reset
   :end-before: -- docs-end: protocol-checker-reset
   :dedent:

**When to use this:** when one test runs several scenarios, or after a scenario that leaves a
transfer or a busy period unfinished.

* A flash reset is a power-on reset of the device state, not an erase: preload or erase to change
  the content.
* A flash reset while CS is low makes the flash ignore the rest of that transaction, and it ends a
  busy period.
* VUnit runs every test case in a fresh simulation, so a reset is only needed within a test.

**Full example:** ``test_reset_can_clear_the_statistics``, ``test_reset_aborts_an_in_flight_transfer``
and ``test_reset_clears_counts_and_timing_history``

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash.test_reset*"
   $ python tests/vhdl/run.py "lib.tb_qspi_master.test_reset*"
   $ python tests/vhdl/run.py "lib.tb_qspi_protocol_checker.test_reset*"

**See also:** :doc:`../flash/qspi_flash`, :doc:`../flash/qspi_master`,
:doc:`../flash/qspi_protocol_checker`

Drive custom QSPI transfers with the QSPI master
------------------------------------------------

**Goal:** send flash commands from a testbench, and transfers the command layer does not have.

The command layer sends the common flash commands:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-flash-commands
   :end-before: -- docs-end: qspi-flash-commands
   :dedent:

``qspi_transfer`` sends any transaction: a command, an address, dummy cycles and data, each phase on
its own number of lanes. Here the non-blocking form starts a page program so the test can act while
it runs:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-transfer
   :end-before: -- docs-end: qspi-transfer
   :dedent:

**When to use this:** to set up flash content through the bus as a DUT would, or to send a command
sequence the command layer lacks, such as a read without an opcode in continuous read mode.

* ``qspi_flash_address_bytes`` builds a 3- or 4-byte address; the caller deallocates it.
* With ``reference``, ``qspi_transfer`` returns at once; ``await_qspi_transfer_reply`` waits for the
  end of the transfer.
* Preloading with ``flash_preload`` is much faster than programming over the bus.

**Full example:** ``test_page_program_then_read_back`` and
``test_reset_returns_to_standby_mid_transaction``

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash.test_page_program_then_read_back"
   $ python tests/vhdl/run.py "lib.tb_flash.test_reset_returns*"

**See also:** :doc:`../flash/qspi_master`, :vhdl:`qspi_master_pkg.qspi_transfer`,
:vhdl:`qspi_flash_cmd_pkg.qspi_flash_page_program`
