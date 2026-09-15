Test strategies
===============

Test a sequence of operations
-----------------------------

The snippets on this page use testbench helpers from the cookbook: :ref:`apply <property-helper-apply>`, :ref:`item <property-helper-item>`, :ref:`new_example <property-helper-new-example>` and :ref:`pulse <property-helper-pulse>`.

A design with state is tested with sequences of steps. Return a
``hypothesis.stateful.RuleBasedStateMachine`` subclass instead of a strategy: its rules keep a
reference model in Python and run each step in VHDL with ``step(rule, **fields)``, which returns the
value VHDL reports. Hypothesis shrinks a failure to the shortest failing sequence of steps.

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: Registers

The testbench dispatches on ``get_rule(prop)``, reads the arguments of the rule by name and answers
with ``report_step(prop, value)``. Every sequence starts with the rule ``"start"``, where the
design is reset. The register bank of the example loses writes to address 5, and the property finds
that:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent: 8

``get_counterexample`` then gives ``write(address=5, data=1); read(address=5)``.

Test Ethernet frames
--------------------

``tb_property_ethernet.vhd`` has a testbench of its own, since it instantiates the GMII source and
monitor. Every frame the source sends, the monitor must receive unchanged:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: frame_data

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: ethernet
   :end-before: -- docs-end: ethernet
   :dedent: 4

The typed Python API of the Ethernet VCs (``Frame``, ``WireOptions``, ``Malformation``,
``expected_violations``) gives strategies for malformed traffic and the violations a protocol checker
must count.

Handle a design that locks up
-----------------------------

An example can make a design lock up. Wait for the design with a simulation-time budget and report a
missed deadline with ``timed_out``: Hypothesis treats a lockup and wrong behavior as different
failures, so shrinking a lockup does not slip into another bug. ``example_budget(base, per_item,
items)`` scales a budget with the example. Reset the design after a lockup and report whether it
works again as ``recovered``; a design that does not recover ends the property as aborted, with the
smallest failing example found so far.

``tb_property_lockup.vhd`` has a testbench of its own, with a sink that stops taking octets after
0xFF. The property found the lockup and shrank it to ``[255, 0]``, which its strategy now pins (see
:doc:`reproducing`):

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: lockup
   :end-before: -- docs-end: lockup
   :dedent: 4

Examples must be independent. Reset the design, and every verification component that keeps state
(``reset`` of the Ethernet VCs), before each example. A property whose example fails once and passes
when repeated is reported as flaky, which usually means state leaked between examples.

Steer the search with scores
----------------------------

``report_score(prop, name, value)`` reports a score of the current example before its verdict, for
example the fill level a FIFO reached. It is forwarded to ``hypothesis.target``, which steers
generation towards higher scores, so rare corner cases are reached sooner. Report each name at most
once per example.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: score
   :end-before: -- docs-end: score
   :dedent: 8

Compare two runs
----------------

When the expected result is hard to compute, check a relation between two runs instead: the same
design with a transformed input must give a related output. Both runs belong to one example:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: metamorphic
   :end-before: -- docs-end: metamorphic
   :dedent: 8

Generate timing separately from data
------------------------------------

Draw the timing of an example, such as idle cycles between operations or where a reset lands,
separately from its data. Hypothesis then shrinks the two on their own, so a counterexample shows the
smallest data together with the simplest timing that still fails:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: timed_writes

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing
   :end-before: -- docs-end: timing
   :dedent: 8

Test random feature subsets
---------------------------

A strategy that mixes every kind of operation in every example can hide a bug that needs many of one
kind. Swarm testing first draws which kinds an example enables, then draws operations of those kinds
only:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: swarm

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: swarm
   :end-before: -- docs-end: swarm
   :dedent: 8

Related recipes
---------------

* :doc:`../cookbook/property_testing`

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`
