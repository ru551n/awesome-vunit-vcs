RMII
====

RMII carries 10 and 100 Mbit/s Ethernet on two data pins and a 50 MHz reference clock.

When to use it
--------------

Use the RMII components when your design has an RMII port, for example a MAC connected to a 10/100
PHY with few pins.

.. list-table::
   :widths: 30 70

   * - Entities
     - :vhdl:`rmii_source`, :vhdl:`rmii_monitor`, :vhdl:`rmii_protocol_checker`
   * - Link rates
     - ``link_rate_mbps => 100`` (default) or ``10``
   * - Clocking
     - Rising edge of ``ref_clk``, 50 MHz at both rates
   * - Python interface
     - ``awesome_vunit_vcs.ethernet.RMII``
   * - Tested on
     - GHDL, NVC, at both rates

How to use it
-------------

Connect the pins
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Port
     - Source
     - Monitor, protocol checker
     - RMII signal
   * - ``ref_clk``
     - ``in std_ulogic``
     - ``in std_ulogic``
     - ``REF_CLK``
   * - ``data``
     - ``out std_ulogic_vector(1 downto 0)``
     - ``in std_ulogic_vector(1 downto 0)``
     - ``TXD`` / ``RXD``
   * - ``dv``
     - ``out std_ulogic``
     - ``in std_ulogic``
     - ``TX_EN`` / ``CRS_DV``
   * - ``er``
     - ``out std_ulogic``
     - ``in std_ulogic := '0'``
     - ``RX_ER``

Create the components
~~~~~~~~~~~~~~~~~~~~~

.. literalinclude:: ../../examples/cookbook/tb_cookbook_interfaces.vhd
   :caption: examples/cookbook/tb_cookbook_interfaces.vhd
   :language: vhdl
   :start-after: -- docs-start: rmii
   :end-before: -- docs-end: rmii
   :dedent:

Test the receive side of a MAC
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A PHY may still deliver data after the carrier ends, and then toggles ``CRS_DV``. Set
``crs_dv_toggle_octets`` on a source to send frames that way and check that your MAC receives them
unchanged.

.. code-block:: vhdl
   :caption: A source whose CRS_DV toggles during the last three octets of every frame

   constant phy : rmii_source_t := new_rmii_source(crs_dv_toggle_octets => 3);

Send and receive frames
~~~~~~~~~~~~~~~~~~~~~~~

Everything else works as on :doc:`gmii`: the same procedures push, check and count frames.

Common options
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Option
     - Meaning
   * - ``link_rate_mbps``
     - 10 or 100; any other rate is a failure. Give the source and the monitors the same rate.
   * - ``crs_dv_toggle_octets``
     - Sources only: toggle ``dv`` during the last this many octets of every frame, like a PHY whose
       carrier ends before its data. 0 (default) keeps ``dv`` high for the whole frame.

The other parameters are those of :doc:`gmii`.

Good to know
------------

* Octets are sent two bits at a time, least significant bits first.
* At 10 Mbit/s every dibit lasts 10 clock cycles; the clock stays at 50 MHz.
* A monitor keeps receiving while ``CRS_DV`` toggles. Two samples with ``CRS_DV`` low end the frame.
* ``00`` dibits a PHY presents after asserting ``CRS_DV`` and before the preamble are ignored.
* A frame that ends with an incomplete octet is reported as ``ETH_TERMINATION``, and its FCS fails too.

Related recipes
---------------

* :doc:`../cookbook/interfaces`: *Use RMII at 10 or 100 Mbit/s*, *Run one testbench at several rates*

API reference
-------------

* VHDL: :vhdl:`rmii_pkg.new_rmii_source`, :vhdl:`rmii_pkg.new_rmii_monitor`,
  :vhdl:`rmii_pkg.new_rmii_protocol_checker`, and the whole family in :doc:`vhdl_api`
* Python: :doc:`python_api`
