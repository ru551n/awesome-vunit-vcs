Property-based testing
======================

A property is a statement that must hold for every input. Instead of writing the inputs, you
describe them with a `Hypothesis <https://hypothesis.readthedocs.io>`_ strategy, a plain Python
function, and :doc:`property_pkg <vhdl_api>` runs the design with the examples Hypothesis draws, all inside one
simulation. When an example fails, Hypothesis shrinks it to a minimal counterexample by running more
examples through the same loop.

The package does not depend on Hypothesis; install it where the simulation runs:

.. code-block:: bash
   :caption: Terminal

   pip install hypothesis

The examples are in ``examples/property``; run them with ``python examples/property/run.py``. The
strategies are the functions of ``examples/property/python/strategies.py``, and most examples are
test cases of ``tb_property_examples.vhd``, which shares an ALU and a register bank between them.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`strategies`
     - Stateful properties, Ethernet frames, lockups, scores, metamorphic, timing and swarm testing
   * - :doc:`records`
     - Sharing records between Python and VHDL, generated from dataclasses
   * - :doc:`reproducing`
     - Pinned examples, budgets, seeds, journals and replay
   * - :doc:`vhdl_api`
     - ``property_pkg``
   * - :doc:`python_api`
     - The property runner, records and the VHDL generator

Write a first property
----------------------

The strategy returns a Hypothesis strategy:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: scalar

The testbench loops over the examples: read the example, simulate, report the verdict, and check the
property when the loop ends. The snippets on this page use testbench helpers from the cookbook: :ref:`apply <property-helper-apply>`, :ref:`item <property-helper-item>` and :ref:`new_example <property-helper-new-example>`.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: scalar
   :end-before: -- docs-end: scalar
   :dedent: 8

``new_property`` names the strategy as ``"module:function"`` and ``search_path`` makes the module
importable. ``seed => get_seed(runner_cfg)`` makes the examples follow VUnit's seed, and
``output_path => output_path(runner_cfg)`` journals and replays them (see :doc:`reproducing`).

The testbench needs one context clause, ``context awesome_vunit_vcs.property_context;``. The Ethernet
and flash contexts include it, so a testbench with those needs nothing more.

.. include:: ../_includes/vunit_names.inc

Read composite examples
-----------------------

An example can be any combination of dicts, dataclasses, named tuples, lists, tuples, binary data,
integers, booleans and strings. VHDL reads a value through a path: field names joined by dots and
indexes in parentheses, as in ``"frames(2).payload"``. The empty path is the whole example.

.. list-table::
   :header-rows: 1

   * - Getter
     - Returns
   * - :vhdl:`get_integer(prop, path) <property_pkg.get_integer>`
     - an integer
   * - :vhdl:`get_boolean(prop, path) <property_pkg.get_boolean>`
     - a boolean
   * - :vhdl:`get_string(prop, path) <property_pkg.get_string>`
     - a string, or the lower-case name of an ``Enum`` member
   * - :vhdl:`get_integer_vector(prop, path) <property_pkg.get_integer_vector>`
     - the items of a list, tuple or binary value, in one bridge call
   * - :vhdl:`get_unsigned(prop, path, length) <property_pkg.get_unsigned>`
     - an unsigned integer, or a binary value read big-endian, as ``length`` bits
   * - :vhdl:`get_length(prop, path) <property_pkg.get_length>`
     - the number of items of a list, tuple or binary value
   * - :vhdl:`has_field(prop, path) <property_pkg.has_field>`
     - whether an optional field exists and is not None

A wrong path fails with a message that names the fields that exist, for example
``'confg.lanes': the example has no field 'confg'; its fields are config, frames, vlan``.

A record with a list:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: composite

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: composite
   :end-before: -- docs-end: composite
   :dedent: 8

A tagged union, where each kind of example has fields of its own:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: tagged_union

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: tagged_union
   :end-before: -- docs-end: tagged_union
   :dedent: 8

Related recipes
---------------

* :doc:`../cookbook/property_testing`: *Write the first property*, *Read composite examples*

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`

.. toctree::
   :hidden:

   strategies
   records
   reproducing
   vhdl_api
   python_api
