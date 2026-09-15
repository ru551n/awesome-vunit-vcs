Flash
=====

The flash family verifies designs that talk to serial NOR flash over QSPI. It has three verification
components (:term:`VCs <VC>`) that share one bus, so a test combines them as its design needs.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - VC
     - Role
   * - :vhdl:`flash`
     - A QSPI NOR flash responder for a DUT that reads, programs or boots from flash. A testbench
       configures and inspects it from VHDL and never writes Python.
   * - :vhdl:`qspi_master`
     - Drives the bus from a testbench, with a flash command layer on top. It replaces a flash
       controller DUT, or exercises the flash without one.
   * - :vhdl:`qspi_protocol_checker`
     - Observes the bus and checks the pin timing the master must meet. Never drives.

The device model behind the flash, :py:class:`~awesome_vunit_vcs.flash.device.FlashDevice`, also works
in plain ``pytest``.

What's here
-----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`qspi_flash`, :doc:`qspi_master`, :doc:`qspi_protocol_checker`
     - One page per VC: pins, constructors, procedures and options
   * - :doc:`checks`, :doc:`configuration`, :doc:`commands`, :doc:`statistics`
     - The checks and error messages, every option, the supported opcodes and the statistics
   * - :doc:`../cookbook/flash_boot`
     - Recipes: boot from an image, check writes, check pin timing, reset, custom transfers
   * - :doc:`python`
     - The flash device model in Python, without a simulator
   * - :doc:`vhdl_api`
     - Every VHDL package, context and entity of the family
   * - :doc:`python_api`
     - Every public Python name of ``awesome_vunit_vcs.flash``

.. _flash-quick-start:

The pattern
-----------

.. literalinclude:: ../../examples/flash/tb_flash_examples.vhd
   :caption: examples/flash/tb_flash_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: boot
   :end-before: -- docs-end: boot
   :dedent:

This test checks a DUT that boots from a flash image; :doc:`../cookbook/flash_boot` builds it up step by step. The flash has the default configuration of a
16 MiB part and checks the pin timing of the DUT with a default protocol checker. The test loads an
Intel HEX image, releases the reset, and checks that the RAM of the DUT holds the image and that the
boot wrote nothing.

The DUT, ``examples/flash/src/boot_reader.vhd``, reads a length header and then the image with fast read
(``0x0B``). The test uses :vhdl:`flash_pkg.flash_load_image`, :vhdl:`flash_pkg.flash_check_content`
and :vhdl:`flash_pkg.flash_get_written_regions`, and runs in CI on GHDL and NVC.

.. code-block:: vhdl
   :caption: Testbench context clause

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.flash_context;

``flash_context`` is the only context clause a flash testbench needs. It makes ``qspi_pkg``,
``qspi_master_pkg``, ``qspi_flash_cmd_pkg``, ``qspi_protocol_checker_pkg`` and ``flash_pkg`` visible,
together with ``ieee.std_logic_1164``, ``vunit_context``, ``com_context``, ``sync_pkg``,
``integer_array_pkg`` and ``vc_pkg``. Add ``ieee.numeric_std`` where a testbench needs it.

Combine the components on one bus
---------------------------------

.. code-block:: text
   :caption: One QSPI bus

                         m2s : qspi_m2s_t (sck, cs_n, io)
     +-------------+  ------------------------------------>  +-------------+
     | qspi_master |                                         |    flash    |
     |  or a DUT   |  <------------------------------------  |   or a DUT  |
     +-------------+         s2m : qspi_s2m_t (io)           +-------------+
                                    |
                                    v
                        qspi_protocol_checker (passive)

The master drives the bus, the flash answers, and the checker watches. Each end drives its own
unresolved record, so a waveform shows which end drove an I/O lane, and ``qspi_io_value(m2s, s2m)``
gives what a probe on the four wires would see. A DUT on either side connects through a small adapter
between its tri-state pins and the records.

.. code-block:: vhdl
   :caption: A flash that owns a protocol checker

   constant master : qspi_master_t := new_qspi_master;
   constant boot_flash : flash_t :=
     new_flash(protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns));
   ...
   -- The counts and rule switches of the checker the flash instantiated
   get_check_count(net, boot_flash, qspi_cs_deselect, count);

* A checker can be instantiated on any bus as an entity of its own.
* The flash and the master can also own one: pass a handle created with
  :vhdl:`new_qspi_protocol_checker <qspi_protocol_checker_pkg.new_qspi_protocol_checker>` as the
  ``protocol_checker`` parameter of :vhdl:`flash_pkg.new_flash` or
  :vhdl:`qspi_master_pkg.new_qspi_master`, and the component instantiates the checker on its own pins.
* The default is :vhdl:`qspi_protocol_checker_pkg.null_qspi_protocol_checker`, so pin timing is only
  checked where a protocol checker is passed or instantiated.
* A checker in both the master and the flash of one bus reports every violation twice.
* ``set_check_enabled`` and ``get_check_count`` work on a flash and on a master alike, for the protocol
  checker that component owns: :vhdl:`flash_pkg.set_check_enabled` and :vhdl:`flash_pkg.get_check_count`
  on a flash, :vhdl:`qspi_master_pkg.set_check_enabled` and :vhdl:`qspi_master_pkg.get_check_count` on a
  master.
* :vhdl:`protocol_checker(flash) <flash_pkg.protocol_checker>` returns that checker, for its logger and
  the rest of its procedures.

Handles and identity
--------------------

Constructors take the VC configuration first, then ``protocol_checker`` (flash and master) and the
standard VUnit parameters ``id``, ``logger``, ``actor``, ``checker`` and
``unexpected_msg_type_policy``, all with defaults. The logger, actor and checker of a component derive
from its id unless they are passed explicitly, so log messages name the component they come from.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Constructed with
     - Id
   * - No ``id``
     - ``awesome_vunit_vcs:<vc>:<n>``, where ``<vc>`` is ``flash``, ``qspi_master`` or
       ``qspi_protocol_checker`` and ``<n>`` numbers the default ids from 1
   * - ``id => get_id("tb:boot_flash")``
     - ``tb:boot_flash``
   * - A protocol checker without an explicit ``id``, passed to ``new_flash`` or ``new_qspi_master``
     - ``<parent id>:protocol_checker``, for example ``tb:boot_flash:protocol_checker``. The logger,
       actor and checker that were not passed explicitly are derived from this id. The checker uses
       up no default id and leaves no actor behind: a checker constructed without an ``id`` gets its
       default id the first time it is needed, by its own entity or an accessor such as ``get_id``.
   * - A protocol checker with an explicit ``id``, passed to ``new_flash`` or ``new_qspi_master``
     - Its own id; the handle is used unchanged

* Reports of the flash model start with the full name of its id, for example
  ``tb:boot_flash: flash content mismatch at 0x00001000 ...``.
* Two flashes with the same id are a failure on the logger of the second while it is elaborated:
  ``Two verification components have the id tb:boot_flash and would share one Python backend``. Give
  every flash its own id, or leave the ids out.
* ``get_id``, ``get_logger``, ``get_actor`` and ``get_checker`` return them.
* A message a VC does not handle is a check failure unless ``unexpected_msg_type_policy`` is ``ignore``.

Standard interfaces
-------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Function
     - VUnit interface
   * - ``as_sync(vc)``
     - Sync, on every VC: ``wait_until_idle`` and ``wait_for_time``.

Procedures
----------

Every procedure takes ``net`` first. Procedures that return nothing only send a message, handled in
order, and ``wait_until_idle`` waits for them. A procedure that returns a value blocks; most also have
a non-blocking form returning a reference, read later with the matching ``await_`` procedure.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - Page
   * - ``flash_preload``, ``flash_preload_fill``, ``flash_load_image``
     - :doc:`qspi_flash`
   * - ``flash_read_back``, ``flash_check_content``, ``flash_check_content_fill``,
       ``flash_get_written_regions``
     - :doc:`qspi_flash`
   * - ``flash_set_timing_enable``, ``flash_set_timing``, ``flash_set_protection``,
       ``flash_wait_until_ready``, ``flash_get_stat``
     - :doc:`qspi_flash`
   * - ``qspi_transfer``, ``set_sck_period`` and the ``qspi_flash_*`` commands
     - :doc:`qspi_master`
   * - ``set_check_enabled``, ``get_check_count``
     - :doc:`qspi_protocol_checker`, also on a flash or master that owns one
   * - ``reset``
     - Below

Recover a component with :vhdl:`reset <flash_pkg.reset>`, :vhdl:`reset <qspi_master_pkg.reset>` or
:vhdl:`reset <qspi_protocol_checker_pkg.reset>`. It returns the component to its idle state between
tests:

.. list-table::
   :widths: 25 75

   * - Flash
     - Returns to standby as a power-on reset and drops a transaction in progress. Keeps content and
       locks, and statistics unless ``clear_statistics => true``.
   * - QSPI master
     - Aborts the transfer in progress and drops queued ones. Works while the far end is stuck.
   * - Protocol checker
     - Sets its counts to 0 and forgets the timing history. Keeps its rule switches.

Every declaration is listed in the :doc:`vhdl_api`.

Read :doc:`checks` for every check and error the family reports, and how to count them in a
negative test.

.. toctree::
   :maxdepth: 1
   :hidden:

   qspi_flash
   qspi_master
   qspi_protocol_checker
   checks
   configuration
   commands
   statistics
   python
   vhdl_api
   python_api
