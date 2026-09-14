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

   The project is in early development (alpha). The Python Ethernet core is implemented and tested;
   the GMII components are being written and the APIs can change.

.. toctree::
   :maxdepth: 2
   :caption: User guide

   installation
   vunit_integration
   gmii
   vhdl_api

.. toctree::
   :maxdepth: 2
   :caption: Reference

   architecture
   python_api
   roadmap
