.. _flash-statistics:

Flash statistics and state
==========================

:vhdl:`flash_get_stat(net, flash, name, value) <flash_pkg.flash_get_stat>` blocks and returns one
statistic or piece of state by name; :vhdl:`flash_pkg.await_flash_get_stat_reply` redeems its
non-blocking form. The flash passes the current simulation time, so ``wip``, ``sr1`` and
``busy_remaining_us`` are current, not those of the last bus activity.

An unknown name, or a value an ``integer`` cannot hold, is a failure on the logger that lists the
valid names, and returns 0.

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

The counters and the written regions accumulate for the whole simulation.
``reset(net, flash, clear_statistics => true)`` sets the counters to 0 and forgets the written regions.

Related pages
-------------

* :doc:`qspi_flash`: *Read statistics and state*
* :doc:`../cookbook/flash`: *Reset the flash family between examples*

API reference
-------------

* VHDL: :vhdl:`flash_pkg.flash_get_stat`, :vhdl:`flash_pkg.await_flash_get_stat_reply`,
  :vhdl:`flash_pkg.reset`
