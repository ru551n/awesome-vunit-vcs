VUnit integration
=================

awesome-vunit-vcs is a VUnit package. ``VUnit.add_package`` finds the installed Python package and
compiles the VHDL sources its ``vunit_pkg.toml`` lists into the library ``awesome_vunit_vcs``.

Run script
----------

.. code-block:: python

   from pathlib import Path

   from vunit import VUnit

   vu = VUnit.from_argv()
   vu.add_vhdl_builtins()
   vu.add_verification_components()
   vu.add_package("vunit-python-bridge")
   vu.add_package("awesome-vunit-vcs")

   lib = vu.add_library("lib")
   lib.add_source_files(Path(__file__).parent / "*.vhd")

   vu.main()

.. list-table::
   :widths: 40 60

   * - ``add_vhdl_builtins()``
     - First, as for any VUnit package.
   * - ``add_verification_components()``
     - Required: the Ethernet components implement VUnit's verification component interfaces.
   * - ``add_package("vunit-python-bridge")``
     - The Python bridge. There is no ``add_python()`` call.
   * - ``add_package("awesome-vunit-vcs")``
     - This package. The two ``add_package`` calls work in either order, and ``awesome_vunit_vcs`` works
       as a name as well.

Testbench
---------

One context clause makes the Ethernet components and VUnit visible:

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

It covers ``ieee.std_logic_1164``, VUnit's ``vunit_context`` and ``com_context``, ``sync_pkg``, the
stream VCI packages, ``vc_pkg`` and the Ethernet packages. A testbench that also calls Python directly
adds the bridge context:

.. code-block:: vhdl

   library python_bridge;
   context python_bridge.python_context;

Python environment
------------------

The simulator's embedded interpreter runs in the environment that started VUnit, including an active
virtual environment, and imports the Python backends from wherever pip installed the package. Your own
Python modules, for example packet functions, are imported the same way: install them, or put their
directory on ``sys.path`` (``PYTHONPATH``).

Output
------

Everything a component writes, such as captures, belongs in the test output path:

.. code-block:: vhdl

   start_capture(net, monitor, output_path(runner_cfg) & "rx.pcapng");
