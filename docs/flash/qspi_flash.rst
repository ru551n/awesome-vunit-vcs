QSPI NOR flash
==============

The :vhdl:`flash` component is a QSPI NOR flash that your design reads, programs and erases over its
pins. A testbench sets it up and inspects it with VHDL procedures and never writes Python.

When to use it
--------------

Use the flash when your design is a flash controller, or boots from or stores data in serial NOR
flash. The device is a generic :term:`JEDEC` part: every value that differs between two parts is a
parameter of :vhdl:`flash_pkg.new_flash`. The defaults describe a 16 MiB part, so a test only names
what it cares about.

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`flash`
   * - Bus
     - QSPI in SPI mode 0: the flash samples on the rising edge of SCK and drives its outputs
       ``t_clqv`` after the falling edge
   * - Lanes
     - x1, x2 and x4 phases as each command defines them, and :term:`QPI` (``0x38``), where every
       phase including the opcode is x4
   * - Addressing
     - 3- and 4-byte addressing, switched with ``0xB7`` and ``0xE9`` and limited by ``addr_modes``,
       plus commands with a fixed 4-byte address
   * - Features
     - :term:`Continuous read <continuous read>` (XIP), :term:`SFDP` (basic parameter table), status
       registers 1 to 3, status register and region protection, busy times with :term:`WIP`, deep
       power-down, software reset
   * - Content
     - Sparse storage that reads ``0xFF`` where nothing was written, preloaded from arrays, fills
       and Intel HEX, S-record, binary and JSON images
   * - Pin timing
     - Checked by a :doc:`qspi_protocol_checker` passed as ``protocol_checker``; none by default
   * - Python model
     - :py:class:`~awesome_vunit_vcs.flash.device.FlashDevice`, configured with
       :py:class:`~awesome_vunit_vcs.flash.config.FlashConfig`
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
     - ``IO0`` to ``IO3`` driven by the controller
   * - ``s2m.io.value``, ``s2m.io.enable``
     - out
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` driven by the flash

* ``s2m`` has the initial value ``qspi_s2m_init``, no lane driven.
* A single-lane phase uses ``IO0`` from the controller (MOSI) and ``IO1`` from the flash (MISO).
* Dual and quad phases use ``IO1`` to ``IO0`` and ``IO3`` to ``IO0`` in both directions, with the most
  significant bit of a beat on the highest lane.
* The flash releases its lanes ``t_shqz`` after CS rises and during dummy cycles.
* The :term:`handle` is the only generic: ``flash : flash_t``.

Create the flash
~~~~~~~~~~~~~~~~

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_constructors
   :end-before: -- docs-end: flash_constructors
   :dedent: 2

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_instances
   :end-before: -- docs-end: flash_instances
   :dedent: 2

``tests/vhdl/tb_flash.vhd`` connects QSPI masters to flashes; these are a master and a flash with a
protocol checker. Every parameter has a default, and :ref:`flash-common-options` lists them.

Preload a flash image
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: vhdl
   :caption: A typical setup

   reset(net, boot_flash);
   flash_set_timing_enable(net, boot_flash, false);
   flash_preload(net, boot_flash, 16#000000#, std_ulogic_vector'(x"01020304"));
   flash_load_image(net, boot_flash, tb_path(runner_cfg) & "fw.bin",
                    format => "bin", base_address => 16#400000#);
   flash_set_protection(net, boot_flash, 16#000000#, 16#001000#, locked => true);

Procedures that return nothing only send a message: the flash handles its messages in order, and
``wait_until_idle(net, as_sync(flash))`` waits for them. The others block until the reply, or have a
non-blocking form that returns a reference redeemed with the matching ``await_`` procedure.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`flash_preload(net, flash, address, data) <flash_pkg.flash_preload>`
     - Write bytes, an ``integer_array_t`` the caller keeps or a ``std_ulogic_vector`` whose leftmost
       byte goes to ``address``. Meant for small data, up to a few KiB; fill or load an image for more
   * - :vhdl:`flash_preload_fill(net, flash, address, num_bytes, value) <flash_pkg.flash_preload_fill>`
     - Fill a region with ``value`` (``16#FF#`` by default); cheap for a region of any size
   * - :vhdl:`flash_load_image(net, flash, file_name, format, base_address) <flash_pkg.flash_load_image>`
     - Load an image file; ``format => "auto"`` picks the format from the extension

Preloads and images are test setup, not device operations: they ignore :term:`WEL` and protection,
overwrite without NOR semantics and are not written regions. Every address range must lie inside the
device and every value must be a byte, 0 to 255: a range past the end is reported as a failure on the
logger and nothing is written, never wrapped. ``value`` of the fill procedures is a
``natural range 0 to 255``, and an array element outside it is reported the same way.

.. list-table::
   :header-rows: 1
   :widths: 12 38 50

   * - Format
     - Extensions
     - Notes
   * - ``hex``
     - ``.hex``, ``.ihex``, ``.ihx``
     - Intel HEX, sparse; checksums are verified
   * - ``srec``
     - ``.srec``, ``.s19``, ``.s28``, ``.s37``, ``.mot``
     - Motorola S-record, sparse; checksums are verified
   * - ``bin``
     - ``.bin``, ``.img``, ``.raw``
     - Raw bytes placed at ``base_address``
   * - ``json``
     - ``.json``
     - A list of regions, or an object with an optional ``base`` and a ``regions`` list

For the formats other than ``bin``, ``base_address`` is an offset added to every address. A JSON
region has an ``addr`` and one of ``hex``, ``data`` or ``fill`` with ``length``; a fill stays sparse:

.. code-block:: json
   :caption: A JSON image

   {"base": 0, "regions": [
       {"addr": 4096, "hex": "deadbeef"},
       {"addr": 8192, "data": [1, 2, 3]},
       {"addr": 65536, "fill": 0, "length": 1048576}
   ]}

A relative ``file_name`` is relative to the directory the simulator runs in.
``tb_path(runner_cfg) & "boot.hex"`` names a file next to the testbench.

Check what the DUT wrote
~~~~~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_sector_erase
   :end-before: -- docs-end: flash_sector_erase
   :dedent: 8

This test erases a sector over the bus and checks the result in the model. ``poll_until_ready`` and
``send_raw_byte`` are helpers of the testbench.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`flash_read_back(net, flash, address, num_bytes, data) <flash_pkg.flash_read_back>`
     - Blocking: the content as a new byte array the caller deallocates; also non-blocking with
       :vhdl:`flash_pkg.await_flash_read_back_reply`
   * - :vhdl:`flash_check_content(net, flash, address, expected) <flash_pkg.flash_check_content>`
     - Compare the content with ``expected``, an ``integer_array_t`` the caller keeps or a
       ``std_ulogic_vector`` of whole bytes with the byte of ``address`` leftmost
   * - :vhdl:`flash_check_content_fill(net, flash, address, num_bytes, value) <flash_pkg.flash_check_content_fill>`
     - Compare a region with a constant, ``16#FF#`` (erased) by default, for example to prove an erase
   * - :vhdl:`flash_get_written_regions <flash_pkg.flash_get_written_regions>`
     - Blocking: a flat ``[address, length, ...]`` array of everything programmed or erased over the
       bus, coalesced; also non-blocking with :vhdl:`flash_pkg.await_flash_get_written_regions_reply`

There is no VUnit memory model view of the content; read and check it with these procedures.

Control busy times and protection
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`flash_set_timing_enable(net, flash, enable) <flash_pkg.flash_set_timing_enable>`
     - False makes every busy time 0 and also ends a busy period that is running, so WIP reads clear
       and ``flash_wait_until_ready`` returns; true, the default, applies the busy times to commands
       that follow
   * - :vhdl:`flash_set_timing(net, flash, name, duration) <flash_pkg.flash_set_timing>`
     - Override one busy time: ``"tPP"``, ``"tSE"``, ``"tBE32"``, ``"tBE64"``, ``"tCE"``, ``"tW"``,
       ``"tRST"``, ``"tRES1"`` or ``"tRES2"``. It applies to busy periods that start afterwards; another
       name is a failure on the logger that lists the valid ones
   * - :vhdl:`flash_set_protection(net, flash, address, num_bytes, locked) <flash_pkg.flash_set_protection>`
     - Lock (``locked => true``, the default) or unlock a region in addition to the status register
       protection. Locks survive a ``reset``
   * - :vhdl:`flash_wait_until_ready(net, flash, timeout) <flash_pkg.flash_wait_until_ready>`
     - Blocking: wait until a busy time the component started is over. ``timeout`` defaults to 1 min,
       longer than the default ``t_ce``; a timeout is a failure

Reset the flash between tests
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:vhdl:`reset(net, flash, clear_statistics) <flash_pkg.reset>` blocks and returns the flash to standby,
as a power-on reset:

* Status registers, WEL, addressing and QPI mode, continuous read, deep power-down and the status
  register protection return to their defaults.
* A busy period ends, so ``flash_wait_until_ready`` returns at once.
* A reset while CS is low drops that transaction: the flash ignores the rest of it, and the next CS
  fall starts a command normally.
* Content and locks are kept, and so are the statistics and written regions unless
  ``clear_statistics => true``.

Read statistics and state
~~~~~~~~~~~~~~~~~~~~~~~~~

:vhdl:`flash_get_stat(net, flash, name, value) <flash_pkg.flash_get_stat>` returns one statistic or
piece of state by name. Use it to see why a controller seems to do nothing. :doc:`statistics` lists
every name.

Count errors in a negative test
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_metavalue
   :end-before: -- docs-end: flash_metavalue
   :dedent: 8

Negative tests disable the stop, count the errors and reset the count. This one bit-bangs a metavalue
on a lane the flash samples.

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :caption: tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_protocol_violation
   :end-before: -- docs-end: flash_protocol_violation
   :dedent: 8

This one breaks the ``t_shsl`` of the flash's protocol checker with a CS deselect time that is too
short. The flash checks what the device itself sees: errors are check failures on its checker, and
requests the model cannot carry out are failures on its logger.

Every message a flash reports is listed in :doc:`checks`.

The pin timing of the controller is checked by the protocol checker of the flash, when it has one, on
the checker of the protocol checker. See :doc:`qspi_protocol_checker` for its check IDs.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`set_check_enabled(net, flash, check, enabled) <flash_pkg.set_check_enabled>`,
       :vhdl:`get_check_count(net, flash, check, count) <flash_pkg.get_check_count>` and
       ``get_check_count(net, flash, check, reference)``
     - The procedures of the :doc:`qspi_protocol_checker` for the protocol checker of the flash. A flash
       without one reports ``<id> has no protocol checker`` as a check failure on its checker; the
       blocking ``get_check_count`` then returns 0, and the reference is ``null_msg``
   * - :vhdl:`protocol_checker(flash) <flash_pkg.protocol_checker>`
     - The protocol checker the flash instantiates, with its final id, or ``null_qspi_protocol_checker``
   * - ``get_id``, ``get_logger``, ``get_actor``, ``get_checker``, ``as_sync``
     - The identity of the flash, and its handle for ``wait_until_idle`` and ``wait_for_time``

Look up the supported commands
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:doc:`commands` lists every opcode the flash answers, with its lanes and what it does. Other
opcodes are ignored like on a real part.

Use the model from Python
~~~~~~~~~~~~~~~~~~~~~~~~~

The device model runs without a simulator, for example to test an image or a driver sequence in
``pytest``: construct a :py:class:`~awesome_vunit_vcs.flash.device.FlashDevice` from a
:py:class:`~awesome_vunit_vcs.flash.config.FlashConfig`. Invalid arguments raise
:py:class:`~awesome_vunit_vcs.flash.errors.FlashValueError` and failed content checks raise
:py:class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`, both
:py:class:`~awesome_vunit_vcs.flash.errors.FlashError`. :doc:`python` has an example and
:doc:`python_api` the full API.

See a complete example
~~~~~~~~~~~~~~~~~~~~~~

``tests/vhdl/tb_flash.vhd``, excerpted above, connects QSPI masters to flashes and makes every claim
about bytes that crossed the wires. ``tests/vhdl/tb_flash_boot_example.vhd`` tests a DUT that boots
from a flash image, and :ref:`flash-quick-start` shows it in full. Both run in CI on GHDL and NVC.

.. _flash-common-options:

Common options
--------------

.. code-block:: vhdl
   :caption: A 32 MiB part with 4-byte addressing and pin timing checks

   constant big_flash : flash_t := new_flash(
     size_bytes => 32 * 1024 * 1024,
     addr_bytes => 4,
     jedec_id => 16#20BA19#,
     protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns)
   );

:vhdl:`flash_pkg.new_flash` checks the geometry, identity and busy times when the component starts,
with the rules of :py:class:`~awesome_vunit_vcs.flash.config.FlashConfig`. An invalid combination is
a failure on the logger of the flash, and the model then uses the default configuration so that the
calls that follow stay harmless.

.. list-table::
   :header-rows: 1
   :widths: 22 24 16 38


   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``size_bytes``
     - ``positive``
     - 16 MiB
     - Capacity, a power of two
   * - ``addr_bytes``
     - ``positive range 3 to 4``
     - 3
     - Addressing mode at power-up and after a reset
   * - ``jedec_id``
     - ``natural``
     - ``16#EF4018#``
     - Manufacturer, memory type and capacity bytes of ``0x9F``, 24 bits
   * - ``timing_enabled``
     - ``boolean``
     - true
     - Whether busy times apply at start; false makes every busy time 0
   * - ``protocol_checker``
     - ``qspi_protocol_checker_t``
     - ``null_qspi_protocol_checker``
     - A protocol checker to instantiate on the pins, ``<id>:protocol_checker`` unless it has an id of
       its own; see :doc:`index`
   * - ``id``
     - ``id_t``
     - ``null_id``
     - ``awesome_vunit_vcs:flash:<n>`` when not given; two flashes with the same id are a failure on
       the logger

:doc:`configuration` lists every option: geometry, identity, status registers, busy and output
times, and the standard VUnit parameters.

The busy times are typical rather than worst-case values. A test that depends on one sets it.

Good to know
------------

* **Nothing happens until CS rises.** Program data and status bytes are latched and executed at the
  CS rising edge. A program or status write that ends within a byte, or any command whose address
  phase did not complete (except ``0xAB``), is not executed and counts as ``abort_count``.
* **Refusals are silent.** A command without WEL, while busy, without QE, in deep power-down, or an
  unknown opcode, does nothing and drives nothing, like a real part. So does a program or erase that
  touches a protected byte; it clears WEL unless ``clear_wel_on_protection_reject`` is false.
* **A controller that seems to do nothing** was probably refused: ``ignored_command_count`` and the
  reject counters of the :ref:`statistics <flash-statistics>` say why.
* **NOR semantics.** A page program writes at most ``page_bytes``; bytes past the end of the page wrap
  to the start of the same page, and the last byte written to an offset wins. Programming only clears
  bits, and erasing sets ``0xFF`` over the unit that contains the address.
* **Addresses wrap.** Reads continue past the end of the device from address 0, and a bus address is
  taken modulo ``size_bytes``.
* **Busy time.** A program, erase, status write, software reset or release from deep power-down holds
  WIP for its busy time from the CS rising edge. While busy, only ``0x05``, ``0x35``, ``0x15``,
  ``0xFF``, ``0x66`` and ``0x99`` are accepted, so status polling works.
* **Waiting for ready.** ``flash_wait_until_ready`` cannot see a busy time the component has not
  started yet; the blocking master procedures return after CS has risen, so it can follow them
  directly. A controller that polls the status register over the bus is the stronger check.
* **Continuous read.** A mode byte with ``M5:M4 = 10`` after ``0xBB`` or ``0xEB`` makes the next
  transaction start with the address of the same command, without an opcode. Any other mode byte,
  ``0xFF`` or a reset ends it.
* **Status registers.** The status writes change SR1 bits 7 to 2 (SRP, SEC, TB, BP2..BP0), SR2 bits 6,
  1 and 0 (CMP, QE, SRL) and SR3 bits 7 to 5 and 2. WIP, WEL and SR3's ADS are derived.
* **Protection.** BP2..BP0 protect ``2**(BP-1)`` 64 KiB blocks, or 4 KiB sectors with SEC set, at the
  top of the device, at the bottom with TB set. ``BP = 7`` protects the whole device and CMP inverts
  the region; ``flash_set_protection`` locks regions in addition.
* **Addressing modes.** A ``three_only`` device ignores ``0xB7``, ``0xE9``, ``0x13``, ``0x0C``,
  ``0x12`` and ``0xDC``; a ``four_only`` device ignores ``0xE9``. SFDP advertises the same modes.
* **SFDP.** ``0x5A`` returns a basic parameter table computed from the configuration: density,
  addressing modes and the erase types of ``sector_bytes``, ``block32_bytes`` and ``block_bytes``
  with their opcodes.
* **Bulk content is faster through the preload, image and check procedures** than over the bus.
* **One device per bus.** ``s2m`` has one driver; two devices need two buses.
* **Fixed protection units.** The BP bits count 4 KiB or 64 KiB units whatever the geometry.
* **No hardware write protection.** SRP and SRL have no effect, and there is no WP# pin.
* **Limited 4-byte command set**, no program or erase suspend, and fixed dummy cycles per opcode.
* **Deep power-down** takes no time to enter.
* **Released I/Os are metavalues** when the flash samples them for data in.

Related recipes
---------------

* :doc:`../cookbook/flash_boot`: *Boot a design from an image*, *Check what the design wrote*, *Reset between scenarios*

API reference
-------------

* VHDL: :vhdl:`flash_pkg.new_flash`, :vhdl:`flash_pkg.flash_load_image`,
  :vhdl:`flash_pkg.flash_check_content`, :vhdl:`flash_pkg.flash_get_stat`, :vhdl:`flash_pkg.reset`,
  and the whole family in :doc:`vhdl_api`
* Python: :py:class:`~awesome_vunit_vcs.flash.device.FlashDevice`,
  :py:class:`~awesome_vunit_vcs.flash.config.FlashConfig`, and :doc:`python_api`
