QSPI NOR flash
==============

Overview
--------

The ``flash`` verification component (VC) is a QSPI NOR flash that a DUT controller reads, programs
and erases over its pins. The VHDL entity owns the pins and simulation time: it samples and drives
the I/O lanes at the SCK edges and applies the output delays. Every decision about what the bytes on
the wire mean, from the opcode table to NOR semantics, protection and busy times, is taken by its
Python backend, a :class:`~awesome_vunit_vcs.flash.device.FlashDevice` that also runs without a
simulator.

The device is a generic JEDEC part. Every value that differs between two parts is a parameter of
:vhdl:`flash_pkg.new_flash`, and the defaults describe a 16 MiB part, so a test only names what it
cares about. A testbench sets the device up and inspects it with the procedures below and never
writes Python.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Bus
     - QSPI in SPI mode 0: the flash samples on the rising edge of SCK and drives its outputs
       ``t_clqv`` after the falling edge
   * - Lanes
     - x1, x2 and x4 phases as each command defines them, and QPI (``0x38``), where every phase
       including the opcode is x4
   * - Addressing
     - 3- and 4-byte addressing, switched with ``0xB7`` and ``0xE9`` and limited by ``addr_modes``,
       plus commands with a fixed 4-byte address
   * - Features
     - Continuous read (XIP), SFDP (JESD216 basic parameter table), status registers 1 to 3, status
       register and region protection, busy times with write-in-progress, deep power-down, software
       reset
   * - Content
     - Sparse storage that reads ``0xFF`` where nothing was written, preloaded from arrays, fills
       and Intel HEX, S-record, binary and JSON images
   * - Pin timing
     - Checked by a :doc:`qspi_protocol_checker` passed as ``protocol_checker``; none by default
   * - Simulators
     - GHDL and NVC, in CI

Supported commands
~~~~~~~~~~~~~~~~~~

The opcode table is data in :mod:`awesome_vunit_vcs.flash.commands`; the list below is generated
from it. Lanes are opcode/address/data outside QPI. "Current" addressing follows the 3- or 4-byte
mode. Any other opcode, and any command a configuration does not support, is ignored as an unknown
opcode.

.. list-table::
   :header-rows: 1
   :widths: 9 16 12 43 20

   * - Opcode
     - Name
     - Lanes
     - Phases and conditions
     - Not supported with
   * - ``0x9F``
     - RDID
     - x1/-/x1
     - The three ``jedec_id`` bytes, repeating
     -
   * - ``0x5A``
     - RDSFDP
     - x1/x1/x1
     - 3-byte address in either mode, 8 dummy cycles
     -
   * - ``0x03``
     - READ
     - x1/x1/x1
     - Current addressing
     -
   * - ``0x0B``
     - FAST_READ
     - x1/x1/x1
     - Current addressing, 8 dummy cycles
     -
   * - ``0x3B``
     - READ_DUAL_OUT
     - x1/x1/x2
     - Current addressing, 8 dummy cycles
     -
   * - ``0x6B``
     - READ_QUAD_OUT
     - x1/x1/x4
     - Current addressing, 8 dummy cycles; needs QE
     -
   * - ``0xBB``
     - READ_DUAL_IO
     - x1/x2/x2
     - Current addressing, mode byte
     -
   * - ``0xEB``
     - READ_QUAD_IO
     - x1/x4/x4
     - Current addressing, mode byte, 4 dummy cycles; needs QE
     -
   * - ``0x13``
     - READ4B
     - x1/x1/x1
     - 4-byte address
     - ``three_only``
   * - ``0x0C``
     - FAST_READ4B
     - x1/x1/x1
     - 4-byte address, 8 dummy cycles
     - ``three_only``
   * - ``0x02``
     - PP
     - x1/x1/x1
     - Current addressing; needs WEL; ``tPP``
     -
   * - ``0x32``
     - PP_QUAD
     - x1/x1/x4
     - Current addressing; needs WEL and QE; ``tPP``
     -
   * - ``0x12``
     - PP4B
     - x1/x1/x1
     - 4-byte address; needs WEL; ``tPP``
     - ``three_only``
   * - ``0x20``
     - SE
     - x1/x1/-
     - Erases ``sector_bytes``; current addressing; needs WEL; ``tSE``
     -
   * - ``0x52``
     - BE32
     - x1/x1/-
     - Erases ``block32_bytes``; current addressing; needs WEL; ``tBE32``
     - ``block32_bytes => 0``
   * - ``0xD8``
     - BE64
     - x1/x1/-
     - Erases ``block_bytes``; current addressing; needs WEL; ``tBE64``
     -
   * - ``0xDC``
     - BE64_4B
     - x1/x1/-
     - Erases ``block_bytes``; 4-byte address; needs WEL; ``tBE64``
     - ``three_only``
   * - ``0xC7``, ``0x60``
     - CE, CE_ALT
     - x1/-/-
     - Erases the device; needs WEL; ``tCE``
     -
   * - ``0x06``, ``0x04``
     - WREN, WRDI
     - x1/-/-
     - Set and clear the write enable latch (WEL)
     -
   * - ``0x05``, ``0x35``, ``0x15``
     - RDSR1, RDSR2, RDSR3
     - x1/-/x1
     - Status register 1, 2 or 3, repeating; allowed while busy
     -
   * - ``0x01``
     - WRSR
     - x1/-/x1
     - Up to three bytes from status register 1; needs WEL; ``tW``
     -
   * - ``0x31``, ``0x11``
     - WRSR2, WRSR3
     - x1/-/x1
     - One byte to status register 2 or 3; needs WEL; ``tW``
     -
   * - ``0x38``
     - QPI_ENTER
     - x1/-/-
     - Enter QPI; needs QE
     -
   * - ``0xFF``
     - QPI_EXIT
     - x1/-/-
     - Leave QPI and continuous read; allowed while busy
     -
   * - ``0xB7``
     - EN4B
     - x1/-/-
     - Enter 4-byte addressing
     - ``three_only``
   * - ``0xE9``
     - EX4B
     - x1/-/-
     - Leave 4-byte addressing
     - ``three_only``, ``four_only``
   * - ``0x66``, ``0x99``
     - RSTEN, RST
     - x1/-/-
     - Software reset, ``0x99`` directly after ``0x66``; allowed while busy; ``tRST``
     -
   * - ``0xB9``
     - DPD
     - x1/-/-
     - Enter deep power-down
     -
   * - ``0xAB``
     - RELEASE_DPD
     - x1/x1/x1
     - Three don't-care address bytes, then the electronic ID; executes even when CS rises during the
       address; allowed in deep power-down; ``tRES1``, or ``tRES2`` after an ID byte
     -

Device behavior
~~~~~~~~~~~~~~~

* **Nothing happens until CS rises.** Program data and status bytes are latched and executed at the
  CS rising edge. A program or status write that ends within a byte, or any command whose address
  phase did not complete (except ``0xAB``), is not executed and counts as ``abort_count``.
* **Refusals are silent.** A command without WEL, while busy, without QE, in deep power-down, or an
  unknown opcode, does nothing and drives nothing, like a real part. So does a program or erase that
  touches a protected byte; it clears WEL. The :ref:`statistics <flash-statistics>` count every
  refusal.
* **NOR semantics.** A page program writes at most ``page_bytes``; bytes past the end of the page wrap
  to the start of the same page, and the last byte written to an offset wins. Programming only clears
  bits; erasing sets ``0xFF`` over the unit that contains the address. Reads continue past the end of
  the device from address 0, and a bus address is taken modulo ``size_bytes``.
* **Busy time.** A program, erase, status write, software reset or release from deep power-down holds
  write-in-progress (WIP) for its busy time from the CS rising edge. While busy, only ``0x05``,
  ``0x35``, ``0x15``, ``0xFF``, ``0x66`` and ``0x99`` are accepted, so status polling works. WIP is a
  deadline in the model, evaluated whenever it is read, so it is right whenever a controller polls.
* **Continuous read.** A mode byte with ``M5:M4 = 10`` after ``0xBB`` or ``0xEB`` makes the next
  transaction start with the address of the same command, without an opcode. Any other mode byte,
  ``0xFF`` or a reset ends it.
* **Status registers and protection.** The status writes change SR1 bits 7 to 2 (SRP, SEC, TB,
  BP2..BP0), SR2 bits 6, 1 and 0 (CMP, QE, SRL) and SR3 bits 7 to 5 and 2. WIP, WEL and SR3's ADS
  are derived. BP2..BP0 protect ``2**(BP-1)`` 64 KiB blocks, or 4 KiB sectors with SEC set, at the top
  of the device, at the bottom with TB set; ``BP = 7`` protects the whole device and CMP inverts the
  region. ``flash_set_protection`` locks regions in addition.
* **Addressing modes.** A ``three_only`` device ignores ``0xB7``, ``0xE9``, ``0x13``, ``0x0C``,
  ``0x12`` and ``0xDC``; a ``four_only`` device ignores ``0xE9``. SFDP advertises the same modes.
* **SFDP.** ``0x5A`` returns a JESD216 basic parameter table computed from the configuration:
  density, addressing modes and the erase types of ``sector_bytes``, ``block32_bytes`` and
  ``block_bytes`` with their opcodes.

Pins
----

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

``s2m`` has the initial value ``qspi_s2m_init``, no lane driven. A single-lane phase uses ``IO0``
from the controller (MOSI) and ``IO1`` from the flash (MISO). Dual and quad phases use ``IO1`` to
``IO0`` and ``IO3`` to ``IO0`` in both directions, with the most significant bit of a beat on the
highest lane. The flash releases its lanes ``t_shqz`` after CS rises and during dummy cycles. The
handle is the only generic: ``flash : flash_t``.

Constructor parameters
----------------------

:vhdl:`flash_pkg.new_flash` checks the geometry, identity and busy times when the component starts.
An invalid combination is a failure on the logger of the flash, and the model then uses the default
configuration so that the calls that follow stay harmless.

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
   * - ``page_bytes``
     - ``positive``
     - 256
     - The most bytes one page program writes; a power of two dividing ``size_bytes``
   * - ``sector_bytes``
     - ``positive``
     - 4096
     - The bytes ``0x20`` erases; a power of two dividing the device, at least ``page_bytes`` and less
       than ``block_bytes``
   * - ``block32_bytes``
     - ``natural``
     - 32768
     - The bytes ``0x52`` erases, between ``sector_bytes`` and ``block_bytes`` exclusive; 0 for a part
       without this erase, which then ignores ``0x52``
   * - ``block_bytes``
     - ``positive``
     - 65536
     - The bytes ``0xD8`` and ``0xDC`` erase; a power of two dividing the device, the largest erase
       unit
   * - ``addr_bytes``
     - ``positive range 3 to 4``
     - 3
     - Addressing mode at power-up and after a reset
   * - ``addr_modes``
     - ``flash_addr_modes_t``
     - ``both``
     - ``both``, ``three_only`` (needs ``addr_bytes => 3``) or ``four_only`` (needs
       ``addr_bytes => 4``); enforced by the device and advertised in SFDP
   * - ``jedec_id``
     - ``natural``
     - ``16#EF4018#``
     - Manufacturer, memory type and capacity bytes of ``0x9F``, 24 bits
   * - ``electronic_id``
     - ``integer``
     - -1
     - The byte ``0xAB`` returns; -1 uses the capacity byte of ``jedec_id`` minus one
   * - ``sr1_default``
     - ``natural range 0 to 255``
     - ``16#00#``
     - Status register 1 at power-up and reset; WIP and WEL are derived
   * - ``sr2_default``
     - ``natural range 0 to 255``
     - ``16#02#``
     - Status register 2; QE is set, so quad commands work without writing it first
   * - ``sr3_default``
     - ``natural range 0 to 255``
     - ``16#00#``
     - Status register 3; ADS is derived
   * - ``t_pp``
     - ``delay_length``
     - 700 us
     - Busy time of ``0x02``, ``0x32`` and ``0x12`` (tPP)
   * - ``t_se``
     - ``delay_length``
     - 45 ms
     - Busy time of ``0x20`` (tSE)
   * - ``t_be32``
     - ``delay_length``
     - 120 ms
     - Busy time of ``0x52`` (tBE32)
   * - ``t_be64``
     - ``delay_length``
     - 150 ms
     - Busy time of ``0xD8`` and ``0xDC`` (tBE64)
   * - ``t_ce``
     - ``delay_length``
     - 20 sec
     - Busy time of ``0xC7`` and ``0x60`` (tCE)
   * - ``t_w``
     - ``delay_length``
     - 10 ms
     - Busy time of ``0x01``, ``0x31`` and ``0x11`` (tW)
   * - ``t_rst``
     - ``delay_length``
     - 30 us
     - Busy time of a software reset (tRST)
   * - ``t_res1``
     - ``delay_length``
     - 3 us
     - Busy time of ``0xAB`` without an ID byte (tRES1)
   * - ``t_res2``
     - ``delay_length``
     - 1800 ns
     - Busy time of ``0xAB`` with an ID byte (tRES2)
   * - ``timing_enabled``
     - ``boolean``
     - true
     - Whether busy times apply at start; false makes every busy time 0
   * - ``t_clqv``
     - ``delay_length``
     - 6 ns
     - Output delay after SCK falls (tCLQV)
   * - ``t_shqz``
     - ``delay_length``
     - 6 ns
     - Output release delay after CS rises (tSHQZ)
   * - ``protocol_checker``
     - ``qspi_protocol_checker_t``
     - ``null_qspi_protocol_checker``
     - A protocol checker to instantiate on the pins, ``<id>:protocol_checker`` unless it has an id of
       its own; see :doc:`index`
   * - ``id``
     - ``id_t``
     - ``null_id``
     - ``awesome_vunit_vcs:flash:<n>`` when not given; also the identity of the Python session
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
     - ``fail`` logs a message of an unknown type as a failure on the logger, ``Got unexpected
       message <type>``; ``ignore`` drops it

The busy times are typical rather than worst-case values. A test that depends on one sets it.

.. code-block:: vhdl

   constant big_flash : flash_t := new_flash(
     size_bytes => 32 * 1024 * 1024,
     addr_bytes => 4,
     jedec_id => 16#20BA19#,
     protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns)
   );

Procedures
----------

Procedures that return nothing only send a message: the flash handles its messages in order, and
``wait_until_idle(net, as_sync(flash))`` waits for them. The others block until the reply, or have a
non-blocking form that returns a reference redeemed with the matching ``await_`` procedure.

Content
~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - ``flash_preload(net, flash, address, data)``
     - Write bytes, an ``integer_array_t`` the caller keeps or a ``std_ulogic_vector`` whose leftmost
       byte goes to ``address``. The data crosses the bridge, so keep it to a few KiB
   * - ``flash_preload_fill(net, flash, address, num_bytes, value)``
     - Fill a region with ``value`` (``16#FF#`` by default); only the length crosses, and nothing is
       allocated per byte
   * - ``flash_load_image(net, flash, file_name, format, base_address)``
     - Load an image file that Python opens; ``format => "auto"`` picks the format from the extension
   * - ``flash_read_back(net, flash, address, num_bytes, data)``
     - Blocking: the content as a new byte array the caller deallocates; also non-blocking with
       ``await_flash_read_back_reply``
   * - ``flash_check_content(net, flash, address, expected)``
     - Compare the content with ``expected`` in Python, an ``integer_array_t`` the caller keeps or a
       ``std_ulogic_vector`` of whole bytes with the byte of ``address`` leftmost
   * - ``flash_check_content_fill(net, flash, address, num_bytes, value)``
     - Compare a region with a constant, for example to prove an erase
   * - :vhdl:`flash_get_written_regions <flash_pkg.flash_get_written_regions>`
     - Blocking: a flat ``[address, length, ...]`` array of everything programmed or erased over the
       bus, coalesced; also non-blocking with ``await_flash_get_written_regions_reply``

Preloads and images are test setup, not device operations: they ignore WEL and protection, overwrite
without NOR semantics and are not written regions. Every address range must lie inside the device and
every value must be a byte, 0 to 255: a range past the end is reported as a failure on the logger and
nothing is written, never wrapped. ``value`` of the fill procedures is a ``natural range 0 to 255``,
and an array element outside it is reported the same way.

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

   {"base": 0, "regions": [
       {"addr": 4096, "hex": "deadbeef"},
       {"addr": 8192, "data": [1, 2, 3]},
       {"addr": 65536, "fill": 0, "length": 1048576}
   ]}

A relative ``file_name`` is relative to the directory the simulator runs in;
``tb_path(runner_cfg) & "boot.hex"`` names a file next to the testbench.

Configuration and state
~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - ``flash_set_timing_enable(net, flash, enable)``
     - False makes every busy time 0 and also ends a busy period that is running, so WIP reads clear
       from then on; true applies the busy times to commands that follow
   * - ``flash_set_timing(net, flash, name, duration)``
     - Override one busy time: ``"tPP"``, ``"tSE"``, ``"tBE32"``, ``"tBE64"``, ``"tCE"``, ``"tW"``,
       ``"tRST"``, ``"tRES1"`` or ``"tRES2"``. It applies to busy periods that start afterwards; another
       name is a failure on the logger that lists the valid ones
   * - ``flash_set_protection(net, flash, address, num_bytes, locked)``
     - Lock or unlock a region in addition to the status register protection. Locks survive a
       ``reset``
   * - ``flash_wait_until_ready(net, flash, timeout)``
     - Blocking: wait until a busy time the component started is over. ``timeout`` defaults to 1 min,
       longer than the default ``t_ce``; a timeout is a failure
   * - :vhdl:`reset(net, flash) <flash_pkg.reset>`
     - Blocking: return to standby, as a power-on reset. Status registers, WEL, addressing and QPI
       mode, continuous read, deep power-down and the status register protection return to their
       defaults, and a busy period ends, so ``flash_wait_until_ready`` returns at once. A reset while
       CS is low drops that transaction: the flash ignores the rest of it, and the next CS fall starts
       a command normally. Content, locks, statistics and written regions are kept
   * - :vhdl:`flash_get_stat <flash_pkg.flash_get_stat>`
     - Blocking: one statistic or piece of state, read at the current simulation time; also
       non-blocking with ``await_flash_get_stat_reply``
   * - ``get_id``, ``get_logger``, ``get_actor``, ``get_checker``, ``as_sync``
     - The identity of the flash, and its handle for ``wait_until_idle`` and ``wait_for_time``
   * - ``protocol_checker(flash)``
     - The protocol checker the flash instantiates, with its final id, or ``null_qspi_protocol_checker``

``flash_wait_until_ready`` cannot see a busy time the component has not started yet; the blocking
master procedures return after CS has risen, so it can follow them directly. A controller that polls
the status register over the bus is the stronger check.

A typical setup:

.. code-block:: vhdl

   reset(net, boot_flash);
   flash_set_timing_enable(net, boot_flash, false);
   flash_preload(net, boot_flash, 16#000000#, std_ulogic_vector'(x"01020304"));
   flash_load_image(net, boot_flash, tb_path(runner_cfg) & "fw.bin", format => "bin", base_address => 16#400000#);
   flash_set_protection(net, boot_flash, 16#000000#, 16#001000#, locked => true);

Checks
------

The flash checks what the device itself sees. Errors are check failures on its checker; failures of
the backend go to its logger.

.. list-table::
   :header-rows: 1
   :widths: 25 20 55

   * - Check
     - Reported on
     - Message
   * - Metavalue on a sampled lane
     - Checker
     - ``Metavalue <lanes> sampled on the IOs at <time>``, for every beat with ``U``, ``X``, ``Z``,
       ``W`` or ``-`` on a lane the flash samples for data in. The beat is read with ``to_01``
   * - Content mismatch
     - Checker
     - ``<id>: flash content mismatch at 0x<address>: expected 0x<value>, got 0x<value> (first of <n>
       bad bytes in [...])``, or ``expected fill 0x<value>`` for ``flash_check_content_fill``
   * - Directive layout
     - Checker
     - ``The directive layout of the Python backend does not match flash_pkg``, at time 0
   * - Backend failure
     - Logger
     - ``<id>: <method> raised <exception>: <message>``, for example an invalid configuration, a range
       outside the device, a value that is not a byte, an unknown timing or stat name or an image that
       cannot be read
   * - Unexpected message
     - Logger
     - ``Got unexpected message <type>`` with the ``fail`` policy

The pin timing of the controller is checked by the protocol checker of the flash, when it has one, on
the checker of the protocol checker; see :doc:`qspi_protocol_checker` for its check IDs.

.. _flash-statistics:

Statistics notes
----------------

``flash_get_stat(net, flash, name, value)`` returns one value by name. The flash passes the current
simulation time, so ``wip``, ``sr1`` and ``busy_remaining_us`` are current, not those of the last bus
activity. An unknown name, or a value an ``integer`` cannot hold, is a failure on the logger that
lists the valid names, and returns 0.

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Name
     - Meaning
   * - ``cmd_count``
     - Opcodes decoded, including unknown and refused ones, plus transactions continuing a continuous
       read
   * - ``xfer_count``
     - Bytes moved on the wire
   * - ``ignored_command_count``
     - The sum of the seven counters below: every command dropped silently
   * - ``unknown_opcode_count``
     - Opcodes that are not in the table, or not supported by the configuration
   * - ``wel_reject_count``, ``wip_reject_count``, ``qe_reject_count``, ``dpd_reject_count``
     - Commands refused without WEL, while busy, without QE and in deep power-down
   * - ``protect_reject_count``
     - Programs and erases refused because they touch a protected byte
   * - ``abort_count``
     - Commands not executed because CS rose within a data byte of a program or status write, or before
       the address phase completed
   * - ``program_count``, ``erase_count``, ``chip_erase_count``, ``wrsr_count``, ``reset_count``
     - Page programs, erases (chip erases included), chip erases, status writes and software resets
       executed
   * - ``bytes_programmed``, ``bytes_erased``
     - Bytes committed by page programs, bytes erased
   * - ``bytes_read``
     - Array bytes the read commands prepared, including one read ahead that CS may cut off
   * - ``continuous_read_entries``
     - Times continuous read was entered
   * - ``wip``, ``wel``, ``qe``, ``qpi``, ``dpd``, ``continuous_read``, ``timing_enabled``
     - 1 when set, 0 otherwise
   * - ``addr_bytes``
     - The current addressing mode, 3 or 4
   * - ``sr1``, ``sr2``, ``sr3``
     - The status registers as a read returns them
   * - ``busy_remaining_us``
     - The time until WIP clears in microseconds, rounded up, so 0 exactly when WIP is clear
   * - ``materialized_pages``, ``run_count``
     - How much the sparse array has allocated

A real part refuses a command without a trace on the wire, and so does the model: when a controller
seems to do nothing, ``ignored_command_count`` and the reject counters say why. The counters and the
written regions accumulate for the whole simulation; ``reset`` keeps them, and no VHDL procedure
clears them.

Python backend
--------------

Every ``flash`` creates one :class:`~awesome_vunit_vcs.flash.vunit_backend.FlashBackend` as the object
``vc`` in a Python session with the identity of the flash, so instances share nothing. The backend
converts arguments, turns every exception into a report, and delegates to a
:class:`~awesome_vunit_vcs.flash.device.FlashDevice` built from a
:class:`~awesome_vunit_vcs.flash.config.FlashConfig` with the parameters of ``new_flash``, busy times
in integer femtoseconds. The pin timing, the protocol checker and the output delays stay in VHDL.

On the wire the flash calls ``cs_assert`` when CS falls, ``xfer`` after every byte and
``cs_deassert`` when CS rises, which returns the busy time and the number of waiting reports. The
procedures above call the other methods, and a backend method never raises into the bridge. The
backend also has ``clear_statistics``, which no VHDL procedure calls; a testbench can reach it through
the Python bridge in the session of the flash.

``cs_assert`` and ``xfer`` return one packed directive, an integer that says what to do with the next
byte:

.. list-table::
   :header-rows: 1
   :widths: 22 12 66

   * - Field
     - Bits
     - Values
   * - ``action``
     - 1..0
     - 0 receive, 1 transmit, 2 ignore the rest of the transaction
   * - ``lanes``
     - 4..2
     - 1, 2 or 4
   * - ``pre_dummy_cycles``
     - 10..5
     - SCK cycles with the I/Os released before the action
   * - ``byte_out``
     - 18..11
     - The byte to transmit
   * - ``flags``
     - 20..19
     - Bit 0, volatile: the next ``xfer`` passes the simulation time, because the byte depends on it
   * - ``n_bytes``
     - 29..21
     - Always 1

The layout fits in 30 bits, since a VHDL ``integer`` is signed 32-bit. The component compares
``flash_layout_version`` with :data:`~awesome_vunit_vcs.flash.directive.LAYOUT_VERSION` at time 0.

The model runs without a simulator; this file is ``examples/python/flash_jedec_id.py``, which the
test suite runs:

.. literalinclude:: ../../examples/python/flash_jedec_id.py
   :language: python
   :lines: 5-

Example
-------

``tests/vhdl/tb_flash.vhd`` connects QSPI masters to flashes and makes every claim about bytes that
crossed the wires. It runs in CI on GHDL and NVC. A master and a flash with a protocol checker:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_constructors
   :end-before: -- docs-end: flash_constructors
   :dedent: 2

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_instances
   :end-before: -- docs-end: flash_instances
   :dedent: 2

A sector erase over the bus, checked in Python:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_sector_erase
   :end-before: -- docs-end: flash_sector_erase
   :dedent: 8

Negative tests disable the stop, count the errors and reset the count. A metavalue on a lane the flash
samples, bit-banged by the testbench:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_metavalue
   :end-before: -- docs-end: flash_metavalue
   :dedent: 8

A CS deselect time below the ``t_shsl`` of the flash's protocol checker:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: flash_protocol_violation
   :end-before: -- docs-end: flash_protocol_violation
   :dedent: 8

``poll_until_ready``, ``bytes_of`` and ``send_raw_byte`` are helpers of the testbench.

Limitations
-----------

.. note::

   * **One bridge call per byte on the bus**, plus one at each CS edge; bulk content goes through the
     preload, image and check procedures. See :ref:`performance-flash`.
   * **One device per bus.** ``s2m`` has one driver; two devices need two buses.
   * **Fixed protection units.** The BP bits count 4 KiB or 64 KiB units whatever the geometry.
   * **No hardware write protection.** SRP and SRL have no effect, and there is no WP# pin.
   * **Limited 4-byte command set**, no program or erase suspend, and fixed dummy cycles per opcode.
   * **Deep power-down** takes no time to enter.
   * **Released I/Os are metavalues** when the flash samples them for data in.
   * **Waiting for a busy time that was cut short.** ``flash_wait_until_ready`` waits for the whole
     busy time the component started, even when ``flash_set_timing_enable(net, flash, false)`` ended
     it in the model.
   * **Statistics are never cleared from VHDL.**

   These are also listed, with details, in :ref:`limitations-flash`.
