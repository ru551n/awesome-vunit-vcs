Flash in Python
===============

The flash VC is a thin VHDL frontend: it owns the pins and the simulation time, and a Python device
model decides what every byte on the bus means. The model is plain Python, so it is used in two ways.

* **Standalone**, without a simulator: test an image, a boot sequence or a driver's command order in
  ``pytest``.
* **Inside a simulation**, behind every ``flash`` entity. A testbench configures and inspects it with
  VHDL procedures and never has to write Python.

Everything a test needs is one import:

.. code-block:: python

   from awesome_vunit_vcs.flash import FlashConfig, FlashDevice

Addresses and lengths are in bytes, and times are integers in femtoseconds. Every invalid argument or
configuration raises :class:`~awesome_vunit_vcs.flash.errors.FlashValueError`, and a failed content
check raises :class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`. Both are a
:class:`~awesome_vunit_vcs.flash.errors.FlashError`.

.. contents:: On this page
   :local:
   :depth: 2

The device model
----------------

:class:`~awesome_vunit_vcs.flash.device.FlashDevice` is the device model behind a VHDL flash, built
from a :class:`~awesome_vunit_vcs.flash.config.FlashConfig` with the same parameters as
:vhdl:`flash_pkg.new_flash`. It answers the calls the component makes for the bytes on the wire with
packed directives, which :func:`~awesome_vunit_vcs.flash.directive.unpack` turns back into fields.
The example reads the JEDEC ID the way a QSPI master would:

.. literalinclude:: ../../examples/python/flash_jedec_id.py
   :language: python
   :start-at: from awesome_vunit_vcs.flash import

This file is ``examples/python/flash_jedec_id.py``, which the test suite runs.

Content without the bus
-----------------------

A test that only cares about the content uses the memory access methods, which the VHDL procedures
of the same names call:

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

In a simulation
---------------

Every ``flash`` creates one :class:`~awesome_vunit_vcs.flash.vunit_backend.FlashBackend` as the object
``vc`` in a Python session with the identity of the flash, so two flashes share nothing. The backend
wraps a :class:`~awesome_vunit_vcs.flash.device.FlashDevice` and never raises: an exception becomes a
report that the VHDL component logs on the logger or checker of the flash. :doc:`qspi_flash` lists
what is reported where.
