Finding the hard bugs with properties
=====================================

This article goes further than :doc:`property_testing`, so read that one first. There, Hypothesis drew
inputs at random. That finds a lot, but some bugs hide where random inputs rarely go: at extremes, in
rare timing, or behind a mix of features that masks them. Here we point Hypothesis at those places,
starting with the simplest technique, and end with the hardest failure of all: a design that stops
responding.

The files are the same as before: strategies in ``examples/property/python/strategies.py`` (Python)
and test loops in ``examples/property/tb_property_examples.vhd`` (VHDL), using the helpers :ref:`apply <property-helper-apply>`, :ref:`item <property-helper-item>`, :ref:`new_example <property-helper-new-example>` and :ref:`pulse <property-helper-pulse>` shown in
:doc:`property_testing`. The design is the same small arithmetic unit too: its operands ``a`` and
``b`` and its result ``y`` are declared in step 1 of that article, and the ``pair`` strategy draws the
two operands.

Step 1: compare two runs instead of expected values
---------------------------------------------------

Sometimes we can't say what the output should be, but we know how two outputs relate. Swapping the
operands of an addition must not change the sum. **In VHDL**, run the design twice and compare:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: metamorphic
   :end-before: -- docs-end: metamorphic
   :dedent:

No reference model and no new Python: the strategy is the ``pair`` strategy from
:doc:`property_testing`.

Step 2: steer the search towards corner cases
---------------------------------------------

Say the carry of our adder is only wrong when the sum overflows. **In VHDL**, give each example a score
that grows towards the interesting case:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: score
   :end-before: -- docs-end: score
   :dedent:

``report_score`` doesn't decide whether an example passes. It tells Hypothesis that larger sums are more
interesting, so more examples go there. Scores suit anything with an extreme: a full FIFO, the longest
latency, the most retries.

Step 3: generate timing separately from data
--------------------------------------------

Many bugs depend on *when* things happen. **In Python**, give timing its own part of the example, here
the idle cycles before each write:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: timed_writes

**In VHDL**, wait that many cycles before each write, then read everything back:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing
   :end-before: -- docs-end: timing
   :dedent:

Because data and idle cycles are drawn apart, a failure shrinks to the simplest data *and* the simplest
timing that break the design.

Step 4: test with random subsets of features
--------------------------------------------

When every example mixes every kind of operation, a bug that needs one kind alone can stay hidden.
**In Python**, let each example first pick which kinds it enables, then draw operations of those kinds:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: swarm

**In VHDL**, run whatever operations the example holds; the testbench doesn't need to know about the
subsets:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: swarm
   :end-before: -- docs-end: swarm
   :dedent:

Step 5: fuzz backpressure on an AXI-Stream bus
----------------------------------------------

Timing fuzzing works with the Ethernet components too. On AXI-Stream the receiver decides when to take
data. **In Python**, draw the sink's ``tready`` pattern together with the frame:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :pyobject: backpressure

**In VHDL**, apply the pattern to the sink with ``set_ready_pattern`` before sending each frame:

.. literalinclude:: ../../examples/property/tb_property_ethernet.vhd
   :caption: examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: axis-backpressure
   :end-before: -- docs-end: axis-backpressure
   :dedent:

A failure shrinks to the shortest frame and the simplest pattern that break the design.
``axis_source``, ``axis_sink`` and ``axis_monitor`` are the AXI-Stream source, sink and monitor handles:
:doc:`beyond_gmii` shows how they are created, and :doc:`../ethernet/axis_mac` describes the components
and ``set_ready_pattern``.

Step 6: keep a bug from coming back
-----------------------------------

Once a property has found a bug and we have fixed it, that exact example should run every time from
now on. **In Python**, pin it to the strategy:

.. literalinclude:: ../../examples/property/python/strategies.py
   :caption: examples/property/python/strategies.py
   :language: python
   :start-after: # docs-start: pin
   :end-before: # docs-end: pin

Pinned examples always run first. How many other examples run is set by a profile: the default is a
quick run for every commit. For a deeper search, for example every night, run the long profile:

.. code-block:: console
   :caption: Terminal

   $ AWESOME_VUNIT_VCS_PROPERTY_PROFILE=long python examples/property/run.py

Going further: handle a design that locks up
--------------------------------------------

Some inputs don't make a design answer wrongly, they make it stop answering, and the simulation hangs.
This takes more care than the steps above. **In VHDL**, give each wait a time budget, reset the design
after every example, and report a timeout as a failure:

.. literalinclude:: ../../examples/property/tb_property_lockup.vhd
   :caption: examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: lockup
   :end-before: -- docs-end: lockup
   :dedent:

Three things make this work:

#. Every wait has a timeout (``for 20 ns``), so a stuck design can't stall the test.
#. The design is reset after every example, so the next one starts clean.
#. ``report_example`` says that the example timed out, and whether the reset brought the design back
   (``recovered``).

A lockup shrinks like any other failure: here to the two bytes ``[255, 0]``, which is also the pinned
example of step 6. The strategy, ``byte_stream``, is the one shown there. If your testbench uses
Ethernet or flash components, reset them between examples too, as :doc:`error_handling` shows.

Where to go next
----------------

* :doc:`../property_testing/index` lists every property procedure and setting.
* :doc:`../property_testing/reproducing` explains how to replay a failure.
