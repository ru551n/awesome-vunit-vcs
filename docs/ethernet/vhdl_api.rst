VHDL API
========

The reference of every VHDL package, context and entity of the Ethernet family, generated from the
doc comments of the sources when the documentation is built, so it always matches the code. The
user guide pages explain how the pieces fit together; this part is for looking things up.

A testbench only needs the context of a family, for example:

.. code-block:: vhdl

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

Declarations can be referenced from anywhere in the documentation with the ``vhdl`` role, for
example ``:vhdl:`ethernet_pkg.ethernet_check_t``` renders as :vhdl:`ethernet_pkg.ethernet_check_t`.
They are also listed in the :ref:`general index <genindex>`.

The packages, contexts and entities of the Ethernet family, grouped by interface. Testbenches use
``ethernet_context``; the shared packages hold what every interface has in common.

.. include:: /_generated/vhdl/ethernet.inc
