"""
awesome-vunit-vcs: third-party verification components for VUnit.

Add the HDL side to a VUnit project with::

    vu.add_vhdl_builtins()
    vu.add_verification_components()
    vu.add_python()
    vu.add_package("awesome-vunit-vcs")

VHDL owns simulation semantics and pin timing; the Python subpackages
(:mod:`awesome_vunit_vcs.ethernet`, ...) own verification semantics and are
simulator independent.
"""

__version__ = "0.1.0.dev0"

#: Name to pass to ``VUnit.add_package``
VUNIT_PACKAGE_NAME = "awesome-vunit-vcs"

#: VHDL library the package compiles into
VHDL_LIBRARY_NAME = "awesome_vunit_vcs"
