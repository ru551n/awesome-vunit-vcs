VHDL API
========

.. contents:: Packages on this page
   :local:
   :depth: 1

Every VHDL package, context and entity of the Ethernet family. The pages of this section show how to
use them; come here to look up a parameter or a procedure.

A testbench only needs the family context:

.. code-block:: vhdl
   :caption: Testbench context clause

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.ethernet_context;

The declarations are grouped by interface, with the shared packages first. They are also listed in the
:ref:`general index <genindex>`.

.. include:: /_generated/vhdl/ethernet.inc
