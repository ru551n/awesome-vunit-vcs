awesome-vunit-vcs
=================

Third-party verification components for `VUnit <https://vunit.github.io/>`__. Ethernet is the first
component family: GMII first, followed by the XGMII family, MII, RGMII, RMII and an AXI-Stream MAC
client interface.

**VHDL handles simulation timing. Python handles Ethernet verification semantics.**

The VHDL components sample and drive the pins at the right simulation edges and exchange batched
observations with Python through the VUnit Python bridge. Frame reconstruction, protocol checks,
statistics, capture to Wireshark files and packet construction are simulator independent Python.

.. note::

   The project is in early development (alpha). The GMII monitor and source are complete and
   tested on GHDL and NVC; the other interfaces are on the :doc:`roadmap`. The APIs can still
   change, and the package is not released on PyPI yet.

.. toctree::
   :maxdepth: 2
   :caption: User guide

   installation
   vunit_integration
   gmii
   python_guide
   vhdl_api

.. toctree::
   :maxdepth: 2
   :caption: Reference

   explanation/architecture
   explanation/design_decisions
   explanation/performance
   explanation/limitations
   python_api
   roadmap
   contributing/index

.. toctree::
   :maxdepth: 2
   :caption: VHDL API reference

   reference/vhdl/index

.. toctree::
   :maxdepth: 1
   :caption: Project

   release_notes/index
