VUnit integration
=================

awesome-vunit-vcs is a VUnit package: ``VUnit.add_package`` finds the installed Python package and
compiles its VHDL sources, as listed in its ``vunit_pkg.toml``, into the library
``awesome_vunit_vcs``. Neither the run script nor the testbenches know where it is installed.

Run script
----------

.. code-block:: python

   from pathlib import Path

   from vunit import VUnit


   def main():
       root = Path(__file__).parent

       vu = VUnit.from_argv()
       vu.add_vhdl_builtins()
       vu.add_verification_components()
       vu.add_package("vunit-python-bridge")
       vu.add_package("awesome-vunit-vcs")

       lib = vu.add_library("lib")
       lib.add_source_files(root / "*.vhd")

       vu.main()


   if __name__ == "__main__":
       main()

* ``add_vhdl_builtins`` comes first, as for any VUnit package.
* ``add_package("vunit-python-bridge")`` and ``add_package("awesome-vunit-vcs")`` can be called in
  either order. Package names are normalized, so ``awesome_vunit_vcs`` works as well.
* ``add_verification_components`` is needed when the testbench also uses VUnit's own verification
  components.
* There is no ``add_python()`` call: the Python bridge is the vunit-python-bridge package.

Testbenches
-----------

Testbenches use the Ethernet components through the ``awesome_vunit_vcs`` library and never need
to write Python. A testbench that also calls Python directly uses the context of the bridge:

.. code-block:: vhdl

   library vunit_lib;
   context vunit_lib.vunit_context;

   library python_bridge;
   context python_bridge.python_context;

   library awesome_vunit_vcs;

The Python backends of the components are imported by the simulator's embedded interpreter, which
runs in the same Python environment as VUnit, including an active virtual environment.

.. note::

   The component-level usage (instantiating a GMII monitor or source) is described on the
   :doc:`gmii` page once the GMII API is settled.
