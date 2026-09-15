VUnit integration
=================

Add awesome-vunit-vcs to a VUnit project with two ``add_package`` calls and one context clause.

.. include:: ../_includes/vunit_names.inc

Add the packages to your run script
-----------------------------------

.. code-block:: python
   :caption: run.py

   from pathlib import Path

   from vunit import VUnit

   vu = VUnit.from_argv()
   vu.add_vhdl_builtins()
   vu.add_verification_components()
   vu.add_package("vunit-python-bridge", allow_setup=True)
   vu.add_package("awesome-vunit-vcs")

   lib = vu.add_library("lib")
   lib.add_source_files(Path(__file__).parent / "*.vhd")

   vu.main()

.. list-table::
   :widths: 40 60

   * - ``add_vhdl_builtins()``
     - First, as for any VUnit package.
   * - ``add_verification_components()``
     - Required. The components build on VUnit's verification components.
   * - ``add_package("vunit-python-bridge", allow_setup=True)``
     - The Python bridge. ``allow_setup=True`` is required: adding the bridge runs its setup, which
       builds its simulator library. Don't call ``add_python()``.
   * - ``add_package("awesome-vunit-vcs")``
     - This package. The two ``add_package`` calls work in either order.

Use the components in a testbench
---------------------------------

.. code-block:: vhdl
   :caption: Testbench context clause

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

This one context clause gives you the Ethernet components and everything from VUnit a testbench
needs, including the Python bridge and property-based testing, so a testbench that calls Python or runs
properties needs nothing more. A flash testbench uses ``flash_context`` and a testbench with only
properties ``property_context`` in the same way.

Make your own Python code importable
------------------------------------

The simulation runs Python in the environment that started VUnit, including an active virtual
environment. How your own Python code is found depends on what it is:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Your code
     - What it needs
   * - A property strategy module
     - Nothing more: pass its directory as ``search_path`` to ``new_property``.
   * - Packet functions and sequence generators (``"module:function"``)
     - The module must be importable: install it, or put its directory on ``PYTHONPATH`` in
       ``run.py`` before VUnit starts the simulations.
   * - A subscriber file loaded with ``exec_file``
     - Nothing: it is loaded by its path. Modules it imports must be importable, as above.

Write output files to the test output path
------------------------------------------

.. code-block:: vhdl
   :caption: Capture into the test output path

   start_capture(net, monitor, output_path(runner_cfg) & "rx.pcapng");

Put files that components write, such as captures, in the test's output path. VUnit then keeps them
per test run.
