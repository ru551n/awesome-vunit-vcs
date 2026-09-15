Property-based testing in your testbench
========================================

When we pick test data by hand, we test the cases we thought of. Bugs tend to live in the ones we
didn't. Property-based testing turns this around: we state a rule that must hold for every input, and
Hypothesis generates the inputs. When one fails, Hypothesis shrinks it to the smallest example that
still fails.

In this article we start with the smallest property that passes and build up to structured data and
Ethernet frames. Sequences of operations on a design with state come last, under *Going further*.

.. include:: ../_includes/vunit_names.inc

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
     - The run script, with the same package setup as any other testbench
       (:doc:`../getting_started/vunit_integration`): ``add_verification_components()`` is needed
       even when the testbench uses no verification component.

You need Hypothesis installed (``pip install hypothesis``) to run properties. Your VHDL never imports
anything from it.

Step 1: the testbench setup (VHDL)
----------------------------------

A property testbench needs one context clause, ``property_context``. In a testbench that already uses
``ethernet_context`` or ``flash_context``, leave it out: those include it.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: libraries
   :end-before: -- docs-end: libraries

.. _property-helper-apply:

The designs under test are an arithmetic unit (ALU), with inputs ``a`` and ``b`` and output ``y``, and a
register bank. ``apply`` is a small helper in the testbench that puts two operands on the ALU:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: apply-helper
   :end-before: -- docs-end: apply-helper
   :dedent:

Step 2: write the first property
--------------------------------

**In Python**, a strategies module starts with its imports. ``strategies`` comes from Hypothesis;
``pin`` and ``step`` come from ``awesome_vunit_vcs.common.property`` and ``strategy_for`` from
``awesome_vunit_vcs.records``, for later steps:

.. _property-helper-byte:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :start-after: # docs-start: imports
   :end-before: # docs-end: imports

The strategy for our first property is just a byte:

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

``new_property`` names the strategy as ``"module:function"``. ``search_path`` tells the simulator where
your strategies live, the ``python`` directory next to the testbench. ``get_seed(runner_cfg)`` makes a run
repeatable, and ``output_path(runner_cfg)`` keeps a journal and the smallest failure in the test's output.

The loop is the whole pattern:

#. ``next_example`` asks Hypothesis for the next example, and returns false when there are no more.
#. ``get_integer`` reads the example.
#. ``report_example`` tells Hypothesis whether the rule held.

After the loop, ``check_property(prop)`` fails the test if any example failed and logs the smallest
failing one. Run it like any other VUnit test:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python examples/property/run.py --output-path ../vunit_out "*test_scalar"
   pass lib.tb_property_examples.test_scalar (0.3 s)
   pass 1 of 1
   All passed!

Keep examples independent. If your design has state, reset it at the start of each example.

When a property fails
~~~~~~~~~~~~~~~~~~~~~

Say the design is wrong for values of 200 and up. Hypothesis finds a failing value, shrinks it to the
smallest one that still fails, and ``check_property`` reports that one as an error:

.. code-block:: console
   :caption: Terminal

   $ VUNIT_SIMULATOR=nvc python run.py --output-path ../vunit_out -v
   Seed for lib.tb_fail.all: 33341be35c1f9e05
   0 fs - tb_fail:sum - ERROR - Property failed after 20 examples. Minimal counterexample (wrong behavior): 200. Saved failure: <output-path>/test_output/property_failures/lib.tb_fail.all_<hash>.tb_fail_sum.txt. Journal: <output-path>/test_output/lib.tb_fail.all_<hash>/property_journal_tb_fail_sum.jsonl
   fail (P=0 S=0 F=1 T=1) lib.tb_fail.all (0.4 s)

The message names the files it mentions below. This property was created with
``new_property(..., id => get_id("tb_fail:sum"))``. ``get_id`` is VUnit's function for a hierarchical
name (see the `VUnit logging user guide <https://vunit.github.io/logging/user_guide.html>`_), and the
``id`` gives the property a readable name in the log and in those file names; without an ``id`` they
use ``awesome_vunit_vcs:property:<n>``.

The value after ``Minimal counterexample`` is what your design got wrong. To debug it:

#. **Rerun with the same seed.** ``python run.py --output-path ../vunit_out --seed 33341be35c1f9e05`` runs the same examples again.
#. **Look at the saved failure.** The smallest failing example is saved in
   ``<output-path>/test_output/property_failures/``, in the file the message names:
   ``lib.tb_fail.all_<hash>.tb_fail_sum.txt`` here, the test's output directory name and the property
   id with ``:`` written as ``_``. It holds the example as Python writes it (``200`` here). The next run with the same ``--output-path`` tries it first and
   stops at that example if it still fails, so a fix is checked against it straight away. To repeat the
   whole search instead, rerun with the seed and a fresh ``--output-path``.
#. **Look at the journal.** Every example is written to ``property_journal_<name>.jsonl`` in the test's
   output directory before it runs, so you know the input even when the simulation crashes or hits
   the watchdog.
#. **Keep it as a regression test.** Once fixed, ``@pin(200)`` on the strategy function tries the value
   first on every run.

To assert that a property *fails*, for example to prove a checker catches a planted bug, read the
result with ``get_outcome`` instead of calling ``check_property``. :doc:`../property_testing/reproducing`
has that pattern and everything else about seeds, saved failures, pins and profiles.

Step 3: read structured examples
--------------------------------

.. _property-helper-new-example:

From here on, the example testbench creates properties with a helper, ``new_example``, that makes the
same ``new_property`` call for a strategy name:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: new-example-helper
   :end-before: -- docs-end: new-example-helper
   :dedent:

Real test data has structure: a list of values and an optional offset, for example. **In Python**, a
strategy can return dictionaries and lists. ``optional`` adds a key to some examples only:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: composite

**In VHDL**, reach the parts with a path. ``get_length`` gives the length of a list, and ``has_field``
tells whether an optional part is there:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: composite
   :end-before: -- docs-end: composite
   :dedent:

.. _property-helper-item:

``item`` is a small helper in the testbench. It builds ``"(2)"`` from an index, so the path reads
``"values(2)"``:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: item-helper
   :end-before: -- docs-end: item-helper
   :dedent:

Paths can go deeper, such as ``"frames(2).payload"``.

Step 4: send generated frames through the Ethernet components
-------------------------------------------------------------

Properties and the Ethernet components fit together. Start with the smallest mixed property: Python
draws only a payload length, and VHDL builds the frame. **In Python**:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: payload_length

**In VHDL**, one context clause is enough, because ``ethernet_context`` includes the property package:

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

The GMII source and monitor are created and instantiated as in
:ref:`Your first Ethernet test, step 3 <first-test-handles>`. The process declares the property, room
for the frame it receives, and a 14-octet header:

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: frame-variables
   :end-before: -- docs-end: frame-variables
   :dedent:

For each drawn length, the test sends the header and a payload of that length, pops the frame at the
other end, and checks its length:

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: payload-lengths
   :end-before: -- docs-end: payload-lengths
   :dedent:

``pop_ethernet_frame`` waits for the next frame and returns its :term:`frame data` and length in octets;
the form with ``fcs_ok`` also tells whether the FCS was right (see :vhdl:`ethernet_pkg.pop_ethernet_frame`).

Next, let Hypothesis draw the whole frame. **In Python**, generate frame data:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: frame_data

**In VHDL**, each example goes through a :term:`source` and comes back from a :term:`monitor`, and the
property is that it comes back unchanged. The test sends each drawn frame and pops it at the other end:

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
returns the result to the model.

.. _property-helper-pulse:

``pulse`` is a helper that holds a signal high for one clock cycle:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: pulse-helper
   :end-before: -- docs-end: pulse-helper
   :dedent:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent:

Every sequence begins with the ``"start"`` rule, where the testbench resets the design. Call
``report_step`` after every step, ``"start"`` included, or the model waits forever; for a rule that
returns nothing, such as ``"start"`` or a write, report 0, and the model ignores the value. The register
bank in this example has a planted bug: it loses writes to address 5. Hypothesis finds it and shrinks
the failure to two steps, ``write(address=5, data=1); read(address=5)``. Because the example expects
that failure, it checks the counterexample instead of calling ``check_property``; see
:ref:`expect-a-failure`. In your own tests, end with ``check_property(prop)``.

Where to go next
----------------

* :doc:`property_errors` steers the search to corner cases, fuzzes timing and handles designs that lock
  up.
* :doc:`../property_testing/index` lists every property procedure and setting.
