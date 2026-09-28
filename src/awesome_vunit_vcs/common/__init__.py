"""
Infrastructure shared by the verification component families.

* :mod:`.backend`: the base classes of the Python objects behind VHDL components
* :mod:`.events`: fan-out of events from one sampler to many consumers
* :mod:`.reports`: diagnostics queued in Python and logged by VHDL
* :mod:`.sparse_memory`: the sparse byte store of the flash array and the AXI4 memory
* :mod:`.vunit_bridge`: the only module that knows how VHDL encodes bulk
  observations for the VUnit Python bridge (VUnit PR #1220)
"""
