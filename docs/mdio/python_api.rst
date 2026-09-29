Python API
==========

The same API is available as JSON in `api/python.json <../api/python.json>`__.

The public Python API of the MDIO family. :doc:`mdio_phy` shows how the pieces fit together. Times are
integers in femtoseconds (``_fs``).

Everything a test normally needs is importable from one module::

    from awesome_vunit_vcs import mdio

The package exports ``NUM_REGISTERS``, ``MdioAccess``, ``MdioCheckId``, ``MdioDevice``, ``MdioError``,
``MdioOperation``, ``MdioPhy``, ``MdioValueError`` and ``MdioViolation``, documented in the modules
that define them below.

.. automodule:: awesome_vunit_vcs.mdio
   :no-members:

Device models
-------------

.. automodule:: awesome_vunit_vcs.mdio.devices
   :members: MdioDevice, NUM_REGISTERS, check_register_address, check_value

PHY
---

.. automodule:: awesome_vunit_vcs.mdio.phy
   :members: MdioPhy, MdioCheckId, MdioOperation, MdioAccess, MdioViolation, Response, Action

Exceptions
----------

Every invalid argument raises :class:`~awesome_vunit_vcs.mdio.errors.MdioValueError`, a
``ValueError`` and an :class:`~awesome_vunit_vcs.mdio.errors.MdioError`, which derives from
:class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`.

.. automodule:: awesome_vunit_vcs.mdio.errors
   :members: MdioError, MdioValueError

Simulation backend
------------------

The Python object behind the VHDL PHY, ``vc`` in its Python session.

.. automodule:: awesome_vunit_vcs.mdio.vunit_backend
   :members: MdioPhyBackend
