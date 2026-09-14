Flash
=====

The flash family verifies designs that talk to serial NOR flash over QSPI. It has three verification
components (VCs):

* :doc:`qspi_flash`, the ``flash`` entity: a QSPI NOR flash responder. The VHDL entity samples and
  drives the pins; every decision about what the bytes on the wire mean is taken by a simulator
  independent Python device model, ``FlashDevice``, that also runs in plain ``pytest``.
* :doc:`qspi_master`, the ``qspi_master`` entity: a QSPI master that drives the bus from a testbench,
  with a JEDEC command layer on top. It replaces a flash controller DUT, or exercises the flash
  without one.
* :doc:`qspi_protocol_checker`, the ``qspi_protocol_checker`` entity: a passive checker of the pin
  timing the master on a QSPI bus must meet.

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
flash of one bus reports every violation twice.

.. code-block:: vhdl

   constant master : qspi_master_t := new_qspi_master;
   constant boot_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns));
   ...
   -- The checker the flash instantiated, for its logger, counts and rule switches
   get_check_count(net, protocol_checker(boot_flash), qspi_cs_deselect, count);

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

The flash is also the identity of its Python session: reports of its backend start with the full name
of its id, for example ``tb:boot_flash: flash content mismatch at 0x00001000 ...``. Two flashes with
the same id would share one Python backend, so the second is a failure on its logger while it is
elaborated: ``Two verification components have the id tb:boot_flash and would share one Python
backend``. Give every flash its own id, or leave the ids out.

Checks
------

Errors a VC detects are check failures on its checker; everything else is a failure on its logger. By
default the first error stops the simulation, as any VUnit check failure does.

.. list-table::
   :header-rows: 1
   :widths: 22 12 22 44

   * - Check
     - Datasheet
     - Reported by
     - Trigger
   * - ``QSPI_SCK_PERIOD``
     - 1/fC
     - ``qspi_protocol_checker``
     - SCK rising edge to the next rising edge shorter than ``t_sck_min``
   * - ``QSPI_SCK_HIGH``
     - tCLH
     - ``qspi_protocol_checker``
     - SCK rising edge to the next falling edge shorter than ``t_sck_high_min``
   * - ``QSPI_SCK_LOW``
     - tCLL
     - ``qspi_protocol_checker``
     - SCK falling edge to the next rising edge shorter than ``t_sck_low_min``
   * - ``QSPI_CS_SETUP``
     - tSLCH
     - ``qspi_protocol_checker``
     - CS falling edge to the first SCK rising edge shorter than ``t_slch``
   * - ``QSPI_CS_HOLD``
     - tCHSH
     - ``qspi_protocol_checker``
     - Last SCK edge to the CS rising edge shorter than ``t_chsh``
   * - ``QSPI_CS_DESELECT``
     - tSHSL
     - ``qspi_protocol_checker``
     - CS high time between two commands shorter than ``t_shsl``
   * - ``QSPI_DATA_SETUP``
     - tDVCH
     - ``qspi_protocol_checker``
     - Last change of a lane the master drives to the SCK rising edge shorter than ``t_dvch``
   * - ``QSPI_DATA_HOLD``
     - tCHDX
     - ``qspi_protocol_checker``
     - SCK rising edge to a change or release of a lane the master drove at it shorter than ``t_chdx``
   * - Metavalue on sampled lanes
     -
     - ``flash``
     - ``U``, ``X``, ``Z``, ``W`` or ``-`` on a lane the flash samples for data in
   * - Metavalue on read lanes
     -
     - ``qspi_master``
     - A metavalue on a lane the master samples in a read phase
   * - Content mismatch
     -
     - ``flash``
     - ``flash_check_content`` or ``flash_check_content_fill`` finds a byte that differs
   * - Directive layout
     -
     - ``flash``
     - The Python backend has another directive layout version than ``flash_pkg``, at time 0
   * - Backend failure
     -
     - ``flash``, on its logger
     - A request the model cannot carry out: an invalid configuration, a range outside the device, a
       value that is not a byte, an unknown timing or stat name, an image that cannot be read
   * - Duplicate id
     -
     - ``flash``, on its logger
     - A second flash with the id of another, which would share its Python backend, at elaboration
   * - Unexpected message
     -
     - All three
     - A message of an unknown type with ``unexpected_msg_type_policy => fail`` (the default) is a
       check failure, ``Got unexpected message <type>``; ``ignore`` drops it silently

Commands a real part refuses silently, such as a program without write enable, are not errors: the
flash counts them instead, see :ref:`flash-statistics`.

A test that expects an error disables the stop, counts the errors and resets the count, so that an
unexpected error still fails the test at ``test_runner_cleanup``. The pages of the components have
excerpts.

Why not VUnit's memory model
----------------------------

VUnit's ``memory_pkg`` is a good model for a bus memory, but its ``memory_t`` is dense: every byte of
the address space is allocated, with per-byte permissions and expectations. The flash content lives
in Python instead, as a sparse array with NOR semantics (programming only clears bits, erasing sets
``0xFF``) and region protection, which is what lets a 16 MiB part filled with a pattern cost a few
objects. A ``memory_t`` view of it would duplicate that state and would have to be kept in step on
every program and erase. The preload, read-back and check procedures of the flash are its memory
access API.

.. toctree::
   :maxdepth: 2

   qspi_flash
   qspi_master
   qspi_protocol_checker
