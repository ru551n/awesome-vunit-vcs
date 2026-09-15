VHDL API
========

The same declarations are available as JSON in `api/vhdl.json <../api/vhdl.json>`__.

.. contents:: Packages on this page
   :local:
   :depth: 1

``property_pkg`` runs Hypothesis properties from a VHDL testbench. One context clause makes it visible:
``property_context`` in a testbench that only runs properties, or the family context you already use,
``ethernet_context`` or ``flash_context``, which include it.

.. code-block:: vhdl
   :caption: The context clause of a property testbench

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.property_context;

:doc:`index` and :doc:`strategies` show how to use it.

.. include:: /_generated/vhdl/common.property.inc
