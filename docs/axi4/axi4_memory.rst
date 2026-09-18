AXI4 memory
===========

An :vhdl:`axi4_memory_t <axi4_memory_pkg.axi4_memory_t>` is the memory behind the
:doc:`AXI4 read and write slaves <axi4_slaves>`: what VUnit's ``memory_t`` offers, on a sparse store, so
a 64-bit address space costs nothing until it is touched.

.. include:: ../_includes/vunit_names.inc

Overview
--------

The memory holds bytes, a permission per byte, an expected value per byte, and named buffers. The
testbench reads and writes it directly (backdoor access, which ignores the permissions); the slaves
check the permissions and the expected values of every byte they move. One memory serves any number of
slaves, so a read slave returns what a write slave wrote.

The content lives in Python (:py:class:`~awesome_vunit_vcs.axi4.memory_model.MemoryModel`), in the
sparse store the QSPI flash also uses: a fill or a permission over any range is one operation, and only
the pages written byte by byte take memory. The memory is not a verification component: it has no actor
and its subprograms call Python directly.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Handle
     - :vhdl:`axi4_memory_t <axi4_memory_pkg.axi4_memory_t>`, created with
       :vhdl:`new_axi4_memory <axi4_memory_pkg.new_axi4_memory>`
   * - Address space
     - 64 bits; addresses are ``natural`` or ``u_unsigned`` of up to 64 bits
   * - Types from VUnit
     - ``permissions_t`` (``no_access``, ``write_only``, ``read_only``, ``read_and_write``) and
       ``endianness_arg_t`` (``little_endian``, ``big_endian``, ``default_endian``) of ``memory_pkg``
   * - Images
     - Intel HEX, Motorola S-record, raw binary and JSON, the formats of the flash family
   * - Tested on
     - GHDL, NVC

Constructor parameters
----------------------

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: memory
   :end-before: -- docs-end: memory
   :dedent:

.. list-table::
   :header-rows: 1
   :widths: 25 20 15 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``size_bytes``
     - ``natural``
     - ``0``
     - The number of addresses; an access beyond is a failure ``address N out of range 0 to M``. 0 is
       the whole 64-bit space.
   * - ``default_value``
     - ``natural range 0 to 255``
     - ``0``
     - The value of a byte never written
   * - ``default_permissions``
     - ``permissions_t``
     - ``read_and_write``
     - The permission of a byte never allocated or given one. ``read_and_write`` makes a plain RAM;
       ``no_access`` makes the slaves fail on anything not allocated, like VUnit's memory.
   * - ``endian``
     - ``endianness_t``
     - ``little_endian``
     - The byte order of words when a call gives ``default_endian``
   * - ``id``, ``logger``, ``checker``
     - ``id_t``, ``logger_t``, ``checker_t``
     - Derived
     - ``id`` defaults to ``awesome_vunit_vcs:axi4_memory:<n>``, the logger to the logger of the id and
       the checker to a checker on the logger. The Python session of the memory has this id.

Subprograms
-----------

Every subprogram taking an address as a ``natural`` also takes it as a ``u_unsigned`` of up to 64 bits.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Subprograms
     - What they do
   * - ``allocate(memory, num_bytes, name, alignment, permissions)``
     - A buffer after the last one, aligned, as VUnit's ``allocate``
   * - ``allocate(memory, address, num_bytes, name, permissions)``
     - A buffer at an address, anywhere in the 64-bit space
   * - ``name``, ``num_bytes``, ``base_address``, ``last_address``, ``wide_base_address``
     - The buffer; ``wide_base_address`` is the ``u_unsigned(63 downto 0)`` address of any buffer
   * - ``clear``, ``num_bytes(memory)``, ``describe_address``
     - Forget everything; where the next buffer starts; ``address 5 at offset 3 within buffer 'name'
       at range (2 to 11)``
   * - ``write_byte``, ``read_byte``, ``write_word``, ``read_word``, ``write_integer``
     - Backdoor access by byte, word (with an ``endian``) and integer of 1 to 4 bytes
   * - ``write_bytes``, ``read_bytes``, ``fill``
     - Bulk content as an ``integer_array_t``, and a range of one value in one operation
   * - ``write_integer_array``, ``set_expected_integer_array``, ``allocate_integer_array``
     - VUnit's ``memory_utils_pkg`` for ``integer_array_t``, with a stride per row
   * - ``load_image(memory, file_name, image_format, base)``
     - Preload an image file; ``image_format`` "" infers it from the extension
   * - ``get_permissions``, ``set_permissions``
     - A byte, or ``num_bytes`` bytes from an address
   * - ``set_expected_byte``, ``set_expected_word``, ``set_expected_integer``, ``get_expected_byte``,
       ``has_expected_byte``, ``clear_expected_byte``
     - Expected data: what a slave must write
   * - ``check_expected_was_written``, ``expected_was_written``
     - For a range, a buffer or the whole memory: every byte with an expected value holds it

Preload an image into a buffer the slaves may only read (VHDL):

.. literalinclude:: ../../examples/axi4/tb_axi4_slave_examples.vhd
   :caption: examples/axi4/tb_axi4_slave_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: preload
   :end-before: -- docs-end: preload
   :dedent:

Checks
------

The memory has no check IDs. Its failures are check failures, worded like VUnit's:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Failure
     - Message
   * - A slave accesses a byte its permission forbids
     - ``Reading from address 0 at offset 0 within anonymous buffer at range (0 to 15) without permission
       (no_access)``, on the checker of the slave
   * - A byte is written with another value than it expects
     - ``Writing to address 1 ... Got 0 expected 77``, on the checker of the slave, or of the memory for
       backdoor writes, which are then not done
   * - An expected byte was never written
     - ``The address 2 ... was never written with expected byte 66``, on the checker of the memory
   * - An address beyond ``size_bytes``
     - ``Writing to address 1 out of range 0 to 0``

One access that breaks a rule for several bytes gives one message, naming the first byte and ending in
``(and N more bytes)``.

Python backend
--------------

The memory creates an :py:class:`~awesome_vunit_vcs.axi4.vunit_backend.Axi4MemoryBackend` in its own
Python session the first time it is used. It holds the
:py:class:`~awesome_vunit_vcs.axi4.memory_model.MemoryModel` and one
:py:class:`~awesome_vunit_vcs.axi4.slave.Axi4Slave` per slave attached to it, each with reports of its
own. The content, permissions and expected values are four
:py:class:`~awesome_vunit_vcs.common.sparse_memory.SparseMemory` stores.

.. note::

   * ``base_address``, ``last_address`` and ``num_bytes(memory)`` return ``natural``; use
     ``wide_base_address`` for buffers beyond 2 GiB.
   * VUnit's ``memory_utils_pkg`` subprograms for ``integer_vector_ptr_t`` have no counterpart; use
     ``integer_array_t``.

   Details are in
   `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#axi4-read-and-write-slaves-1>`__.
