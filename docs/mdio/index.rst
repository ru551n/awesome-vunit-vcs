MDIO
====

The MDIO family verifies the management interface of Ethernet PHYs: the Clause 22 frames of MDC and
MDIO, with which a station management entity (a MAC or a CPU) reads and writes the 32 registers of
each PHY on the bus. It has two verification components (:term:`VCs <VC>`) that share one bus.

.. include:: ../_includes/vunit_names.inc

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - VC
     - Role
   * - :vhdl:`mdio_phy`
     - A PHY at one address with a register file or a device model in Python. It checks the frames
       sent to it and answers reads with a clock-to-output delay you choose. Use it to test a
       management design.
   * - :vhdl:`mdio_master`
     - A master that drives MDC and sends reads, writes and any bits you give it, for malformed
       frames. Use it to test a PHY-side design, or to drive a PHY VC in a unit test.

The VHDL components drive and sample MDC and MDIO. What the frames mean, from the checks to the
register values, is decided by the Python package ``awesome_vunit_vcs.mdio``, which also works in plain
``pytest``.

.. toctree::
   :maxdepth: 1
   :hidden:

   mdio_phy
   mdio_master
   vhdl_api
   python_api

What's here
-----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`mdio_phy`, :doc:`mdio_master`
     - One page per VC: pins, constructors, procedures and checks
   * - :doc:`vhdl_api`
     - Every VHDL package, context and entity of the family
   * - :doc:`python_api`
     - Every public Python name of ``awesome_vunit_vcs.mdio``

The pattern
-----------

A testbench needs one context clause:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

``mdio_context`` makes ``mdio_pkg``, ``mdio_phy_pkg`` and ``mdio_master_pkg`` visible, together with
``ieee.std_logic_1164``, ``vunit_context``, ``com_context``, ``sync_pkg``, ``vc_pkg`` and the typed
Python arguments of ``vc_python_pkg``.

Each VC is created with a handle in the architecture. Here a master, a PHY with a plain register file
and a PHY modelled in Python that answers at the slowest clock-to-output delay the standard allows:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

MDIO is a tri-state line with a pull-up. Declare it as ``std_logic``, pull it up with ``'H'``, and
connect every VC and your design to MDC and MDIO:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: bus
   :end-before: -- docs-end: bus
   :dedent:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: instances
   :end-before: -- docs-end: instances
   :dedent:

A design with separate output, output enable and input ports, as FPGA I/O buffers have them, connects
through ``mdio <= mdio_o when mdio_t = '0' else 'Z';`` and ``mdio_i <= to_x01(mdio);``.

The run script adds the Python bridge and this package. The device models in ``python/`` are found
through ``PYTHONPATH``:

.. literalinclude:: ../../examples/mdio/run.py
   :caption: examples/mdio/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

Checks
------

The PHY checks every frame it samples and reports a violation as a check failure on its checker, with
a message starting with the check ID. :vhdl:`mdio_phy_pkg.get_mdio_phy_check_count` returns the
violations of one check.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Check
     - Violation
   * - ``mdio_preamble``
     - Fewer preamble ones before ST than ``preamble_bits`` of the PHY. The frame is ignored.
   * - ``mdio_op``
     - An OP of 00 or 11 in a Clause 22 frame to the PHY. The frame is ignored.
   * - ``mdio_ta``
     - A write whose TA is not 10, which is not made, or a read whose first TA bit the master drove
       instead of releasing it.
   * - ``mdio_contention``
     - MDIO differed from the value the PHY drove, in the second TA bit or the data of a read: the
       master drove it too.
   * - ``mdio_metavalue``
     - A metavalue on MDIO from ST to REGAD of any frame, or in the TA and data of a write to the PHY.
   * - ``mdio_register``
     - A register differs from the value given to :vhdl:`mdio_phy_pkg.check_mdio_phy_register`.

A frame to another address, and a Clause 45 frame (ST 00), is ignored without a check.

.. note::

   The PHY checks frames, not pin timing: the MDC period, and the setup and hold times of MDIO around
   the rising MDC edge, are not checked yet, and Clause 45 frames are ignored rather than answered.
