Flash
=====

The flash family verifies designs that talk to serial NOR flash. A ``flash`` component is a QSPI NOR
flash device a DUT controller reads, programs and erases over its pins. A ``qspi_master`` drives
the same bus from a testbench, with a thin JEDEC command layer on top, so the flash can be
exercised without a DUT and a flash-facing DUT can be replaced in a test.

The device is a generic JEDEC part in SPI mode 0: single, dual and quad I/O, 3- and 4-byte
addressing, QPI, continuous read (XIP), SFDP, status register and region protection, busy times
and pin-level AC checks. Every value that differs between two parts is an option of ``new_flash``.

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.flash_context;

Interface
---------

Both ends of the bus drive their own unresolved record: the master drives ``m2s``, the flash
drives ``s2m``. Each I/O lane has a value and an output enable, so a waveform shows which end drove
a lane, and ``qspi_io_value(m2s, s2m)`` from ``qspi_pkg`` gives what a probe on the four wires sees:
``'Z'`` on an undriven lane and ``'X'`` on a lane both ends drive.

.. list-table::
   :header-rows: 1

   * - Port
     - ``flash``
     - ``qspi_master``
   * - ``m2s``
     - ``in qspi_m2s_t``
     - ``out qspi_m2s_t := qspi_m2s_init``
   * - ``s2m``
     - ``out qspi_s2m_t := qspi_s2m_init``
     - ``in qspi_s2m_t``

.. list-table::
   :header-rows: 1

   * - Field
     - Type
     - Flash signal
   * - ``m2s.sck``
     - ``std_ulogic``
     - ``CLK``
   * - ``m2s.cs_n``
     - ``std_ulogic``
     - ``/CS``
   * - ``m2s.io.value``, ``m2s.io.enable``
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` driven by the controller
   * - ``s2m.io.value``, ``s2m.io.enable``
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` driven by the flash

A single-lane phase uses ``IO0`` from the controller (MOSI) and ``IO1`` from the flash (MISO). Dual
and quad phases use ``IO1`` to ``IO0`` and ``IO3`` to ``IO0`` in both directions, most significant
bit on the highest lane. A DUT with tri-state ``io`` pins connects through a small adapter that
splits its drive into ``value`` and ``enable`` and drives the pins from ``s2m`` when the flash
enables a lane.

The handle is the only generic: ``flash : flash_t`` or ``qspi_master : qspi_master_t``.

Creating the component
----------------------

.. code-block:: vhdl

   constant master : qspi_master_t := new_qspi_master;
   constant boot_flash : flash_t := new_flash;

   signal m2s : qspi_m2s_t;
   signal s2m : qspi_s2m_t;
   ...
   qspi_master_inst : entity awesome_vunit_vcs.qspi_master
     generic map (
       qspi_master => master
     )
     port map (
       m2s => m2s,
       s2m => s2m
     );

   flash_inst : entity awesome_vunit_vcs.flash
     generic map (
       flash => boot_flash
     )
     port map (
       m2s => m2s,
       s2m => s2m
     );

Each instance has its own model, logger and checker; several can share a testbench. ``new_flash``
takes ``id``, ``unexpected_msg_type_policy`` and the options below, and the defaults describe a
generic 16 MiB part, so a test only names what it cares about:

.. code-block:: vhdl

   constant big_flash : flash_t := new_flash(
     size_bytes => 32 * 1024 * 1024,
     addr_bytes => 4,
     jedec_id => 16#20BA19#,
     t_shsl => 60 ns
   );

The handle has the accessors ``get_id``, ``get_logger``, ``get_checker`` and ``as_sync``.

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - Option
     - Default
     - Meaning
   * - **Geometry**
     -
     -
   * - ``size_bytes``
     - 16 MiB
     - Capacity, a power of two
   * - ``page_bytes``
     - 256
     - Page program buffer
   * - ``sector_bytes``
     - 4096
     - Unit of ``0x20``
   * - ``block32_bytes``
     - 32768
     - Unit of ``0x52``; 0 means the part has no 32 KiB block erase
   * - ``block_bytes``
     - 65536
     - Unit of ``0xD8``
   * - ``addr_bytes``
     - 3
     - Address length at power-up and after a reset
   * - ``addr_modes``
     - ``both``
     - Addressing modes advertised in SFDP: ``both``, ``three_only`` or ``four_only``, which must
       agree with ``addr_bytes``
   * - **Identity**
     -
     -
   * - ``jedec_id``
     - ``16#EF4018#``
     - Manufacturer, memory type and capacity bytes returned by ``0x9F``
   * - ``electronic_id``
     - -1
     - The byte ``0xAB`` returns; -1 derives it from the capacity code
   * - **Status register defaults**
     -
     -
   * - ``sr1_default``
     - ``16#00#``
     - Status register 1 at power-up and reset
   * - ``sr2_default``
     - ``16#02#``
     - Status register 2; QE is set, so quad commands work without writing it first
   * - ``sr3_default``
     - ``16#00#``
     - Status register 3
   * - **Busy times**
     -
     -
   * - ``t_pp``
     - 700 us
     - Page program (``tPP``)
   * - ``t_se``
     - 45 ms
     - Sector erase (``tSE``)
   * - ``t_be32``, ``t_be64``
     - 120 ms, 150 ms
     - 32 and 64 KiB block erase (``tBE32``, ``tBE64``)
   * - ``t_ce``
     - 20 sec
     - Chip erase (``tCE``)
   * - ``t_w``
     - 10 ms
     - Write status register (``tW``)
   * - ``t_rst``
     - 30 us
     - Software reset recovery (``tRST``)
   * - ``t_res1``, ``t_res2``
     - 3 us, 1800 ns
     - Release from deep power-down, without and with the electronic ID read (``tRES1``,
       ``tRES2``)
   * - ``timing_enabled``
     - true
     - Initial state of the busy timing
   * - **Pin checks**
     -
     -
   * - ``t_sck_min``
     - 7519 ps
     - Minimum SCK period
   * - ``t_sck_high_min``, ``t_sck_low_min``
     - 3 ns, 3 ns
     - Minimum SCK high and low time
   * - ``t_slch``
     - 5 ns
     - CS low to the first SCK rising edge
   * - ``t_chsh``
     - 5 ns
     - Last SCK edge to CS high
   * - ``t_shsl``
     - 30 ns
     - CS high time between commands
   * - ``t_dvch``, ``t_chdx``
     - 2 ns, 3 ns
     - Data-in setup and hold around the sampling edge
   * - ``protocol_checks``
     - true
     - False disables every pin check
   * - **Output delays**
     -
     -
   * - ``t_clqv``
     - 6 ns
     - SCK falling edge to output valid
   * - ``t_shqz``
     - 6 ns
     - CS high to output high impedance

Busy times use the names of the datasheet, and the defaults are typical rather than worst-case
values. A test that needs worst case sets the one time it depends on.

Why not VUnit's memory model
----------------------------

VUnit's ``memory_pkg`` is a good model for a bus memory, but its ``memory_t`` is dense: every
byte of the address space is allocated, with per-byte permissions and expectations. The flash
content lives in Python instead, as a sparse array with NOR semantics (program only clears bits,
erase sets ``0xFF``) and region protection, which is what lets a 16 MiB part filled with a pattern
cost a few objects. A ``memory_t`` view of it would duplicate that state and keep the two copies
in step on every program and erase. The preload and check procedures below are the memory access
API of the flash.

Initializing content
--------------------

Content nobody initialized reads ``0xFF``, like an erased part, and costs nothing. There are three
procedures, chosen by how much data there is, since they differ in what crosses the bridge:

.. code-block:: vhdl

   -- Scattered bytes: the data crosses, so keep it to a few KiB. A vector literal puts its
   -- leftmost byte at the address; an integer_array_t of byte values works too.
   flash_preload(net, boot_flash, 16#001000#, std_ulogic_vector'(x"DEADBEEF"));
   flash_preload(net, boot_flash, 16#020000#, data);

   -- A uniform region: only the length crosses, and nothing is materialized
   flash_preload_fill(net, boot_flash, 16#100000#, 1024 * 1024, 16#00#);

   -- An image file: only the name crosses, Python opens the file
   flash_load_image(net, boot_flash, tb_path(runner_cfg) & "images/boot.hex");
   flash_load_image(net, boot_flash, tb_path(runner_cfg) & "fw.bin", format => "bin", base_address => 16#400000#);

``format => "auto"``, the default, picks the format from the extension:

.. list-table::
   :header-rows: 1

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
     - Regions described inline, see below

For the other formats ``base_address`` is an offset added to every address. A JSON image is a list
of regions, or an object with an optional ``base`` and a ``regions`` list. A ``fill`` region stays
sparse:

.. code-block:: json

   {"base": 0, "regions": [
       {"addr": 4096, "hex": "deadbeef"},
       {"addr": 8192, "data": [1, 2, 3]},
       {"addr": 65536, "fill": 0, "length": 1048576}
   ]}

Initialization is test setup, not a device operation: it ignores the write enable latch and
protection, overwrites without NOR semantics and is not counted as written. That is what lets a
test preload a region, lock it and prove that the DUT cannot change it.

A typical setup:

.. code-block:: vhdl

   flash_set_timing_enable(net, boot_flash, false);
   flash_preload(net, boot_flash, 0, std_ulogic_vector'(x"01020304"));
   flash_set_protection(net, boot_flash, 16#000000#, 16#001000#, locked => true);

``flash_reset(net, boot_flash)`` is a power-on reset: status registers, write enable, addressing
and QPI mode, continuous read and busy state return to their defaults. The content and the regions
locked with ``flash_set_protection`` are kept, since a reset is not an erase.

Inspecting content
------------------

.. code-block:: vhdl

   -- Compared in Python. A mismatch is a check failure naming the first bad address, both
   -- values and the number of bad bytes.
   flash_check_content(net, boot_flash, 16#001000#, expected);

   -- Proves an erase without building a 4 KiB expected array
   flash_check_content_fill(net, boot_flash, 16#002000#, 4096, 16#FF#);

   -- The content as a new integer_array_t of bytes, which the caller deallocates
   flash_read_back(net, boot_flash, 16#001000#, 16, data);

   -- Flat [address, length, address, length, ...] of everything programmed or erased over the
   -- bus, coalesced. Preloads are not included.
   flash_get_written_regions(net, boot_flash, regions);

``flash_read_back`` also has a non-blocking form that returns a reference, redeemed with
``await_flash_read_back_reply``.

``flash_get_stat(net, flash, name, value)`` returns one counter or piece of device state. An
unknown name is a failure listing the valid ones.

.. list-table::
   :header-rows: 1

   * - Name
     - Meaning
   * - ``ignored_command_count``
     - Commands the device dropped silently, for any of the reasons below
   * - ``wel_reject_count``
     - A program, erase or status write arrived without write enable
   * - ``wip_reject_count``
     - A command arrived while the device was busy
   * - ``protect_reject_count``
     - A program or erase touched a protected region
   * - ``qe_reject_count``
     - A quad command arrived with QE clear
   * - ``dpd_reject_count``
     - A command arrived during deep power-down
   * - ``unknown_opcode_count``
     - The opcode is not supported
   * - ``abort_count``
     - CS rose in the middle of a byte, so the command was not executed
   * - ``cmd_count``, ``xfer_count``, ``program_count``, ``erase_count``, ``chip_erase_count``,
       ``wrsr_count``, ``reset_count``, ``continuous_read_entries``
     - Activity counters
   * - ``bytes_read``, ``bytes_programmed``, ``bytes_erased``
     - Byte counters
   * - ``wip``, ``wel``, ``qe``, ``qpi``, ``dpd``, ``addr_bytes``, ``continuous_read``,
       ``timing_enabled``, ``sr1``, ``sr2``, ``sr3``
     - Current device state
   * - ``materialized_pages``, ``run_count``
     - How much the sparse array has allocated

A real part drops a command it refuses without a trace on the wire, and so does the model. When a
controller seems to do nothing, ``ignored_command_count`` and the reject counters say why.

Timing
------

A program, erase, status write or reset holds write-in-progress (WIP) for its busy time from the
rising edge of CS. While busy, the device refuses every command except the status reads, reset
enable, reset and ``0xFF``; status polling keeps working.

.. code-block:: vhdl

   flash_set_timing_enable(net, boot_flash, true);     -- the global switch
   flash_set_timing(net, boot_flash, "tSE", 45 ms);    -- override one busy time
   flash_wait_until_ready(net, boot_flash);            -- block until WIP is clear

The names for ``flash_set_timing`` are ``tPP``, ``tSE``, ``tBE32``, ``tBE64``, ``tCE``, ``tW``,
``tRST``, ``tRES1`` and ``tRES2``. An unknown name is a failure listing the valid ones. With timing
disabled every busy time is zero, and the same test runs without waiting for erases.

The model has no clock of its own. VHDL passes the simulation time at CS edges, and the model keeps
a busy deadline rather than a flag, so WIP is right whenever a controller polls. Times cross the
bridge as integer femtoseconds, without rounding.

Protocol checks
---------------

The flash measures the pins the controller drives against the options of its handle:

* SCK period, high time and low time (``t_sck_min``, ``t_sck_high_min``, ``t_sck_low_min``),
* CS low to the first SCK rising edge (``t_slch``),
* last SCK edge to CS high (``t_chsh``),
* CS high time between commands (``t_shsl``),
* data-in setup and hold around the sampling edge (``t_dvch``, ``t_chdx``), for the beats the
  controller drives only,
* metavalues (``U``, ``X``, ``Z``, ``W``, ``-``) on the I/O lanes the flash samples, which are
  reported instead of being read as ``0``.

A limit of ``0 ns`` disables that check, and ``protocol_checks => false`` disables all of them.
Violation messages start with ``flash protocol:``, for example ``flash protocol: CS high time
between commands 20 ns is shorter than the 30 ns minimum``.

``t_clqv`` and ``t_shqz`` describe the flash's own outputs, so they are applied as output delays
and never checked.

Errors
------

Errors a flash detects go to its checker, which has the identity of the component:

* pin-level protocol violations and metavalues,
* a failed ``flash_check_content`` or ``flash_check_content_fill``,
* a Python model whose directive layout differs from the VHDL one.

Anything else that goes wrong in Python, such as an invalid option combination, a preload past the
end of the device, an image with a bad checksum, or an unknown timing or stat name, is logged as a
failure on the logger with a message naming the component. Refused commands are not errors, see
the stats above. By default the first error stops the simulation, as any VUnit check failure does.

Negative tests
~~~~~~~~~~~~~~

A test that expects a violation disables the stop, counts the errors and resets the count, so that
an unexpected error still fails the test at ``test_runner_cleanup``:

.. code-block:: vhdl

   -- CS stays high for one 20 ns SCK period between transactions, below the 30 ns t_shsl
   constant fast_master : qspi_master_t := new_qspi_master(cs_deselect_time => 10 ns);
   ...
   elsif run("test_short_cs_deselect_is_reported") then
     disable_stop(get_logger(boot_flash), error);

     qspi_flash_write_enable(net, fast_master);
     qspi_flash_write_enable(net, fast_master);

     check_equal(get_log_count(get_logger(boot_flash), error), 1, "tSHSL violations");
     reset_log_count(get_logger(boot_flash), error);

Supported commands
------------------

The opcode table is data in ``awesome_vunit_vcs.flash.commands``. "Current" addressing follows
the 3- or 4-byte mode. In QPI mode every phase of every command is on four lanes.

.. list-table::
   :header-rows: 1
   :widths: 10 20 70

   * - Opcode
     - Name
     - Notes
   * - ``0x9F``
     - RDID
     - The three ``jedec_id`` bytes
   * - ``0x5A``
     - RDSFDP
     - 3-byte address in either mode, 8 dummy cycles; a JESD216 basic parameter table computed from
       the options and this table
   * - ``0x03``
     - READ
     - Current addressing
   * - ``0x0B``
     - FAST_READ
     - Current addressing, 8 dummy cycles
   * - ``0x3B``
     - READ_DUAL_OUT
     - 8 dummy cycles, data x2
   * - ``0x6B``
     - READ_QUAD_OUT
     - 8 dummy cycles, data x4; needs QE
   * - ``0xBB``
     - READ_DUAL_IO
     - Address and mode byte x2, data x2
   * - ``0xEB``
     - READ_QUAD_IO
     - Address and mode byte x4, 4 dummy cycles, data x4; needs QE. Mode bits M5:M4 = ``10``
       enter continuous read, where the next command has no opcode
   * - ``0x13``, ``0x0C``
     - READ4B, FAST_READ4B
     - 4-byte address; ``0x0C`` has 8 dummy cycles
   * - ``0x02``
     - PP
     - Current addressing, up to one page; needs write enable; ``tPP``
   * - ``0x32``
     - PP_QUAD
     - As ``0x02`` with data x4; needs QE
   * - ``0x12``
     - PP4B
     - As ``0x02`` with a 4-byte address
   * - ``0x20``
     - SE
     - 4 KiB sector erase; needs write enable; ``tSE``
   * - ``0x52``
     - BE32
     - 32 KiB block erase; ``tBE32``
   * - ``0xD8``, ``0xDC``
     - BE64, BE64_4B
     - 64 KiB block erase, ``0xDC`` with a 4-byte address; ``tBE64``
   * - ``0xC7``, ``0x60``
     - CE, CE_ALT
     - Chip erase; needs write enable; ``tCE``
   * - ``0x06``, ``0x04``
     - WREN, WRDI
     - Set and clear the write enable latch
   * - ``0x05``, ``0x35``, ``0x15``
     - RDSR1, RDSR2, RDSR3
     - Status registers 1 to 3; allowed while busy
   * - ``0x01``
     - WRSR
     - Up to three status bytes; needs write enable; ``tW``. BP2..BP0, TB, SEC and CMP protect a
       region as on W25Q parts
   * - ``0x38``, ``0xFF``
     - QPI_ENTER, QPI_EXIT
     - Enter QPI (needs QE) and leave it; ``0xFF`` also ends continuous read and is allowed while
       busy
   * - ``0xB7``, ``0xE9``
     - EN4B, EX4B
     - Enter and leave 4-byte addressing
   * - ``0x66``, ``0x99``
     - RSTEN, RST
     - Software reset; allowed while busy; ``tRST``
   * - ``0xB9``, ``0xAB``
     - DPD, RELEASE_DPD
     - Deep power-down and release, with an optional electronic ID read; ``tRES1``

A program or erase of a protected region, or one without write enable, is ignored and clears the
write enable latch. Nothing happens until CS rises, so a command cut off in the middle of a byte is
not executed.

The QSPI master and command layer
---------------------------------

``qspi_master`` knows nothing about flash. It runs one transaction shape, and the caller composes
the bytes:

.. code-block:: text

   CS low -> cmd bytes (cmd_lanes) -> addr bytes (addr_lanes) -> wr_data bytes (wr_lanes)
          -> dummy_cycles with the master tri-stated -> num_read_bytes bytes (read_lanes) -> CS high

.. code-block:: vhdl

   constant master : qspi_master_t := new_qspi_master(sck_period => 20 ns, cs_deselect_time => 50 ns);
   ...
   -- Non-blocking, then redeemed; data is a new byte array the caller owns
   qspi_transfer(net, master, cmd, reference, addr => addr, num_read_bytes => 16, read_lanes => 4);
   await_qspi_transfer_reply(net, reference, data);

   -- Blocking forms, with and without read data
   qspi_transfer(net, master, cmd, data, num_read_bytes => 3);
   qspi_transfer(net, master, cmd, wr_data => payload, wr_lanes => 4);

   set_sck_period(net, master, 10 ns);
   wait_until_idle(net, as_sync(master));

``cmd``, ``addr`` and ``wr_data`` are ``integer_array_t`` byte arrays, read during the call only.
The master uses SPI mode 0: it changes its outputs on the falling edge of SCK and samples on the
rising edge. ``cs_deselect_time`` is the minimum CS high time between transactions; the default of
50 ns is above the default ``t_shsl`` of the flash.

``qspi_flash_cmd_pkg`` wraps the common commands in blocking procedures. Each takes ``addr_bytes``
where the command has an address, ``opcode_lanes`` (4 in QPI mode) and the dummy cycles as
parameters with the JEDEC defaults. Anything else, such as a vendor command or a malformed frame
for a negative test, goes through ``qspi_transfer``.

.. list-table::
   :header-rows: 1

   * - Procedure
     - Command
   * - ``qspi_flash_read_id``
     - ``0x9F``
   * - ``qspi_flash_read``, ``qspi_flash_fast_read``
     - ``0x03``, ``0x0B``
   * - ``qspi_flash_quad_output_read``, ``qspi_flash_quad_io_read``
     - ``0x6B``, ``0xEB`` (with the mode byte)
   * - ``qspi_flash_write_enable``
     - ``0x06``
   * - ``qspi_flash_page_program``
     - ``0x02``, or ``opcode => qspi_flash_op_quad_page_program, data_lanes => 4``
   * - ``qspi_flash_sector_erase``, ``qspi_flash_block_erase``, ``qspi_flash_chip_erase``
     - ``0x20``, ``0xD8`` or ``0x52``, ``0xC7``
   * - ``qspi_flash_read_status``, ``qspi_flash_write_status``
     - ``0x05``/``0x35``/``0x15``, ``0x01``/``0x31``/``0x11``
   * - ``qspi_flash_enter_4byte``, ``qspi_flash_exit_4byte``
     - ``0xB7``, ``0xE9``
   * - ``qspi_flash_enter_qpi``, ``qspi_flash_exit_qpi``
     - ``0x38``, ``0xFF`` on four lanes

.. code-block:: vhdl

   qspi_flash_write_enable(net, master);
   qspi_flash_page_program(net, master, 16#001000#, payload);
   flash_wait_until_ready(net, boot_flash);
   qspi_flash_quad_io_read(net, master, 16#001000#, length(payload), data);

Using the model from Python
---------------------------

The device model is plain Python and runs without a simulator:

.. code-block:: python

   from awesome_vunit_vcs.flash import FlashConfig, FlashDevice
   from awesome_vunit_vcs.flash.directive import unpack

   device = FlashDevice(FlashConfig(size_bytes=32 * 1024 * 1024, addr_bytes=4, timing_enabled=False))
   device.preload(0x1000, bytes.fromhex("deadbeef"))
   device.check_content(0x1000, bytes.fromhex("deadbeef"))  # raises ContentMismatch otherwise

   # RDID on the wire: the device answers every byte with what to do with the next one
   device.cs_assert(0)
   first = unpack(device.xfer(0x9F))
   rest = [unpack(device.xfer(-1)) for _ in range(2)]
   device.cs_deassert(0, 1_000_000)
   assert [first.byte_out, *(d.byte_out for d in rest)] == [0xEF, 0x40, 0x18]

``FlashConfig`` has the options of ``new_flash`` except the pin checks and output delays, which
only VHDL uses, with busy times in integer femtoseconds. See :doc:`python_api`.

How the component uses the model
--------------------------------

Every ``flash`` creates one ``FlashBackend`` from ``awesome_vunit_vcs.flash.vunit_backend`` in its
own Python session. VHDL owns pins and time, Python owns every device decision. At CS falling VHDL
calls ``cs_assert``, after every byte ``xfer``, and at CS rising ``cs_deassert``, which returns the
busy time. ``cs_assert`` and ``xfer`` return one packed directive saying what to do with the next
byte:

.. list-table::
   :header-rows: 1

   * - Field
     - Bits
     - Values
   * - ``action``
     - 1..0
     - 0 receive, 1 transmit, 2 ignore the rest of the command
   * - ``lanes``
     - 4..2
     - 1, 2 or 4, for this action
   * - ``pre_dummy_cycles``
     - 10..5
     - SCK cycles with the I/Os released before this action
   * - ``byte_out``
     - 18..11
     - The byte to transmit
   * - ``flags``
     - 20..19
     - Bit 0: volatile, the next ``xfer`` passes the simulation time
   * - ``n_bytes``
     - 29..21
     - Reserved, always 1

The layout fits in 30 bits, since a VHDL ``integer`` is signed 32-bit. ``flash_layout_version`` in
VHDL and ``LAYOUT_VERSION`` in Python are compared when the component starts.

Backend methods never raise into the bridge: an exception becomes a report, which the component
logs on its logger or checker.

Performance
-----------

The wire path makes one bridge call per byte on the bus, plus one per CS edge. Image-sized content
goes through ``flash_preload_fill``, ``flash_load_image``, ``flash_preload`` and the content checks.
:ref:`performance-flash` has the measurements.
