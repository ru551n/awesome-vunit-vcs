MDIO master
===========

The :vhdl:`mdio_master` component is a station management entity: it drives MDC and reads and writes
the registers of the PHYs on MDIO with Clause 22 frames.

.. include:: ../_includes/vunit_names.inc

Overview
--------

Use the master to test a design that is a PHY, or a bridge to one, and to drive an
:doc:`mdio_phy` in a test of your own device model. Reads and writes build a standard frame; any
other sequence of bits, such as a frame with a wrong TA, goes through
:vhdl:`mdio_master_pkg.transfer_mdio`. The master is VHDL only; it has no Python backend.

At a glance
-----------

.. list-table::
   :widths: 30 70

   * - Entity
     - :vhdl:`mdio_master`
   * - Frames
     - Clause 22 reads and writes, and any bits
   * - Clocking
     - MDC with ``mdc_period``, 400 ns (2.5 MHz) by default; MDC is low between frames
   * - Timing
     - MDIO changes when MDC falls and is sampled when MDC rises
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
     - out
     - ``std_ulogic``
     - MDC
   * - ``mdio``
     - inout
     - ``std_logic``
     - MDIO, driven in the bits the master sends and released ``'Z'`` otherwise

The :term:`handle` is the only generic: ``master : mdio_master_t``.

Constructor parameters
----------------------

:vhdl:`mdio_master_pkg.new_mdio_master` takes:

.. list-table::
   :header-rows: 1
   :widths: 25 20 15 40

   * - Parameter
     - Type
     - Default
     - Meaning
   * - ``mdc_period``
     - ``delay_length``
     - ``400 ns``
     - The period of MDC; the standard needs 400 ns or more
   * - ``preamble_bits``
     - ``natural``
     - ``32``
     - The preamble ones of the frames of ``read_mdio`` and ``write_mdio``
   * - ``id``, ``logger``, ``actor``, ``checker``, ``unexpected_msg_type_policy``
     -
     -
     - As for VUnit's own VCs; the default id is ``awesome_vunit_vcs:mdio_master:<n>``

Procedures
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Procedure
     - What it does
   * - :vhdl:`mdio_master_pkg.write_mdio`
     - Write a register of a PHY; returns at once
   * - :vhdl:`mdio_master_pkg.read_mdio`
     - Read a register of a PHY, blocking or with a reference and
       :vhdl:`mdio_master_pkg.await_read_mdio_reply`. An address no PHY answers reads as all ones.
   * - :vhdl:`mdio_master_pkg.transfer_mdio`
     - Send any bits, one per MDC period, and return what MDIO was at every rising MDC edge.
       :vhdl:`mdio_pkg.mdio_frame` builds a standard frame to change.
   * - :vhdl:`mdio_master_pkg.set_mdio_master_mdc_period`
     - A new MDC period for the frames from now on
   * - ``reset(net, master)``
     - Returns when the frames sent before it are over, with MDIO released and MDC low
   * - ``wait_until_idle``, ``wait_for_time``
     - The synchronization interface, through ``as_sync(master)``

Checks
------

The master checks nothing on the bus; the checks of a frame are in the :doc:`mdio_phy`.

.. note::

   A reset does not abort a frame in progress, and a frame of ``transfer_mdio`` is at most 4096 bits.
