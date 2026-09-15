Booting a design from QSPI flash
================================

Many FPGA and SoC designs read their firmware or configuration from a QSPI NOR flash when they come out
of reset. To test that, we need a flash that behaves like the real part, with the image already in it.
In this article we start with the simplest flash test, a design booting from an image, and build up to
checking what was written and whether the pin timing is right. Sending our own commands to the flash
comes last, under *Going further*.

Everything in this article is VHDL, in one testbench. The flash image is a data file, and no Python code
of your own is needed. The example project is ``examples/flash``:

.. list-table::
   :header-rows: 1
   :widths: 45 15 40

   * - File
     - Language
     - What it holds
   * - ``examples/flash/tb_flash_examples.vhd``
     - VHDL
     - The testbench, with one test case per step.
   * - ``examples/flash/src/boot_reader.vhd``
     - VHDL
     - The design under test: a boot loader that copies the image into its RAM.
   * - ``examples/flash/flash_boot_image.hex``
     - Intel HEX
     - The image the flash is loaded with.
   * - ``examples/flash/run.py``
     - Python
     - The run script.

Run one step's test by name:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/flash/run.py "*test_boot_from_an_image"

Step 1: set up the testbench (VHDL)
-----------------------------------

A flash testbench needs one context clause:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

The architecture creates a flash with ``new_flash`` and the signals of its bus. The flash connects to the
design through two record signals, ``m2s`` (master to slave) and ``s2m`` (slave to master). This flash
also gets a :term:`protocol checker`, so the design's pin timing is checked:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-handles
   :end-before: -- docs-end: boot-handles
   :dedent:

Then the flash and the design under test are instantiated on that bus:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-instances
   :end-before: -- docs-end: boot-instances
   :dedent:

The design under test is a small boot loader. When its reset is released, it reads a 4-byte length
header from address 0 with fast read (``0x0B``), most significant byte first, and then the whole image
into its RAM. It drives its QSPI pins with a ``qspi_master``, so your own boot design can take its place
on the same ``m2s`` and ``s2m`` signals:

.. dropdown:: The design under test, boot_reader.vhd

   .. literalinclude:: ../../examples/flash/src/boot_reader.vhd
      :caption: examples/flash/src/boot_reader.vhd
      :language: vhdl
      :start-after: http://mozilla.org/MPL/2.0/.

The process declares the variables the later steps use:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: variables
   :end-before: -- docs-end: variables
   :dedent:

Step 2: boot from an image (VHDL)
---------------------------------

The first test loads the image, releases the design's reset and waits for the boot to finish:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-test
   :end-before: -- docs-end: boot-test
   :dedent:

Let's follow it:

#. ``flash_load_image`` puts the image into the flash before the design leaves reset. It reads Intel HEX,
   S-record, raw binary and JSON files, and picks the format from the file extension.
#. The design reads a length header and then the image, and raises ``boot_done``.
#. ``flash_check_content`` compares the flash content with what the design copied into its RAM.

A boot should only read. ``flash_get_written_regions`` returns the regions that were programmed or
erased, as ``[address, length]`` pairs, so a boot leaves none:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-writes-nothing
   :end-before: -- docs-end: boot-writes-nothing
   :dedent:

Deallocate the array when you're done.

Step 3: check what was written (VHDL)
-------------------------------------

For a design that stores data, the written regions are what you check. Here the testbench's own
QSPI master component plays the part of such a design. Add it and a second flash on their own bus:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: master-handles
   :end-before: -- docs-end: master-handles
   :dedent:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: master-instances
   :end-before: -- docs-end: master-instances
   :dedent:

The master programs four octets, and ``flash_wait_until_ready`` waits for the flash to finish:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: program
   :end-before: -- docs-end: program
   :dedent:

Then ask the flash what changed and check the content:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: written-regions
   :end-before: -- docs-end: written-regions
   :dedent:

Byte data can be a ``std_ulogic_vector`` literal such as ``x"DEADBEEF"``. ``flash_check_content`` is a
message to the flash, so ``wait_until_idle`` waits until the flash has checked it. To check an erased or
otherwise constant region, ``flash_check_content_fill`` saves building the expected bytes.

Step 4: count a content mismatch (VHDL)
---------------------------------------

A content check that fails is an error on the flash's logger. When a test expects a mismatch, it counts
it, the same way :doc:`error_handling` counts Ethernet errors:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: content-mismatch
   :end-before: -- docs-end: content-mismatch
   :dedent:

Step 5: check the pin timing (VHDL)
-----------------------------------

A design can read the right data with timing a real flash wouldn't accept. The protocol checker of a
flash catches that. Its limits are parameters of ``new_qspi_protocol_checker``, and a limit of zero
switches its rule off. This bus has a master that keeps CS high too briefly between commands:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing-handles
   :end-before: -- docs-end: timing-handles
   :dedent:

A negative test sends two commands and counts the violation:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing-violation
   :end-before: -- docs-end: timing-violation
   :dedent:

Violations are reported by the protocol checker, named ``<flash id>:protocol_checker``; count them on its
logger. ``get_check_count`` and ``set_check_enabled`` take the flash and pass on to its protocol checker,
so you don't need to look it up. Without a protocol checker, a flash doesn't check timing at all.

Step 6: reset between scenarios (VHDL)
--------------------------------------

VUnit runs every test case in a fresh simulation, so separate tests never need a reset. Within one test,
though, a scenario can leave a transfer or a busy period unfinished. Then reset the components:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: reset
   :end-before: -- docs-end: reset
   :dedent:

The flash returns to its power-on state. It keeps its content, and its statistics unless you ask it to
clear them. The master aborts a transfer in progress and releases the bus. A protocol checker clears its
counts:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: protocol-checker-reset
   :end-before: -- docs-end: protocol-checker-reset
   :dedent:

Step 7: test write protection (VHDL)
------------------------------------

A flash can lock regions against programs and erases, for example to keep a boot loader safe from a
bad firmware update. A real part refuses a program to a locked region silently: nothing changes and no
error is reported. Only the status register shows it. To test that a design copes, lock a region and
let the design try to write it:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: write-protection
   :end-before: -- docs-end: write-protection
   :dedent:

Let's follow it:

#. ``flash_set_protection`` locks 4 KiB from address 0. A region is locked or unlocked here directly, as
   the lock bits of a real part would set it.
#. The program is refused. ``flash_get_stat`` counts the refusal as ``protect_reject_count``, and the
   content stays erased.
#. ``wel``, the write-enable latch, is 0 after the refusal. Parts differ here: some keep write enable
   set. ``clear_wel_on_protection_reject`` picks the behaviour of your part:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: keep-wel-handles
   :end-before: -- docs-end: keep-wel-handles
   :dedent:

This flash needs a master and a bus of its own, instantiated next to the others:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: keep-wel-instances
   :end-before: -- docs-end: keep-wel-instances
   :dedent:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: keep-wel-test
   :end-before: -- docs-end: keep-wel-test
   :dedent:

A refusal isn't an error, but some requests are: a statistic that doesn't exist, an address outside the
device or an image that can't be read. The flash reports those as a *failure* on its logger, one level
above the errors of steps 4 and 5, so a test that expects one disables the stop at that level:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: failed-request
   :end-before: -- docs-end: failed-request
   :dedent:

:ref:`flash-error-levels` lists which level each kind of error uses.

Going further: send your own commands
-------------------------------------

So far the testbench used the command layer only to stand in for a design. It can send any command.
When you only need content in the flash, ``flash_load_image`` or ``flash_preload`` is much faster.

The command layer sends the common flash commands:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: commands
   :end-before: -- docs-end: commands
   :dedent:

Read data comes back as a byte array, which the caller deallocates.

For anything the command layer doesn't have, ``qspi_transfer`` sends a transaction of your own: a
command, an address, dummy cycles and data, each a byte array with its own number of lanes.
``new_byte_array`` builds a byte array from integers. The simplest form blocks until the transaction is
done and returns the bytes it read. Here it reads the three ID bytes that follow the ``0x9F`` command:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: read-transfer
   :end-before: -- docs-end: read-transfer
   :dedent:

``got`` is a new byte array with ``num_read_bytes`` bytes, which the test deallocates.

The non-blocking form returns at once, so the test can act while the transfer runs, and
``await_qspi_transfer_reply`` waits for it to end:

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: transfer
   :end-before: -- docs-end: transfer
   :dedent:

``qspi_transfer`` copies the arrays, so the test deallocates them straight away.

Where to go next
----------------

* :doc:`../flash/qspi_flash` lists every flash option, and :doc:`../flash/commands` every command.
* :doc:`../flash/qspi_master` and :doc:`../flash/qspi_protocol_checker` cover the other components.
