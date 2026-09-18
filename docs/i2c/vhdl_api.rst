VHDL API
========

The same declarations are available as JSON in `api/vhdl.json <../api/vhdl.json>`__.

.. contents:: Packages on this page
   :local:
   :depth: 1

The reference of every VHDL package, context and entity of the I2C family, generated from the doc
comments of the sources when the documentation is built, so it always matches the code. The pages of
the components explain how the pieces fit together; this part is for looking things up.

A testbench only needs the context of the family:

.. code-block:: vhdl
   :caption: Testbench context clause

   library awesome_vunit_vcs;
   context awesome_vunit_vcs.i2c_context;

Declarations can be referenced from anywhere in the documentation with the ``vhdl`` role, for
example ``:vhdl:`i2c_master_pkg.new_i2c_master``` renders as :vhdl:`i2c_master_pkg.new_i2c_master`.
They are also listed in the :ref:`general index <genindex>`.

.. include:: /_generated/vhdl/i2c.i2c.inc
