Installation
============

awesome-vunit-vcs is a Python package that VUnit loads as a VUnit package. Installing it installs the
VHDL sources and the Python backends together, and a project never refers to their installed location.

Requirements
------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Requirement
     - Notes
   * - CPython 3.10 to 3.14
     - A standard (GIL) build with a shared ``libpython``. Distribution Pythons, ``actions/setup-python``,
       ``uv`` and ``pyenv`` provide that by default.
   * - VUnit with package setup hooks
     - :vunit-pr:`1221`, not in a VUnit release yet.
   * - `vunit-python-bridge <https://github.com/ru551n/vunit-python-bridge>`__
     - The VUnit package that lets VHDL call Python. A dependency, installed with awesome-vunit-vcs.
   * - A C compiler and the Python development headers
     - Linux and macOS (for example ``gcc`` and ``python3-dev``): the bridge compiles its simulator
       library on first use. Windows gets prebuilt libraries for NVC and GHDL.
   * - A simulator
     - GHDL or NVC, both tested in CI. Questa/ModelSim, Riviera-PRO and Active-HDL are supported by the
       bridge but not tested with these components.

Install
-------

.. tab-set::

   .. tab-item:: From the repository

      Install the unreleased dependencies first. ``tests/packaging/unreleased-requirements.txt`` pins
      VUnit and vunit-python-bridge to tested commits.

      .. code-block:: bash

         git clone https://github.com/ru551n/awesome-vunit-vcs.git
         cd awesome-vunit-vcs
         pip install -r tests/packaging/unreleased-requirements.txt
         pip install .              # or: pip install -e ".[dev]" to develop the package

   .. tab-item:: From PyPI

      .. code-block:: bash

         pip install awesome-vunit-vcs

      .. note::

         Not released yet. Only pre-releases will be published until the dependencies are on PyPI.

Optional extras
---------------

.. list-table::
   :widths: 20 80

   * - ``scapy``
     - Packet construction and decoding with `Scapy <https://scapy.net/>`__. Raw frame monitoring,
       checking, statistics and capture do not need it.
   * - ``test``
     - The test suite of the repository, including Hypothesis for its property-based tests. The package
       itself never imports Hypothesis.
   * - ``dev``
     - Everything needed to develop the package: tests, linters, Scapy.

Check the installation
----------------------

.. code-block:: bash

   python -c "import awesome_vunit_vcs, vunit_python_bridge; print('ok')"
   VUNIT_SIMULATOR=nvc python examples/quickstart/run.py

The first simulation compiles the bridge library, which takes a few seconds; later runs reuse it. If
something fails, see :doc:`../troubleshooting`.
