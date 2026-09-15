Booting a design from QSPI flash
================================

Many FPGA and SoC designs read their firmware or configuration from a QSPI NOR flash when they come out
of reset. To test that, we need a flash that behaves like the real part, with the image already in it.
In this article we start with the simplest flash test, a design booting from an image, and build up to
checking what the design wrote and whether its pin timing is right. Sending our own commands to the
flash comes last, under *Going further*.

Everything in this article is VHDL, in testbench files. The flash image is a data file, and no Python
code of your own is needed. The examples are the flash testbenches in ``tests/vhdl``, which CI runs on
GHDL and NVC:

.. list-table::
   :header-rows: 1
   :widths: 45 15 40

   * - File
     - Language
     - What it holds
   * - ``tests/vhdl/tb_flash_boot_example.vhd``
     - VHDL
     - The complete boot test of steps 1 and 2.
   * - ``tests/vhdl/flash_boot_image.hex``
     - Intel HEX
     - The image the flash is loaded with.
   * - ``tests/vhdl/tb_flash.vhd``
     - VHDL
     - The flash tests used in the later steps.

Run a test through ``tests/vhdl/run.py`` with its name:

.. code-block:: console
   :caption: Terminal

   $ python tests/vhdl/run.py "lib.tb_flash_boot_example.*"

Step 1: boot a design from an image
-----------------------------------

Here is the whole test. A small boot reader is the design under test:

.. literalinclude:: ../../tests/vhdl/tb_flash_boot_example.vhd
   :caption: tests/vhdl/tb_flash_boot_example.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-example
   :end-before: -- docs-end: boot-example

Let's follow it:

#. ``context awesome_vunit_vcs.flash_context`` is the only context clause a flash testbench needs.
#. ``new_flash`` creates the flash handle. The flash entity connects to the design through two record
   signals, ``m2s`` (master to slave) and ``s2m`` (slave to master).
#. ``flash_load_image`` puts the image into the flash before the design leaves reset. It reads Intel HEX,
   S-record, raw binary and JSON files, and picks the format from the file extension.
#. The test releases the reset and waits for the design to finish booting.

Step 2: check what the design read and wrote
--------------------------------------------

The same test ends with two checks. ``flash_check_content`` compares the flash with what the design
copied into its RAM, so we know it read the image correctly. ``flash_get_written_regions`` returns the
regions the design programmed or erased, and a boot should leave none.

For a design that stores data, the written regions are what you check. After it has written, ask the
flash which regions changed and compare their content:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-written-regions
   :end-before: -- docs-end: flash-written-regions
   :dedent:

The regions come back as merged ``[address, length]`` pairs. Deallocate the array when you're done. To
check an erased or otherwise constant region, ``flash_check_content_fill`` saves building the expected
bytes.

A content check that fails is a check failure. When a test expects a mismatch, it counts it, the same
way :doc:`error_handling` counts Ethernet errors:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-content-mismatch
   :end-before: -- docs-end: flash-content-mismatch
   :dedent:

Step 3: check the pin timing
----------------------------

A design can read the right data with timing a real flash wouldn't accept. To catch that, give the flash
a :term:`protocol checker` with your part's limits when you create it:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_constructors
   :end-before: -- docs-end: flash_constructors
   :dedent:

A limit of zero switches its rule off. Without a protocol checker, the flash doesn't check timing at
all; the boot test of step 1 uses one with default limits.

A negative test sends traffic that breaks a rule and counts the violations:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_protocol_violation
   :end-before: -- docs-end: flash_protocol_violation
   :dedent:

Violations are reported by the protocol checker, named ``<flash id>:protocol_checker``. The flash passes
``set_check_enabled`` and ``get_check_count`` on to it, so you don't need to look it up:

.. literalinclude:: ../../tests/vhdl/tb_flash_vci.vhd
   :caption: tests/vhdl/tb_flash_vci.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-check-forwarding
   :end-before: -- docs-end: flash-check-forwarding
   :dedent:

Step 4: reset between scenarios
-------------------------------

VUnit runs every test case in a fresh simulation, so separate tests never need a reset. Within one test,
though, a scenario can leave a transfer or a busy period unfinished. Then reset the components.

The flash returns to its power-on state. It keeps its content, and its statistics unless you ask it to
clear them:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash-reset-statistics
   :end-before: -- docs-end: flash-reset-statistics
   :dedent:

The protocol checker clears its counts and forgets the edges it saw:

.. literalinclude:: ../../tests/vhdl/tb_qspi_protocol_checker.vhd
   :caption: tests/vhdl/tb_qspi_protocol_checker.vhd
   :language: vhdl
   :start-after: -- docs-start: protocol-checker-reset
   :end-before: -- docs-end: protocol-checker-reset
   :dedent:

A flash reset is not an erase. To change the content, preload or erase it.

Going further: send your own commands
-------------------------------------

So far the design under test did all the talking. The QSPI master component lets the testbench talk to
the flash too, for example to set up content through the bus as a design would. When you only need
content in the flash, ``flash_preload`` or ``flash_load_image`` is much faster.

The command layer sends the common flash commands:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-flash-commands
   :end-before: -- docs-end: qspi-flash-commands
   :dedent:

For anything the command layer doesn't have, ``qspi_transfer`` sends a transaction of your own: a
command, an address, dummy cycles and data, each on its own number of lanes. Here the non-blocking form
starts a page program, so the test can act while it runs, and ``await_qspi_transfer_reply`` waits for it
to end:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-transfer
   :end-before: -- docs-end: qspi-transfer
   :dedent:

Reset the master between scenarios too; it aborts its transfer and releases the bus:

.. literalinclude:: ../../tests/vhdl/tb_qspi_master.vhd
   :caption: tests/vhdl/tb_qspi_master.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi-master-reset
   :end-before: -- docs-end: qspi-master-reset
   :dedent:

Where to go next
----------------

* :doc:`../flash/qspi_flash` lists every flash option, and :doc:`../flash/commands` every command.
* :doc:`../flash/qspi_master` and :doc:`../flash/qspi_protocol_checker` cover the other components.
