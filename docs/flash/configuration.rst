Flash configuration options
===========================

Every parameter of :vhdl:`flash_pkg.new_flash`. :doc:`qspi_flash` shows the ones most tests need. An
invalid combination is a failure on the logger of the flash when it starts.

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
     - The byte ``0xAB`` returns; -1 (``None`` in Python's ``FlashConfig``) uses the capacity byte of
       ``jedec_id`` minus one
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
   * - ``clear_wel_on_protection_reject``
     - ``boolean``
     - true
     - Whether a program or erase refused because it touches a protected byte clears WEL; false keeps
       WEL set
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
     - ``awesome_vunit_vcs:flash:<n>`` when not given; two flashes with the same id are a failure on
       the logger
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

The busy times are typical rather than worst-case values. A test that depends on one sets it.

Related pages
-------------

* :doc:`qspi_flash`: *Common options*
* :doc:`qspi_protocol_checker`: the pin timing limits

API reference
-------------

* VHDL: :vhdl:`flash_pkg.new_flash`
* Python: :py:class:`~awesome_vunit_vcs.flash.config.FlashConfig`
