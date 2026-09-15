Python API
==========

The same API is available as JSON in `api/python.json <../api/python.json>`__.

The public Python API of the flash family, grouped by topic. :doc:`python` shows how the pieces fit
together.

Everything a test normally needs is importable from one module::

    from awesome_vunit_vcs import flash

Addresses and lengths are in bytes and times are integers in femtoseconds (``_fs``).

Device model
------------

The package exports ``AddrModes``, ``FlashConfig``, ``FlashDevice``, ``LAYOUT_VERSION``, ``FlashError``,
``FlashValueError`` and ``ContentMismatch``, documented in the modules that define them below.

.. automodule:: awesome_vunit_vcs.flash
   :no-members:

.. automodule:: awesome_vunit_vcs.flash.device
   :members: FlashDevice, Phase, WRSR_MASK, SR2_QE, SR2_CMP, SR3_ADS

Exceptions
~~~~~~~~~~

Every invalid argument or configuration raises
:class:`~awesome_vunit_vcs.flash.errors.FlashValueError`, including an unknown busy-time or statistic
name and a call out of protocol order, such as ``xfer`` before ``cs_assert``. A content check that
fails raises :class:`~awesome_vunit_vcs.flash.errors.ContentMismatch`. Both derive from
:class:`~awesome_vunit_vcs.flash.errors.FlashError`, which derives from
:class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`, and ``FlashValueError`` is also a
``ValueError``.

.. automodule:: awesome_vunit_vcs.flash.errors
   :members: FlashError, FlashValueError, ContentMismatch

Configuration
~~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.flash.config
   :members: FlashConfig, AddrModes, BUSY_KEYS, DEFAULT_BUSY_FS, KIB, MIB

Memory array
~~~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.flash.array
   :members: FlashArray, ERASED_BYTE

Commands
~~~~~~~~

.. automodule:: awesome_vunit_vcs.flash.commands
   :members: Command, Op, Direction, AddrLen, EraseUnit, ERASE_CHIP, COMMAND_TABLE, COMMANDS, supported, lookup,
             commands_for, erase_opcode_for

Directive
~~~~~~~~~

.. automodule:: awesome_vunit_vcs.flash.directive
   :members: LAYOUT_VERSION, Action, Directive, pack, unpack, ignore_rest, FLAG_VOLATILE, VALID_LANES,
             PACKED_MAX

Timing
~~~~~~

.. automodule:: awesome_vunit_vcs.flash.timing
   :members: Timing

Protection
~~~~~~~~~~

.. automodule:: awesome_vunit_vcs.flash.protection
   :members: Protection, SEC_UNIT_BYTES, BLOCK_UNIT_BYTES

Mode
~~~~

.. automodule:: awesome_vunit_vcs.flash.mode
   :members: ProtocolMode, is_continuous, MODE_BYTE_CONTINUOUS, MODE_BYTE_SHIFT, MODE_BYTE_MASK

SFDP
~~~~

.. automodule:: awesome_vunit_vcs.flash.sfdp
   :members: build, read, basic_parameter_table, SFDP_SIGNATURE, SFDP_MAJOR, SFDP_MINOR,
             PARAM_HEADER_OFFSET, PARAM_TABLE_OFFSET, BASIC_TABLE_DWORDS

Images
~~~~~~

.. automodule:: awesome_vunit_vcs.flash.images
   :members: load, format_for, Segment, FORMATS

Simulation backend
------------------

The Python object behind the VHDL flash, ``vc`` in the Python session of each flash.

.. automodule:: awesome_vunit_vcs.flash.vunit_backend
   :members: FlashBackend
