Supported flash commands
========================

Lanes are opcode/address/data outside QPI, and "current" addressing follows the 3- or 4-byte mode.
Any other opcode, and any command a configuration does not support, is ignored as an unknown opcode.

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

Related pages
-------------

* :doc:`qspi_flash`: how to create and use the flash
* :doc:`qspi_master`: *Send flash commands* with the command layer of the master

API reference
-------------

* VHDL: :vhdl:`flash_pkg.new_flash` and the ``qspi_flash_*`` procedures in :doc:`vhdl_api`
