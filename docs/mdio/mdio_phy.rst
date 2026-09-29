MDIO PHY
========

The :vhdl:`mdio_phy` component is the management interface of an Ethernet PHY: it answers Clause 22
frames at its address from a register file, or from a device model written in Python.

.. include:: ../_includes/vunit_names.inc

Overview
--------

Use the PHY to test a management design, such as an MDIO master block or firmware that brings a link
up. The component samples MDIO on rising MDC edges and drives the TA and data of a read; its Python
backend checks the frames and holds the registers. It calls Python twice per frame, never per clock
edge.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`mdio_phy`
   * - Frames
     - Clause 22 reads and writes; Clause 45 frames are ignored
   * - Clocking
     - Any MDC the master drives; the PHY samples on rising edges
   * - Clock-to-output delay
     - 0 ns to 300 ns after a rising MDC edge, set in the constructor or while running
   * - Device models
     - ``"registers"`` or ``"package.module:Class"``
   * - Tested on
     - GHDL, NVC

Pins
----

.. list-table::
   :header-rows: 1
   :widths: 15 15 25 45

   * - Port
     - Direction
     - Type
     - Signal
   * - ``mdc``
     - in
     - ``std_ulogic``
     - MDC, driven by the master
   * - ``mdio``
     - inout
     - ``std_logic``
     - MDIO, released ``'Z'`` except in the TA and data of a read

The :term:`handle` is the only generic: ``phy : mdio_phy_t``.

Constructor parameters
----------------------

:vhdl:`mdio_phy_pkg.new_mdio_phy` takes:

.. list-table::
   :header-rows: 1
   :widths: 25 20 15 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``phy_address``
     - ``natural``
     -
     - The address the PHY answers, 0 to 31
   * - ``clock_to_output_delay``
     - ``delay_length``
     - ``0 ns``
     - How long after a rising MDC edge the PHY changes MDIO in a read, up to
       ``mdio_max_clock_to_output_delay`` (300 ns)
   * - ``preamble_bits``
     - ``natural``
     - ``32``
     - The preamble ones the PHY needs before ST, 0 to accept a suppressed preamble
   * - ``model``
     - ``string``
     - ``"registers"``
     - The device model: ``"registers"``, 32 registers of 16 bits, or ``"package.module:Class"``
   * - ``model_args``
     - ``arg_t``
     - ``null_arg``
     - The arguments of the model, built with ``kwarg`` and ``kwarg_time``
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - As for VUnit's own VCs; the default id is ``awesome_vunit_vcs:mdio_phy:<n>``

Procedures
----------

The registers can be set, read and checked without the bus, which keeps a test short and its checks
independent of the design:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: read-write
   :end-before: -- docs-end: read-write
   :dedent:

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`mdio_phy_pkg.set_mdio_phy_register`
     - Set a register, without the side effects of the model
   * - :vhdl:`mdio_phy_pkg.get_mdio_phy_register`
     - Read a register, blocking or with a reference and
       :vhdl:`mdio_phy_pkg.await_get_mdio_phy_register_reply`
   * - :vhdl:`mdio_phy_pkg.check_mdio_phy_register`
     - Compare a register with the expected value; a difference is an ``MDIO_REGISTER`` failure
   * - :vhdl:`mdio_phy_pkg.get_mdio_phy_access_count`
     - The reads and writes the PHY answered, of one operation or register if given
   * - :vhdl:`mdio_phy_pkg.get_mdio_phy_check_count`
     - The violations of one check
   * - :vhdl:`mdio_phy_pkg.set_mdio_phy_clock_to_output_delay`
     - A new clock-to-output delay for the reads from now on
   * - ``reset(net, phy)``
     - Release MDIO and forget a frame in progress; the registers are kept
   * - ``wait_until_idle``, ``wait_for_time``
     - The synchronization interface, through ``as_sync(phy)``

Timing of a read
----------------

The master releases MDIO in the first TA bit. After the rising MDC edge of that bit, the PHY drives the
second TA bit, 0, and then one data bit per MDC period, each ``clock_to_output_delay`` after a rising
edge, and releases MDIO the same delay after the edge of the last data bit. A master design must
sample a bit no earlier than the delay after the edge the PHY drove it on: with 300 ns, an MDC of
2.5 MHz leaves 100 ns before the next rising edge. A master that samples earlier reads every bit one
period late, which a test with ``clock_to_output_delay => mdio_max_clock_to_output_delay`` shows.

Device models
-------------

A device model is a subclass of ``MdioDevice`` in a Python module that the simulation finds through
``PYTHONPATH``. It overrides ``read`` and ``write``, which the PHY calls once per frame with the time
in fs. This one brings the link up at a given time and clears its reset bit:

.. literalinclude:: ../../examples/mdio/python/link_phy.py
   :caption: examples/mdio/python/link_phy.py
   :language: python
   :start-after: # docs-start: link-phy
   :end-before: # docs-end: link-phy

``decode_time_fs`` turns the time that ``kwarg_time`` sends into fs. The testbench names the class and
gives its arguments in the constructor (see the handles above), and reads the registers over MDIO:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: link-up
   :end-before: -- docs-end: link-up
   :dedent:

Checks
------

The checks are listed in :doc:`index`. A malformed frame from :vhdl:`mdio_master_pkg.transfer_mdio`
shows one; ``disable_stop`` lets the test count the failure instead of stopping:

.. literalinclude:: ../../examples/mdio/tb_mdio_examples.vhd
   :caption: examples/mdio/tb_mdio_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: malformed
   :end-before: -- docs-end: malformed
   :dedent:

Python backend
--------------

The backend is ``awesome_vunit_vcs.mdio.vunit_backend.MdioPhyBackend``, with the protocol engine
``MdioPhy``, whose ``accesses`` list every frame the PHY answered. There is no sample word: the
component hands Python the header bits after REGAD and the TA and data bits at the end of a frame.

.. note::

   The PHY answers one address and does not check pin timing. The contention check compares MDIO with
   the value the PHY drives, so a master that drives MDIO to the same value is not caught.
