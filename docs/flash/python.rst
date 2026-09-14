Flash in Python
===============

Use the flash device model to test an image, a boot sequence or a driver's command order in
``pytest``, without a simulator. The same model runs behind every ``flash`` entity in a simulation,
where a testbench drives it with VHDL procedures and never has to write Python.

.. code-block:: python
   :caption: The one import you need

   from awesome_vunit_vcs.flash import FlashConfig, FlashDevice

Every example on this page is a file that the test suite runs.

.. list-table::
   :widths: 30 70

   * - Times
     - Integers in femtoseconds.
   * - Addresses and lengths
     - Bytes.
   * - Errors
     - Every invalid argument or configuration raises
       :class:`~awesome_vunit_vcs.flash.errors.FlashValueError`, and a failed content check raises
       :class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`. Both are a
       :class:`~awesome_vunit_vcs.flash.errors.FlashError`.

.. contents:: On this page
   :local:
   :depth: 1

Talk to the device model
------------------------

.. literalinclude:: ../../examples/python/flash_jedec_id.py
   :caption: examples/python/flash_jedec_id.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

:class:`~awesome_vunit_vcs.flash.device.FlashDevice` is the device model behind a VHDL flash. Build it
from a :class:`~awesome_vunit_vcs.flash.config.FlashConfig`, which has the same parameters as
:vhdl:`flash_pkg.new_flash`.

The model answers the calls the component makes for the bytes on the wire with packed directives.
:func:`~awesome_vunit_vcs.flash.directive.unpack` turns them back into fields. The example reads the
:term:`JEDEC` ID the way a QSPI master would.

Seed and check content without the bus
---------------------------------------

A test that only cares about the content uses the memory access methods. The VHDL procedures of the
same names call them.

* :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.preload`,
  :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.preload_fill` and
  :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.load_image` seed content. An image is Intel HEX,
  Motorola S-record, JSON or a raw binary, see :func:`~awesome_vunit_vcs.flash.images.format_for`.
* :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.read_back`,
  :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.check_content` and
  :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.check_content_fill` read and check it.
* :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.written_regions` lists what programs and erases
  touched, and :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.get_stat` returns the counters of
  :ref:`flash-statistics`.

Use the model inside a simulation
---------------------------------

Every ``flash`` creates one :class:`~awesome_vunit_vcs.flash.vunit_backend.FlashBackend` as the
:term:`backend` object ``vc``. It lives in a Python :term:`session` with the identity of the flash, so
two flashes share nothing.

The backend wraps a :class:`~awesome_vunit_vcs.flash.device.FlashDevice` and never raises: an exception
becomes a report that the VHDL component logs on the logger or checker of the flash.
:doc:`qspi_flash` lists what is reported where.

Related recipes
---------------

* :doc:`../cookbook/flash`: *Preload a flash image and boot from it*, *Check what the DUT wrote to the
  flash*

API reference
-------------

:doc:`python_api`
