Flash
=====

The flash family verifies designs that talk to serial NOR flash over QSPI. It has three verification
components (VCs):

* :doc:`qspi_flash`, the :vhdl:`flash` entity: a QSPI NOR flash responder for a DUT that reads,
  programs or boots from flash. A testbench configures and inspects it from VHDL and never writes
  Python; the same device model, :py:class:`~awesome_vunit_vcs.flash.device.FlashDevice`, can also be
  used in plain ``pytest``.
* :doc:`qspi_master`, the :vhdl:`qspi_master` entity: a QSPI master that drives the bus from a
  testbench, with a flash command layer on top. It replaces a flash controller DUT, or exercises the
  flash without one.
* :doc:`qspi_protocol_checker`, the :vhdl:`qspi_protocol_checker` entity: a passive checker of the pin
  timing the master on a QSPI bus must meet.

.. _flash-quick-start:

Quick start
-----------

A DUT that boots from a flash image, tested in full. The flash has the default configuration of a
16 MiB part and checks the pin timing of the DUT with a default protocol checker. The test loads an
Intel HEX image, releases the reset, and checks that the RAM of the DUT holds the image and that the
boot wrote nothing:

.. literalinclude:: ../../tests/vhdl/tb_flash_boot_example.vhd
   :language: vhdl
   :start-after: -- docs-start: boot-example
   :end-before: -- docs-end: boot-example

``tests/vhdl/tb_flash_boot_example.vhd`` runs in CI on GHDL and NVC. Its DUT,
``tests/vhdl/boot_reader.vhd``, reads a length header and then the image with fast read (``0x0B``).
The test uses :vhdl:`flash_pkg.flash_load_image`, :vhdl:`flash_pkg.flash_check_content` and
:vhdl:`flash_pkg.flash_get_written_regions`.
The rest of this page and the pages of the components describe the deeper layers: device
configuration, bus-level stimulus from a :doc:`qspi_master`, statistics, protection and busy times.

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.flash_context;

``flash_context`` is the only context clause a flash testbench needs. It makes ``qspi_pkg``,
``qspi_master_pkg``, ``qspi_flash_cmd_pkg``, ``qspi_protocol_checker_pkg`` and ``flash_pkg`` visible,
together with ``ieee.std_logic_1164``, ``vunit_context``, ``com_context``, ``sync_pkg``,
``integer_array_pkg`` and ``vc_pkg``. Add ``ieee.numeric_std`` where a testbench needs it. The
generated reference of every declaration is :doc:`../reference/vhdl/flash`.

How the components relate
-------------------------

.. code-block:: text

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

A checker can be instantiated on any bus as an entity of its own. The flash and the master can also
own one: pass a handle created with
:vhdl:`new_qspi_protocol_checker <qspi_protocol_checker_pkg.new_qspi_protocol_checker>` as the
``protocol_checker`` parameter of :vhdl:`flash_pkg.new_flash` or
:vhdl:`qspi_master_pkg.new_qspi_master`, and the component instantiates the checker on its own pins.
The default is :vhdl:`qspi_protocol_checker_pkg.null_qspi_protocol_checker`, so **pin timing is only
checked where a protocol checker is passed or instantiated**. A checker in both the master and the
flash of one bus reports every violation twice. :vhdl:`set_check_enabled <flash_pkg.set_check_enabled>`
and :vhdl:`get_check_count <flash_pkg.get_check_count>` take the flash, and
:vhdl:`set_check_enabled <qspi_master_pkg.set_check_enabled>` and
:vhdl:`get_check_count <qspi_master_pkg.get_check_count>` the master, for the checker it owns;
:vhdl:`protocol_checker(flash) <flash_pkg.protocol_checker>` returns that checker, for its logger and
the rest of its procedures. :vhdl:`reset <flash_pkg.reset>`,
:vhdl:`reset <qspi_master_pkg.reset>` and :vhdl:`reset <qspi_protocol_checker_pkg.reset>` return each
component to its idle state between tests.

.. code-block:: vhdl

   constant master : qspi_master_t := new_qspi_master;
   constant boot_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns));
   ...
   -- The counts and rule switches of the checker the flash instantiated
   get_check_count(net, boot_flash, qspi_cs_deselect, count);

Identities
----------

Every handle has an id, and the logger, actor and checker of the component derive from it unless they
are passed explicitly. Log messages therefore name the component they come from:

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

Reports of the flash model start with the full name of its id, for example
``tb:boot_flash: flash content mismatch at 0x00001000 ...``. Two flashes with the same id are a
failure on the logger of the second while it is elaborated: ``Two verification components have the id
tb:boot_flash and would share one Python backend``. Give every flash its own id, or leave the ids out.

Checks
------

A protocol checker runs the pin timing checks, all enabled by default, with the minimum times given to
:vhdl:`new_qspi_protocol_checker <qspi_protocol_checker_pkg.new_qspi_protocol_checker>` and switched
with :vhdl:`qspi_protocol_checker_pkg.set_check_enabled`; the check names are the literals of
:vhdl:`qspi_protocol_checker_pkg.qspi_check_t`. A violation's message starts with the check ID in upper
case, such as ``QSPI_CS_DESELECT``. Errors a VC detects are
check failures on its checker; everything else is a failure on its logger. By default the first error
stops the simulation, as any VUnit check failure does.

.. list-table::
   :header-rows: 1
   :widths: 20 45 20 15

   * - Check
     - Violation
     - Configured by
     - Reported by
   * - ``qspi_sck_period``
     - SCK rising edge to the next rising edge too short (1/fC)
     - ``t_sck_min``
     - ``qspi_protocol_checker``
   * - ``qspi_sck_high``
     - SCK rising edge to the next falling edge too short (tCLH)
     - ``t_sck_high_min``
     - ``qspi_protocol_checker``
   * - ``qspi_sck_low``
     - SCK falling edge to the next rising edge too short (tCLL)
     - ``t_sck_low_min``
     - ``qspi_protocol_checker``
   * - ``qspi_cs_setup``
     - CS falling edge to the first SCK rising edge too short (tSLCH)
     - ``t_slch``
     - ``qspi_protocol_checker``
   * - ``qspi_cs_hold``
     - Last SCK rising edge to the CS rising edge too short (tCHSH)
     - ``t_chsh``
     - ``qspi_protocol_checker``
   * - ``qspi_cs_deselect``
     - CS high time between two commands too short (tSHSL)
     - ``t_shsl``
     - ``qspi_protocol_checker``
   * - ``qspi_data_setup``
     - Last change of a lane the master drives to the SCK rising edge too short (tDVCH)
     - ``t_dvch``
     - ``qspi_protocol_checker``
   * - ``qspi_data_hold``
     - SCK rising edge to a change or release of a lane the master drove at it too short (tCHDX)
     - ``t_chdx``
     - ``qspi_protocol_checker``
   * - Metavalue on sampled lanes
     - ``U``, ``X``, ``Z``, ``W`` or ``-`` on a lane the flash samples for data in
     -
     - ``flash``
   * - Metavalue on read lanes
     - A metavalue on a lane the master samples in a read phase
     -
     - ``qspi_master``
   * - Content mismatch
     - :vhdl:`flash_pkg.flash_check_content` or :vhdl:`flash_pkg.flash_check_content_fill` finds a byte
       that differs (:py:class:`~awesome_vunit_vcs.flash.errors.ContentMismatch` in Python)
     -
     - ``flash``
   * - Version mismatch
     - The VHDL and Python parts of the package come from different versions, at time 0
     -
     - ``flash``
   * - Request failure
     - A request the model cannot carry out: an invalid configuration, a range outside the device, a value
       that is not a byte, an unknown timing or stat name, an image that cannot be read
       (:py:class:`~awesome_vunit_vcs.flash.errors.FlashValueError` or another exception in Python)
     -
     - ``flash``, on its logger
   * - Duplicate id
     - A second flash with the id of another, which would share its Python backend, at elaboration
     -
     - ``flash``, on its logger
   * - Unexpected message
     - A message of an unknown type with the ``fail`` policy (the default) is a check failure,
       ``Got unexpected message <type>``; ``ignore`` drops it silently
     - ``unexpected_msg_type_policy``
     - All three

Commands a real part refuses silently, such as a program without write enable, are not errors: the
flash counts them instead, see :ref:`flash-statistics`.

A test that expects an error disables the stop, counts the errors and resets the count, so that an
unexpected error still fails the test at ``test_runner_cleanup``. The pages of the components have
excerpts.

The content of a flash is read and checked with :vhdl:`flash_pkg.flash_read_back`,
:vhdl:`flash_pkg.flash_check_content` and :vhdl:`flash_pkg.flash_check_content_fill`; there is no VUnit
memory model view of it.

.. toctree::
   :maxdepth: 2

   qspi_flash
   qspi_master
   qspi_protocol_checker
