Flash checks and errors
=======================

What the flash family reports, where it reports it, and how to switch checks off or count them.

Check the pin timing
--------------------

A protocol checker runs the pin timing checks, all enabled by default, with the minimum times given to
:vhdl:`new_qspi_protocol_checker <qspi_protocol_checker_pkg.new_qspi_protocol_checker>`. They are
switched with :vhdl:`qspi_protocol_checker_pkg.set_check_enabled`, and the check names are the literals
of :vhdl:`qspi_protocol_checker_pkg.qspi_check_t`.

A violation's message starts with the check ID in upper case, such as ``QSPI_CS_DESELECT``. Errors a VC
detects are check failures on its checker, and everything else is a failure on its logger. By default
the first error stops the simulation, as any VUnit check failure does.

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
     - CS high time between two commands too short (:term:`tSHSL`)
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

* Commands a real part refuses silently, such as a program without write enable, are not errors: the
  flash counts them instead, see :ref:`flash-statistics`.
* A test that expects an error disables the stop, counts the errors and resets the count, so that an
  unexpected error still fails the test at ``test_runner_cleanup``. The pages of the components have
  excerpts.
* The content of a flash is read and checked with :vhdl:`flash_pkg.flash_read_back`,
  :vhdl:`flash_pkg.flash_check_content` and :vhdl:`flash_pkg.flash_check_content_fill`; there is no
  VUnit memory model view of it.

Read the messages of a flash
----------------------------

Errors a flash detects are check failures on its checker. Requests the model cannot carry out are
failures on its logger.

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
     - :py:class:`~awesome_vunit_vcs.flash.errors.ContentMismatch` in Python, reported as
       ``<id>: flash content mismatch at 0x<address>: expected 0x<value>, got 0x<value> (first of <n>
       bad bytes in [...])``, or ``expected fill 0x<value>`` for ``flash_check_content_fill``
   * - Version mismatch
     - Checker
     - ``The directive layout of the Python backend does not match flash_pkg``, at time 0: the VHDL and
       Python parts of the package come from different versions. Reinstall the package
   * - Request failure
     - Logger
     - ``<id>: <method> raised <exception>: <message>``, for example an invalid configuration, a range
       outside the device, a value that is not a byte, an unknown timing or stat name or an image that
       cannot be read. The exception is a
       :py:class:`~awesome_vunit_vcs.flash.errors.FlashValueError` for an invalid argument
   * - Duplicate id
     - Logger
     - ``Two verification components have the id <id> and would share one Python backend``, when a
       second flash with the same id is elaborated
   * - Unexpected message
     - Checker
     - ``Got unexpected message <type>`` with the ``fail`` policy

Related pages
-------------

* :doc:`qspi_flash`: *Count errors in a negative test*
* :doc:`qspi_protocol_checker`: *Switch rules and count violations*
* :doc:`../cookbook/flash_boot`: *Check the pin timing*

API reference
-------------

* VHDL: :vhdl:`qspi_protocol_checker_pkg.qspi_check_t`,
  :vhdl:`qspi_protocol_checker_pkg.set_check_enabled`, :vhdl:`flash_pkg.get_check_count`
* Python: :py:class:`~awesome_vunit_vcs.flash.errors.FlashError`
