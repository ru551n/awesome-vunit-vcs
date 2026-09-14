VHDL API
========

The reference of every VHDL package, context and entity of the flash family, generated from the doc
comments of the sources when the documentation is built, so it always matches the code. The pages of
the components explain how the pieces fit together; this part is for looking things up.

A testbench only needs the context of the family:

.. code-block:: vhdl
   :caption: Testbench context clause

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.flash_context;

Declarations can be referenced from anywhere in the documentation with the ``vhdl`` role, for
example ``:vhdl:`flash_pkg.new_flash``` renders as :vhdl:`flash_pkg.new_flash`. They are also listed
in the :ref:`general index <genindex>`.

.. include:: /_generated/vhdl/flash.flash.inc

.. include:: /_generated/vhdl/flash.qspi.inc
