Property-based testing
======================

Hypothesis generates test data inside the simulation and shrinks a failure to the smallest example.
The recipes come from :repo-file:`examples/property`, mostly the shared testbench
:repo-file:`examples/property/tb_property_examples.vhd`.

.. code-block:: console

   $ python examples/property/run.py

Write the simplest property
---------------------------

**Goal:** check one rule for many generated values.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: scalar
   :end-before: -- docs-end: scalar
   :dedent:

**When to use this:** when a rule should hold for every input, not just the few you would pick.

* Loop on ``next_example`` and call ``report_example`` once per example.
* Keep examples independent: reset the DUT between them if it has state.

**Full example:** ``test_scalar``

**See also:** :doc:`../property_testing/index`

Read composite examples
-----------------------

**Goal:** get fields, lists and optional parts of a generated example.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: composite
   :end-before: -- docs-end: composite
   :dedent:

**When to use this:** when one example has several parts, such as a configuration and a list of
frames.

* Paths look like ``"frames(2).payload"``; ``get_length`` and ``has_field`` handle lists and options.

**Full example:** ``test_composite``

**See also:** :doc:`../property_testing/index`

Use a record from a Python dataclass
------------------------------------

**Goal:** define the data once in Python and read it as a typed VHDL record.

.. literalinclude:: ../../examples/property/run.py
   :caption: examples/property/run.py
   :language: python
   :start-after: # docs-start: generate
   :end-before: # docs-end: generate

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: generated_record
   :end-before: -- docs-end: generated_record
   :dedent:

**When to use this:** when many tests read the same structured data, so hand-written getters would
repeat.

* Regenerate the package from ``run.py`` so the record always matches the dataclass.

**Full example:** ``test_generated_record``

**See also:** :doc:`../property_testing/index`

Test a sequence of operations
-----------------------------

**Goal:** let Hypothesis generate operation sequences and shrink to the shortest failing one.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent:

**When to use this:** for DUTs with state, such as register banks, FIFOs or memories.

* Reset the DUT in the ``"start"`` rule; every sequence begins with it.

**Full example:** ``test_stateful``

**See also:** :doc:`../property_testing/index`

Steer the search towards corner cases
-------------------------------------

**Goal:** give Hypothesis a score so it looks for larger values of it.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: score
   :end-before: -- docs-end: score
   :dedent:

**When to use this:** when bugs hide at extremes, such as a full FIFO or the largest latency.

**Full example:** ``test_score``

**See also:** :doc:`../property_testing/index`

Compare two runs instead of expected values
-------------------------------------------

**Goal:** check a relation between outputs, such as "the order of the operands doesn't matter".

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: metamorphic
   :end-before: -- docs-end: metamorphic
   :dedent:

**When to use this:** when you can't compute the expected output, but know how outputs relate.

**Full example:** ``test_metamorphic``

**See also:** :doc:`../property_testing/index`

Generate timing separately from data
------------------------------------

**Goal:** vary delays between operations, independently of the data.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing
   :end-before: -- docs-end: timing
   :dedent:

**When to use this:** when bugs depend on when things happen, such as stalls or a reset in the middle
of a transfer.

**Full example:** ``test_timing``

**See also:** :doc:`../property_testing/index`

Test with random feature subsets
--------------------------------

**Goal:** each example enables only some kinds of operation.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: swarm
   :end-before: -- docs-end: swarm
   :dedent:

**When to use this:** when a mix of every feature in every example could hide a bug that needs one
feature on its own.

**Full example:** ``test_swarm``

**See also:** :doc:`../property_testing/index`

Handle a DUT that locks up
--------------------------

**Goal:** turn a hang into a failed example that still shrinks.

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: lockup
   :end-before: -- docs-end: lockup
   :dedent:

**When to use this:** when some inputs can make the DUT stop responding.

* Give each example a time budget, and reset the DUT before the next example.

**Full example:** :repo-file:`examples/property/tb_property_lockup.vhd`

**See also:** :doc:`../property_testing/index`

Always test a known failure first
---------------------------------

**Goal:** pin examples, and choose a short or a long run.

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :start-after: # docs-start: pin
   :end-before: # docs-end: pin

**When to use this:** after fixing a bug a property found, so it can never come back unnoticed.

* Pinned examples run first, every time.
* Run ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=long`` nightly for a deeper search.

**Full example:** :repo-file:`examples/property/python/strategies.py`

.. code-block:: console

   $ AWESOME_VUNIT_VCS_PROPERTY_PROFILE=long python examples/property/run.py

**See also:** :doc:`../property_testing/index`

Test Ethernet frames with properties
------------------------------------

**Goal:** send generated frames through the Ethernet components.

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: ethernet
   :end-before: -- docs-end: ethernet
   :dedent:

**When to use this:** to find the frames that break an Ethernet DUT.

**Full example:** :repo-file:`examples/property/tb_property_ethernet.vhd`

**See also:** :doc:`../property_testing/index`, :doc:`python`
