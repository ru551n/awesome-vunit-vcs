Installation
============

awesome-vunit-vcs is a Python package that VUnit loads as an external package. Installing it
installs the VHDL sources and the Python backends together; a project never refers to their
installed location.

Requirements
------------

* CPython 3.10 or later, a standard (GIL) build with a shared ``libpython``. Distribution Pythons,
  ``actions/setup-python``, ``uv`` and ``pyenv`` provide that by default.
* `vunit-python-bridge <https://github.com/ru551n/vunit-python-bridge>`__, the VUnit package that
  lets VHDL call Python. It is a dependency of awesome-vunit-vcs and installed with it.
* VUnit with support for package setup hooks (`VUnit/vunit#1221
  <https://github.com/VUnit/vunit/pull/1221>`__).
* Linux and macOS: a C compiler and the Python development headers (for example ``python3-dev``).
  vunit-python-bridge compiles its simulator library on first use. On Windows it ships prebuilt
  libraries for NVC and GHDL.
* A simulator supported by vunit-python-bridge: NVC, GHDL, Questa/ModelSim or Riviera-PRO/Active-HDL.
  NVC and GHDL are the ones tested in continuous integration.

From PyPI
---------

.. code-block:: bash

   pip install awesome-vunit-vcs

.. note::

   Neither awesome-vunit-vcs nor vunit-python-bridge is released yet, and the VUnit support for
   package setup hooks is not part of a VUnit release. Until they are, install from the repository
   as described below.

From the repository
-------------------

Install the unreleased dependencies first. The file pins VUnit (the ``feature/package-setup-hooks``
branch of https://github.com/ru551n/vunit) and vunit-python-bridge to tested commits:

.. code-block:: bash

   git clone https://github.com/ru551n/awesome-vunit-vcs.git
   cd awesome-vunit-vcs
   pip install -r tests/packaging/unreleased-requirements.txt

Then install the package, editable when developing it:

.. code-block:: bash

   pip install -e ".[dev]"   # development: tests, linting, Scapy
   pip install .             # or a regular installation

Optional extras
---------------

``scapy``
   Packet construction and decoding with `Scapy <https://scapy.net/>`__. Raw frame monitoring,
   checking, statistics and capture do not need it.

``dev``
   Everything needed to run the test suite and linters.
