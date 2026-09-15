Property-based testing in your testbench
========================================

When we pick test data by hand, we test the cases we thought of. Bugs tend to live in the ones we
didn't. Property-based testing turns this around: we state a rule that must hold for every input, and
Hypothesis generates the inputs. When one fails, Hypothesis shrinks it to the smallest example that
still fails.

In this article we start with the smallest property that passes and build up to structured data and
Ethernet frames. Sequences of operations on a design with state come last, under *Going further*.

Every property has two halves in two files:

.. list-table::
   :header-rows: 1
   :widths: 40 15 45

   * - File
     - Language
     - What it holds
   * - ``examples/property/python/strategies.py``
     - Python
     - The strategies: functions that say what data Hypothesis generates.
   * - ``examples/property/tb_property_examples.vhd``
     - VHDL
     - The testbench: a loop that runs each example through the design and reports the result.
   * - ``examples/property/run.py``
     - Python
     - The run script.

You need Hypothesis installed (``pip install hypothesis``) to run properties. Your VHDL never imports
anything from it.

Step 1: the testbench setup (VHDL)
----------------------------------

A property testbench uses the property package:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: libraries
   :end-before: -- docs-end: libraries

The example testbench also defines a few helpers in its main process. ``new_example`` creates a
property from a strategy name, with VUnit's seed so a run can be repeated. ``apply`` and ``pulse`` drive
the designs under test, an arithmetic unit (ALU) and a register bank:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: helpers
   :end-before: -- docs-end: helpers
   :dedent:

``search_path`` tells the simulator where your strategies live: the ``python`` directory next to the
testbench.

Step 2: write the first property
--------------------------------

**In Python**, the strategy for our first property is just a byte:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: scalar

**In VHDL**, the rule: a value subtracted from itself gives zero.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: scalar
   :end-before: -- docs-end: scalar
   :dedent:

The loop is the whole pattern:

#. ``next_example`` asks Hypothesis for the next example, and returns false when there are no more.
#. ``get_integer`` reads the example.
#. ``report_example`` tells Hypothesis whether the rule held.

After the loop, ``check_property(prop)`` fails the test if any example failed and logs the smallest
failing one. Run it like any other VUnit test:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/property/run.py "*test_scalar"
   pass lib.tb_property_examples.test_scalar (0.3 s)
   pass 1 of 1
   All passed!

Keep examples independent. If your design has state, reset it at the start of each example.

Step 3: read structured examples
--------------------------------

Real test data has structure: an offset plus a list of values, for example. **In Python**, a strategy
can return dictionaries and lists:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: composite

**In VHDL**, reach the parts with a path, and use ``get_length`` for a list:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: composite
   :end-before: -- docs-end: composite
   :dedent:

``item`` is a small helper in the testbench that builds ``"(2)"`` from an index, so the path reads
``"values(2)"``. Paths can go deeper, such as ``"frames(2).payload"``, and ``has_field`` checks
whether an optional part is there.

Step 4: send generated frames through the Ethernet components
-------------------------------------------------------------

Properties and the Ethernet components fit together. **In Python**, generate frame data:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: frame_data

**In VHDL**, each example goes through a :term:`source` and comes back from a :term:`monitor`, and the
property is that it comes back unchanged:

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: ethernet
   :end-before: -- docs-end: ethernet
   :dedent:

This testbench calls ``new_property`` directly: ``"strategies:frame_data"`` names the module and the
function.

Step 5: handle different kinds of examples
------------------------------------------

Some tests mix kinds of operations, each with fields of its own. **In Python**, join the kinds with
``|``:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: tagged_union

**In VHDL**, look at the ``kind`` field and read the fields that kind has:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: tagged_union
   :end-before: -- docs-end: tagged_union
   :dedent:

Step 6: use a record generated from a Python dataclass
------------------------------------------------------

Reading field after field gets repetitive when many tests use the same data. Instead, describe the data
once. **In Python**, write a dataclass with bounds on its fields:

.. literalinclude:: ../../examples/property/python/example_records.py
   :caption: examples/property/python/example_records.py
   :language: python
   :pyobject: Pair

**In the run script (Python)**, generate a VHDL package with a matching record and a getter:

.. literalinclude:: ../../examples/property/run.py
   :caption: examples/property/run.py
   :language: python
   :start-after: # docs-start: generate
   :end-before: # docs-end: generate

**In VHDL**, use the generated package (``use work.example_records_pkg.all``, as in step 1). One call
gives the whole record, and ``to_string`` makes failure messages readable:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: generated_record
   :end-before: -- docs-end: generated_record
   :dedent:

The package is regenerated on every run, so it always matches the dataclass. The strategy comes from
the same dataclass: ``strategy_for(Pair)``.

Going further: test a sequence of operations
--------------------------------------------

Designs with state, such as register banks and FIFOs, fail on *sequences* of operations. Hypothesis can
generate those too. This is the most advanced kind of property, so make sure the steps above are
familiar first.

**In Python**, write a small model of the design as a state machine whose rules are the operations:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: Registers

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: registers

Each rule calls ``step`` to have the testbench perform the operation and return the result, and
compares that with the model.

**In VHDL**, perform whatever step you are given. ``get_rule`` names the operation, and ``report_step``
returns the result to the model:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent:

Every sequence begins with the ``"start"`` rule, where the testbench resets the design. The register
bank in this example has a planted bug: it loses writes to address 5. Hypothesis finds it and shrinks
the failure to two steps, ``write(address=5, data=1); read(address=5)``. The example checks that
counterexample with ``get_counterexample``; in your own tests, end with ``check_property(prop)``.

Where to go next
----------------

* :doc:`property_errors` steers the search to corner cases, fuzzes timing and handles designs that lock
  up.
* :doc:`../property_testing/index` lists every property procedure and setting.
