"""
awesome-vunit-vcs: third-party verification components for VUnit.

Add the HDL side to a VUnit project with::

    vu.add_vhdl_builtins()
    vu.add_verification_components()
    vu.add_package("vunit-python-bridge")
    vu.add_package("awesome-vunit-vcs")

The VHDL components call Python through the ``python_bridge`` library of the
``vunit-python-bridge`` package, so a run script adds that package too.

VHDL owns simulation semantics and pin timing; the Python subpackages
(:mod:`awesome_vunit_vcs.ethernet`, ...) own verification semantics and are
simulator independent.
"""

from .errors import AwesomeVunitVcsError

__all__ = ["VHDL_LIBRARY_NAME", "VUNIT_PACKAGE_NAME", "AwesomeVunitVcsError", "__version__"]

__version__ = "0.1.0.dev0"

#: Name to pass to ``VUnit.add_package``
VUNIT_PACKAGE_NAME = "awesome-vunit-vcs"

#: VHDL library the package compiles into
VHDL_LIBRARY_NAME = "awesome_vunit_vcs"
