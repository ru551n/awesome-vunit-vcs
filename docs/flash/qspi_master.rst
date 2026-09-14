QSPI master
===========

Overview
--------

The :vhdl:`qspi_master` verification component (VC) drives a QSPI bus from a testbench. It knows nothing
about flash: it runs one transaction shape, whose bytes, lane widths and dummy cycles the caller
chooses, and owns CS framing, SCK generation, lane placement and tri-stating. ``qspi_flash_cmd_pkg``
builds the common JEDEC flash commands on top of it. Anything the command layer cannot express, such
as a vendor command or a malformed frame for a negative test, goes through
:vhdl:`qspi_master_pkg.qspi_transfer`. Create the handle with :vhdl:`qspi_master_pkg.new_qspi_master`.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Bus
     - QSPI in SPI mode 0 (CPOL = 0, CPHA = 0): SCK idles low, the master changes its outputs on the
       falling edge and samples on the rising edge
   * - Lanes
     - x1, x2 and x4 per phase; x1 phases drive ``IO0`` (MOSI) and read ``IO1`` (MISO); QPI is x4 on
       every phase
   * - Addressing
     - 3- and 4-byte addresses in the command layer (``addr_bytes``); any bytes with ``qspi_transfer``
   * - Clocking
     - ``sck_period`` from the handle, changed at run time with ``set_sck_period``
   * - Simulators
     - GHDL and NVC, in CI

A transaction is:

.. code-block:: text

   CS low -> cmd bytes (cmd_lanes) -> addr bytes (addr_lanes) -> wr_data bytes (wr_lanes)
          -> dummy_cycles with every master I/O released -> num_read_bytes bytes (read_lanes) -> CS high

Any phase may be empty. CS falls half an SCK period before the first rising edge and rises half a
period after the last falling edge. It then stays high for the longer of one SCK period and
``cs_deselect_time`` before the next transaction starts. A read beat samples the bus just before the
rising edge.

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
     - out
     - ``std_ulogic``
     - ``CLK``
   * - ``m2s.cs_n``
     - out
     - ``std_ulogic``
     - ``/CS``
   * - ``m2s.io.value``, ``m2s.io.enable``
     - out
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` driven by the master
   * - ``s2m.io.value``, ``s2m.io.enable``
     - in
     - ``std_ulogic_vector(3 downto 0)`` each
     - ``IO0`` to ``IO3`` driven by the device

``m2s`` has the initial value ``qspi_m2s_init``: SCK low, CS high, no lane driven. In a dual or quad
phase the most significant bit of a beat is on the highest lane. The handle is the only generic:
``qspi_master : qspi_master_t``.

Constructor parameters
----------------------

.. list-table::
   :header-rows: 1
   :widths: 25 20 20 35

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``sck_period``
     - ``delay_length``
     - 20 ns (``qspi_default_sck_period``)
     - The SCK period the master starts with
   * - ``cs_deselect_time``
     - ``delay_length``
     - 50 ns (``qspi_default_cs_deselect_time``)
     - Minimum CS high time between two transactions, above the 30 ns default ``t_shsl`` of a protocol
       checker
   * - ``protocol_checker``
     - ``qspi_protocol_checker_t``
     - ``null_qspi_protocol_checker``
     - A protocol checker to instantiate on the pins of the master, see :doc:`qspi_protocol_checker`
   * - ``id``
     - ``id_t``
     - ``null_id``
     - ``awesome_vunit_vcs:qspi_master:<n>`` when not given
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

Procedures
----------

Transactions
~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Purpose
   * - :vhdl:`qspi_transfer(net, qspi_master, cmd, reference, ...) <qspi_master_pkg.qspi_transfer>`
     - Non-blocking: queue one transaction. ``cmd``, ``addr`` and ``wr_data`` are byte arrays read
       during the call only, so the caller keeps them; ``null_integer_array`` is an empty phase
   * - :vhdl:`await_qspi_transfer_reply(net, reference, data) <qspi_master_pkg.await_qspi_transfer_reply>`
     - Blocking: wait until the transaction is complete. ``data`` is replaced by a new array of the
       ``num_read_bytes`` bytes read, which the caller deallocates; an array ``data`` already held is
       deallocated first. Without ``data``, the read bytes are discarded
   * - ``qspi_transfer(net, qspi_master, cmd, data, ...)``
     - Blocking: queue and redeem in one call
   * - ``qspi_transfer(net, qspi_master, cmd, ...)``
     - Blocking, for a transaction without read bytes
   * - :vhdl:`set_sck_period(net, qspi_master, period) <qspi_master_pkg.set_sck_period>`
     - Blocking: the SCK period of every transaction queued after the call
   * - :vhdl:`reset(net, qspi_master) <qspi_master_pkg.reset>`
     - Blocking: abort a transfer in progress within its current SCK half period (SCK low, I/Os
       released, CS high), drop the transfers queued before the reset, and return after the CS
       deselect time. The callers of those transfers get replies: the bytes read before the abort, or
       none for a dropped transfer, so ``data`` can be shorter than ``num_read_bytes``. The master logs
       them at level info. It works while the far end is stuck, since the master drives the clock
   * - :vhdl:`set_check_enabled(net, qspi_master, check, enabled) <qspi_master_pkg.set_check_enabled>`,
       :vhdl:`get_check_count(net, qspi_master, check, count) <qspi_master_pkg.get_check_count>` and
       ``get_check_count(net, qspi_master, check, reference)``
     - The procedures of the :doc:`qspi_protocol_checker` for the protocol checker of the master. A master
       without one reports ``<id> has no protocol checker`` as a check failure on its checker; the
       blocking ``get_check_count`` then returns 0, and the reference is ``null_msg``
   * - ``get_id``, ``get_logger``, ``get_actor``, ``get_checker``, ``as_sync``
     - The identity of the master. ``wait_until_idle(net, as_sync(qspi_master))`` waits for every
       queued transaction
   * - :vhdl:`qspi_master_pkg.sck_period`, :vhdl:`qspi_master_pkg.cs_deselect_time`,
       :vhdl:`qspi_master_pkg.protocol_checker`
     - The values of the handle. ``sck_period`` is the initial period, not one set later

The optional parameters of ``qspi_transfer`` are ``cmd_lanes``, ``addr``, ``addr_lanes``,
``wr_data``, ``wr_lanes``, ``dummy_cycles``, ``num_read_bytes`` and ``read_lanes``; the lane widths
default to 1 and the counts to 0. :vhdl:`new_byte_array <qspi_master_pkg.new_byte_array>` makes a
byte array of integer literals, such as ``new_byte_array((16#06#, 16#A5#))``; the caller deallocates it.

JEDEC command layer
~~~~~~~~~~~~~~~~~~~

``qspi_flash_cmd_pkg`` wraps one command per blocking procedure. Every procedure takes
``opcode_lanes`` (4 in QPI mode), and every one with an address takes ``addr_bytes`` (3 or 4). Dummy
cycles default to the JEDEC values and are parameters, since parts can differ.

.. list-table::
   :header-rows: 1
   :widths: 38 20 42

   * - Procedure
     - Opcode
     - Shape
   * - :vhdl:`qspi_flash_read_id <qspi_flash_cmd_pkg.qspi_flash_read_id>`
     - ``0x9F``
     - ``num_bytes`` ID bytes, 3 by default
   * - :vhdl:`qspi_flash_read <qspi_flash_cmd_pkg.qspi_flash_read>`
     - ``0x03``
     - Address and data on ``lanes``
   * - :vhdl:`qspi_flash_fast_read <qspi_flash_cmd_pkg.qspi_flash_fast_read>`
     - ``0x0B``
     - Address and data on ``lanes``, 8 dummy cycles
   * - :vhdl:`qspi_flash_quad_output_read <qspi_flash_cmd_pkg.qspi_flash_quad_output_read>`
     - ``0x6B``
     - Address x1, 8 dummy cycles, data x4
   * - :vhdl:`qspi_flash_quad_io_read <qspi_flash_cmd_pkg.qspi_flash_quad_io_read>`
     - ``0xEB``
     - Address and ``mode_byte`` x4 (``send_mode_byte => false`` omits it), 4 dummy cycles, data x4
   * - :vhdl:`qspi_flash_write_enable <qspi_flash_cmd_pkg.qspi_flash_write_enable>`
     - ``0x06``
     -
   * - :vhdl:`qspi_flash_page_program <qspi_flash_cmd_pkg.qspi_flash_page_program>`
     - ``0x02``
     - ``data`` is a byte array or a ``std_ulogic_vector`` of whole bytes, such as ``x"DEADBEEF"``;
       ``opcode => qspi_flash_op_quad_page_program, data_lanes => 4`` for ``0x32``
   * - :vhdl:`qspi_flash_sector_erase <qspi_flash_cmd_pkg.qspi_flash_sector_erase>`
     - ``0x20``
     -
   * - :vhdl:`qspi_flash_block_erase <qspi_flash_cmd_pkg.qspi_flash_block_erase>`
     - ``0xD8``
     - ``opcode => qspi_flash_op_block_erase_32k`` for ``0x52``
   * - :vhdl:`qspi_flash_chip_erase <qspi_flash_cmd_pkg.qspi_flash_chip_erase>`
     - ``0xC7``
     -
   * - :vhdl:`qspi_flash_read_status <qspi_flash_cmd_pkg.qspi_flash_read_status>`
     - ``0x05``, ``0x35``, ``0x15``
     - Status register ``register_index`` 1, 2 or 3
   * - :vhdl:`qspi_flash_write_status <qspi_flash_cmd_pkg.qspi_flash_write_status>`
     - ``0x01``, ``0x31``, ``0x11``
     - One byte to status register ``register_index`` 1, 2 or 3
   * - :vhdl:`qspi_flash_enter_4byte <qspi_flash_cmd_pkg.qspi_flash_enter_4byte>`,
       :vhdl:`qspi_flash_exit_4byte <qspi_flash_cmd_pkg.qspi_flash_exit_4byte>`
     - ``0xB7``, ``0xE9``
     -
   * - :vhdl:`qspi_flash_enter_qpi <qspi_flash_cmd_pkg.qspi_flash_enter_qpi>`,
       :vhdl:`qspi_flash_exit_qpi <qspi_flash_cmd_pkg.qspi_flash_exit_qpi>`
     - ``0x38``, ``0xFF``
     - ``qspi_flash_exit_qpi`` sends its opcode on four lanes by default

The package also has the opcode constants (``qspi_flash_op_*``), the default dummy cycle counts, and
:vhdl:`qspi_flash_cmd_pkg.qspi_flash_opcode_bytes` and :vhdl:`qspi_flash_cmd_pkg.qspi_flash_address_bytes`
to build byte arrays for ``qspi_transfer``. Its commands target the :doc:`qspi_flash` model; the
supported opcodes are listed there.

Checks
------

* **Metavalues on read lanes.** A ``U``, ``X``, ``Z``, ``W`` or ``-`` sampled on a data lane in a read
  phase is a check failure on the checker of the master, ``Read byte <n> beat <m>: the far end drove
  <value> on the data lanes``, and counts as ``0``.
* **Unexpected messages**, a check failure ``Got unexpected message <type>`` on the checker of the
  master unless ``unexpected_msg_type_policy`` is ``ignore``.
* **Pin timing** of the master's own outputs, only with a ``protocol_checker``. Its violations go to
  the checker of the protocol checker, ``<master id>:protocol_checker`` unless it has its own id.

Statistics notes
----------------

The master keeps no statistics. With a protocol checker, ``get_check_count(net, master, check,
count)`` counts violations per rule.

Example
-------

``tests/vhdl/tb_flash.vhd`` connects a master to a flash on one bus. The handles and signals:

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

The command layer and ``qspi_transfer`` together, arming continuous read with ``0xEB`` and then
reading without an opcode:

.. literalinclude:: ../../tests/vhdl/tb_flash.vhd
   :language: vhdl
   :start-after: -- docs-start: qspi_master_continuous_read
   :end-before: -- docs-end: qspi_master_continuous_read
   :dedent: 8

``ramp`` and ``check_bytes`` are helpers of the testbench. ``tests/vhdl/tb_qspi_master.vhd`` checks
the master bit by bit against a stub device.

Limitations
-----------

.. note::

   * **SPI mode 0 only.** Mode 3 (SCK idling high) is not supported.
   * **Fixed CS framing.** CS setup and hold are half an SCK period; only the deselect time is a
     parameter.
   * **Addresses up to 2 GiB.** The command layer takes addresses as a ``natural``.
   * **One device per bus.** CS is a single line.
