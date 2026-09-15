Test strategies
===============

.. _property-stateful:

Test a sequence of operations
-----------------------------

The snippets on this page use testbench helpers from the cookbook: :ref:`apply <property-helper-apply>`, :ref:`item <property-helper-item>`, :ref:`new_example <property-helper-new-example>` and :ref:`pulse <property-helper-pulse>`. ``BYTE`` is ``st.integers(0, 255)``, from the :ref:`imports of strategies.py <property-helper-byte>`.

.. include:: ../_includes/vunit_names.inc

A design with state is tested with sequences of steps. Return a
:class:`hypothesis.stateful.RuleBasedStateMachine` subclass instead of a strategy: its rules keep a
reference model in Python and run each step in VHDL with
:func:`step(rule, **fields) <awesome_vunit_vcs.common.property.step>`, which returns the value VHDL
reports. Hypothesis shrinks a failure to the shortest failing sequence of steps.

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: Registers

The testbench dispatches on :vhdl:`get_rule(prop) <property_pkg.get_rule>`, reads the arguments of
the rule by name and answers with :vhdl:`report_step(prop, value) <property_pkg.report_step>`. Every sequence starts with the rule ``"start"``, where the
design is reset. The register bank of the example loses writes to address 5, and the property finds
that:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent: 8

:vhdl:`get_counterexample <property_pkg.get_counterexample>` then gives
``write(address=5, data=1); read(address=5)``.

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

.. _property-lockup:

Handle a design that locks up
-----------------------------

An example can make a design lock up. Wait for the design with a simulation-time budget and report a
missed deadline with the ``timed_out`` argument of
:vhdl:`report_example(prop, passed, timed_out, recovered) <property_pkg.report_example>`: Hypothesis treats a lockup and wrong behavior as different
failures, so shrinking a lockup does not slip into another bug.
:vhdl:`example_budget(base, per_item, items) <property_pkg.example_budget>` gives a budget of
``base + per_item * items``, so it grows with the example; the testbench below waits
``example_budget(10 ns, 10 ns, 1)`` for each octet. Reset the design after a lockup and report whether it
works again with its ``recovered`` argument; a design that does not recover ends the property as aborted, with the
smallest failing example found so far.

``tb_property_lockup.vhd`` declares the ports of the sink as testbench signals, and the property and
``timed_out`` as variables of its process:

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: sink-signals
   :end-before: -- docs-end: sink-signals
   :dedent: 2

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: property-variables
   :end-before: -- docs-end: property-variables
   :dedent: 4

It is a testbench of its own, with a sink that stops taking octets after
0xFF. The property found the lockup and shrank it to ``[255, 0]``, which its strategy now pins (see
:doc:`reproducing`):

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: lockup
   :end-before: -- docs-end: lockup
   :dedent: 4

Examples must be independent. Reset the design, and every verification component that keeps state
(``reset`` of the Ethernet VCs, shown in :doc:`../cookbook/error_handling`), before each example. A property whose example fails once and passes
when repeated is reported as flaky, which usually means state leaked between examples.

.. _property-scores:

Steer the search with scores
----------------------------

:vhdl:`report_score(prop, name, value) <property_pkg.report_score>` reports a score of the current
example before its verdict, for example the fill level a FIFO reached. It is forwarded to
:func:`hypothesis.target`, which steers
generation towards higher scores, so rare corner cases are reached sooner. Report each name at most
once per example.

A good score is a number that grows as an example gets closer to the state you worry about: the peak
fill level of a FIFO, the largest value a counter reached, how close a sum came to overflowing, or the
number of retries a handshake needed. Score what the testbench measures, not what the strategy drew;
the operands themselves are already easy to draw.

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: score
   :end-before: -- docs-end: score
   :dedent: 8

.. _property-metamorphic:

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

.. _property-timing:

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

.. _property-swarm:

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
