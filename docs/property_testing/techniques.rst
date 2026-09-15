Technique examples
===================

Each technique below has a small, tested example in ``examples/property``; run all of them with
``python examples/property/run.py --output-path out/property``. Some examples carry a deliberate bug,
off by default: set ``AWESOME_VUNIT_VCS_EXAMPLE_BUGS=1`` to turn it on and watch Hypothesis find and
shrink it.

.. code-block:: bash
   :caption: Terminal

   python examples/property/run.py --output-path out/property
   AWESOME_VUNIT_VCS_EXAMPLE_BUGS=1 python examples/property/run.py --output-path out/property

Each of those benches has an ``inject_bug`` generic, false by default. The run script sets it on the
benches of ``lib``, the library it added the testbenches to (Python):

.. literalinclude:: ../../examples/property/run.py
   :caption: examples/property/run.py
   :language: python
   :start-after: # docs-start: inject-bug
   :end-before: # docs-end: inject-bug

Do the same in your own run script to keep a known bug switchable in a testbench.

.. include:: ../_includes/vunit_names.inc

The snippets on this page use testbench helpers from the cookbook: :ref:`apply <property-helper-apply>`,
:ref:`item <property-helper-item>`, :ref:`new_example <property-helper-new-example>` and
:ref:`pulse <property-helper-pulse>`.

Coverage matrix
----------------

.. list-table::
   :header-rows: 1
   :widths: 28 32 40

   * - Technique
     - Example (bench and test case)
     - Where explained
   * - Scalar and composite values
     - ``tb_property_examples`` (``test_scalar``, ``test_composite``)
     - :ref:`Write a first property <property-scalar-values>`,
       :ref:`Read composite examples <property-composite-values>`
   * - Stateful testing
     - ``tb_property_examples`` (``test_stateful``)
     - :ref:`Test a sequence of operations <property-stateful>`
   * - Resource lifecycle with Bundles
     - ``tb_property_resources`` (``test_resources``)
     - :ref:`Resource lifecycle with Bundles <property-resources>`
   * - Interleaved event schedules
     - ``tb_property_interleaving`` (``test_interleaving``)
     - :ref:`Interleaved event schedules <property-interleaving>`
   * - Recursive, grammar-based inputs
     - ``tb_property_recursive`` (``test_expressions``)
     - :ref:`Recursive, grammar-based inputs <property-recursive>`
   * - Fault injection
     - ``tb_property_corruption`` (``test_fault_injection``)
     - :ref:`Fault injection <property-fault-injection>`
   * - Timing variation
     - ``tb_property_examples`` (``test_timing``)
     - :ref:`Generate timing separately from data <property-timing>`
   * - Clock ratio and phase (CDC)
     - ``tb_property_cdc`` (``test_clock_ratio_and_phase``)
     - :ref:`Clock ratio and phase (CDC) <property-cdc>`
   * - Metamorphic properties
     - ``tb_property_examples`` (``test_metamorphic``)
     - :ref:`Compare two runs <property-metamorphic>`
   * - Differential testing of two designs
     - ``tb_property_bits`` (``test_differential_popcount``)
     - :ref:`Differential testing of two designs <property-differential>`
   * - Round-trip properties
     - ``tb_property_bits`` (``test_roundtrip_pack``)
     - :ref:`Round-trip properties <property-roundtrip>`
   * - Hardware bit patterns
     - ``tb_property_bits`` (``test_differential_popcount``, ``test_roundtrip_pack``)
     - :ref:`Hardware bit patterns <property-bit-patterns>`
   * - Targeting with scores
     - ``tb_property_examples`` (``test_score``)
     - :ref:`Steer the search with scores <property-scores>`
   * - Occupancy targeting (FIFO)
     - ``tb_property_fifo`` (``test_occupancy_targeting``)
     - :ref:`Occupancy targeting <property-occupancy>`
   * - Swarm testing
     - ``tb_property_examples`` (``test_swarm``)
     - :ref:`Test random feature subsets <property-swarm>`
   * - Invalid-input mutation
     - ``tb_property_corruption`` (``test_invalid_packet_mutation``)
     - :ref:`Invalid-input mutation <property-invalid-mutation>`
   * - Lockups and timeouts
     - ``tb_property_lockup``
     - :ref:`Handle a design that locks up <property-lockup>`
   * - Recovery after a lockup
     - ``tb_property_lockup``
     - :ref:`Handle a design that locks up <property-lockup>`
   * - Shrinking
     - every example above
     - Every counterexample on this page, and throughout the property-testing docs, is already the
       shrunk result: no example here is shown as first drawn
   * - Replaying failures (seeds, pins)
     - —
     - :ref:`Pin known failures and set budgets <property-pins>`,
       :ref:`Replay a failure <property-replay>`
   * - AXI4-Stream TVALID must not wait for TREADY
     - ``tb_property_axi_ready`` (``test_tready_fork``, ``test_known_pending``)
     - :ref:`AXI4-Stream TVALID must not wait for TREADY <property-axi-ready>`

.. _property-resources:

Resource lifecycle with Bundles
--------------------------------

Use when a design hands out identity-bearing resources — handles, IDs, buffer slots — that must be
tracked through allocate, use and release, and a step should only touch a resource it actually owns.

**What Hypothesis generates.** A ``RuleBasedStateMachine`` with rules ``allocate``, ``write``, ``read``
and ``release``; ``write``, ``read`` and ``release`` take a handle drawn from a ``Bundle`` of the
handles currently live, so a step can only reference a handle the model actually allocated and has not
yet released. ``BYTE`` is ``st.integers(0, 255)``.

**The property.** A read returns the last value written to a handle, and ``allocate`` never hands out a
handle that is already live.

**Why not plain random stimulus.** A random handle number almost never names one that is actually
allocated, so a write, read or release drawn independently would rarely land on a live handle; the
Bundle guarantees every step targets a real one.

**What it shrinks.** The sequence of steps, toward the fewest ``allocate``/``write``/``read``/``release``
calls, and which handles they touch.

**Bugs it finds.** Handle aliasing and reuse bugs: releasing or reusing the wrong slot, so two live
handles end up sharing the same storage.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_resources.vhd
   :caption: examples/property/tb_property_resources.vhd
   :language: vhdl
   :start-after: -- docs-start: resources
   :end-before: -- docs-end: resources
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/resources_strategies.py
   :caption: examples/property/python/resources_strategies.py
   :language: python
   :start-after: # docs-start: resources
   :end-before: # docs-end: resources

``inject_bug`` makes ``handle_table``'s ``release`` free the lowest still-live slot instead of the one
named by ``handle``, so a later ``allocate`` can hand out a handle that is still live. The counterexample
it shrinks to:

.. code-block:: text

   allocate(); allocate(); release(handle=1); allocate()
   -- allocate returned 0, which is already live

.. _property-interleaving:

Interleaved event schedules
-----------------------------

Use for designs where two or more independent request streams interact on the same clock, and a bug
only shows when several of their events land on the same cycle.

**What Hypothesis generates.** A list of timestamped events, each a ``(cycle, actor, action)`` triple
for client A or B doing ``request``, ``cancel`` or ``release``; several events may share a cycle, and
the list is left unsorted for Hypothesis to shrink freely. ``interleaving`` narrows the reusable
``event_schedule`` helper to two actors and three actions.

**The property.** Every cycle: never both grants at once, no grant without a request, and a client that
is still requesting never has its grant dropped.

**Why not plain random stimulus.** Requests drawn independently per client, applied without regard to
cycle, would rarely line up two clients' events on the exact same cycle; drawing one shared schedule of
timestamped events is what makes the race reachable.

**What it shrinks.** How many events there are, which cycles they land on, and which client and action
each is.

**Bugs it finds.** Same-cycle races in arbitration or handshake logic: a grant issued the very cycle
another client's grant is dropping, so both clients hold the resource at once.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_interleaving.vhd
   :caption: examples/property/tb_property_interleaving.vhd
   :language: vhdl
   :start-after: -- docs-start: interleaving
   :end-before: -- docs-end: interleaving
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/interleaving_strategies.py
   :caption: examples/property/python/interleaving_strategies.py
   :language: python
   :start-after: # docs-start: interleaving
   :end-before: # docs-end: interleaving

``inject_bug`` makes ``arbiter2`` grant a request the same cycle the other client releases, so both stay
held for a cycle. The counterexample it shrinks to:

.. code-block:: text

   cycle 0: A request, cycle 0: B request, cycle 1: A cancel
   -- cycle 1: both grant_a and grant_b are 1

.. _property-recursive:

Recursive, grammar-based inputs
---------------------------------

Use for a design that evaluates a nested or recursive structure — expressions, trees, frames with
sub-frames — where a flat list of inputs cannot express the nesting a bug depends on.

**What Hypothesis generates.** An arithmetic expression tree, built with ``st.recursive``:
``const(value)``, ``add(e, e)``, ``subtract(e, e)`` or ``negate(e)``, up to 8 leaves, then serialized to
a postfix program. ``_to_example`` evaluates the tree in Python and pairs it with the serialized
program.

**The property.** The DUT's result, after replaying the postfix program one instruction per clock
cycle, matches the reference evaluator's expected value for the same tree.

**Why not plain random stimulus.** A flat list of operands and operators cannot express nesting, so it
would only ever exercise expressions one level deep; a bug in a nested subtraction needs a tree.

**What it shrinks.** The expression tree: fewer leaves, shallower nesting, smaller constants.

**Bugs it finds.** Operand-order bugs in ALU-like operations, easy to get right for a single operation
and wrong once one feeds another.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_recursive.vhd
   :caption: examples/property/tb_property_recursive.vhd
   :language: vhdl
   :start-after: -- docs-start: recursive
   :end-before: -- docs-end: recursive
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/recursive_strategies.py
   :caption: examples/property/python/recursive_strategies.py
   :language: python
   :start-after: # docs-start: expressions
   :end-before: # docs-end: expressions

``inject_bug`` swaps ``rpn_evaluator``'s subtract operand order, computing ``b - a`` instead of
``a - b``. The counterexample it shrinks to, the tree ``subtract(const(0), const(1))``:

.. code-block:: text

   {'tree': {'op': 'subtract', 'left': {'op': 'const', 'value': 0}, 'right': {'op': 'const', 'value': 1}},
    'program': [{'op': 'const', 'value': 0}, {'op': 'const', 'value': 1}, {'op': 'subtract', 'value': 0}],
    'expected': 255}

.. _property-fault-injection:

Fault injection
-----------------

Use when a design has a deliberate error-detection or error-correction path, and the property must
prove it catches faults, not just that it passes clean data.

**What Hypothesis generates.** A data byte and, optionally, one fault: which kind (flip a data bit or
the parity bit) and which bit position.

**The property.** With no fault, the register reads back cleanly; with a fault, the error output goes
high.

**Why not plain random stimulus.** A random data byte with no fault almost never demonstrates that
undetected corruption is possible; drawing the fault itself, kind and position, as part of the example
is what reaches the exact bit a detector misses.

**What it shrinks.** The data byte, the fault kind and the bit position.

**Bugs it finds.** Silent data-corruption bugs, where an error detector does not actually cover every
bit it claims to.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_corruption.vhd
   :caption: examples/property/tb_property_corruption.vhd
   :language: vhdl
   :start-after: -- docs-start: fault_injection
   :end-before: -- docs-end: fault_injection
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/corruption_strategies.py
   :caption: examples/property/python/corruption_strategies.py
   :language: python
   :start-after: # docs-start: fault_injection
   :end-before: # docs-end: fault_injection

``inject_bug`` leaves bits 7 downto 4 out of ``parity_register``'s parity, so a fault there goes
undetected. The counterexample it shrinks to:

.. code-block:: text

   {'data': 0, 'fault': {'kind': 'flip_data', 'position': 4}}

.. _property-cdc:

Clock ratio and phase (CDC)
------------------------------

Use for logic that crosses a clock boundary, to search the clock ratio, phase and event timing for the
alignment that breaks it. **This does not model analog metastability.** It explores clock ratio, phase,
event loss or duplication, and reset timing — digital control-logic issues, not the analog settling
behaviour of a real flip-flop.

**What Hypothesis generates.** Source and destination clock periods, the destination clock's phase, and
1 to 6 source-domain event cycles, spaced at least the ratio-dependent legal minimum apart so a passing
run stays legal.

**The property.** Every legal source event produces exactly one destination event, within a bounded
number of destination cycles: no losses, no duplicates.

**Why not plain random stimulus.** Independently random clock periods rarely land two clocks in the
exact ratio and phase, or an event exactly where the synchronizer's timing is tight; drawing periods,
phase and event spacing together lets the search home in on a failing alignment.

**What it shrinks.** The clock periods, the destination phase, and the number and spacing of events —
timing counterexamples shrink to a failing alignment, not necessarily the smallest numbers.

**Bugs it finds.** CDC control-logic bugs: lost or merged events crossing a clock domain.

VHDL (testbench), one clock generator per domain, with the period and phase each example draws:

.. literalinclude:: ../../examples/property/tb_property_cdc.vhd
   :caption: examples/property/tb_property_cdc.vhd
   :language: vhdl
   :start-after: -- docs-start: cdc-clocks
   :end-before: -- docs-end: cdc-clocks
   :dedent: 2

VHDL (testbench), the property loop with the reset sequence:

.. literalinclude:: ../../examples/property/tb_property_cdc.vhd
   :caption: examples/property/tb_property_cdc.vhd
   :language: vhdl
   :start-after: -- docs-start: cdc-property
   :end-before: -- docs-end: cdc-property
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/cdc_strategies.py
   :caption: examples/property/python/cdc_strategies.py
   :language: python
   :start-after: # docs-start: toggle_sync
   :end-before: # docs-end: toggle_sync

``inject_bug`` swaps ``toggle_synchronizer``'s toggle handshake for a naive pulse synchronizer, which
loses or merges events. The counterexample it shrinks to:

.. code-block:: text

   {'src_period_ps': 2000, 'dst_period_ps': 2208, 'dst_phase_ps': 697, 'events': [26]}

.. _property-differential:

Differential testing of two designs
--------------------------------------

Use when two implementations of the same function exist — an optimized one and a simple one, or an HDL
implementation and a reference model — and no independent oracle is worth writing.

**What Hypothesis generates.** One 16-bit input, drawn from :ref:`hardware bit patterns
<property-bit-patterns>` mixed with arbitrary values.

**The property.** Two independently written popcount implementations, ``popcount_loop`` and
``popcount_adder_tree``, agree on every input.

**Why not plain random stimulus.** There is no golden model to compare against, so a plain assertion
would need a specification; feeding the same input to two independently written implementations turns
"do these agree" into the property, with no expected value to compute.

**What it shrinks.** The 16-bit pattern, towards the simplest bit pattern that still fails. That is
usually a single set bit, but a run can also end on another simple pattern, such as a single cleared bit.

**Bugs it finds.** An implementation bug present in one of the two designs only, found without a third
reference model.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_bits.vhd
   :caption: examples/property/tb_property_bits.vhd
   :language: vhdl
   :start-after: -- docs-start: differential_popcount
   :end-before: -- docs-end: differential_popcount
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/bits_strategies.py
   :caption: examples/property/python/bits_strategies.py
   :language: python
   :start-after: # docs-start: differential_popcount
   :end-before: # docs-end: differential_popcount

``WIDTH`` is 16, the width of both popcount inputs. ``inject_bug`` makes ``popcount_adder_tree`` drop
the MSB before counting. The counterexample it usually shrinks to (``65534``, the MSB with one other bit
cleared, is another one you may see):

.. code-block:: text

   data_in=32768

.. _property-roundtrip:

Round-trip properties
------------------------

Use when a transform has an inverse and no separate expected-value computation is worth writing.

**What Hypothesis generates.** The four fields of the packed record — ``opcode``, ``flag``, ``address``
and ``value`` — each drawn independently across its full range.

**The property.** ``unpack(pack(x)) = x``: ``field_unpacker`` must return exactly what
``field_packer`` was given, with no expected value computed separately.

**Why not plain random stimulus.** The same reasoning as differential testing: there is no golden model
either, only that unpacking what was packed returns the original fields.

**What it shrinks.** The four fields, each toward its smallest value.

**Bugs it finds.** Field-boundary bugs in pack/unpack logic, where bits cross into the wrong field.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_bits.vhd
   :caption: examples/property/tb_property_bits.vhd
   :language: vhdl
   :start-after: -- docs-start: roundtrip_pack
   :end-before: -- docs-end: roundtrip_pack
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/bits_strategies.py
   :caption: examples/property/python/bits_strategies.py
   :language: python
   :start-after: # docs-start: roundtrip_pack
   :end-before: # docs-end: roundtrip_pack

``inject_bug`` swaps the address MSB with the value LSB in ``field_unpacker``. The counterexample it
shrinks to:

.. code-block:: text

   {'opcode': 0, 'flag': 0, 'address': 0, 'value': 1}

.. _property-bit-patterns:

Hardware bit patterns
------------------------

Use as the input strategy for any design where a plain arbitrary integer would rarely draw the corner
cases hardware bugs hide in: all zero, all one, a single bit, a single cleared bit, a run of ones, the
sign bit.

**What Hypothesis generates.** ``interesting_unsigned`` mixes structured, hardware-relevant corner
cases — ``zero``, ``one``, ``all_ones``, ``sign_bit``, ``max_signed_positive``, ``powers_of_two``,
``powers_of_two_minus_one``, ``powers_of_two_plus_one``, ``one_hot``, ``one_cold``,
``contiguous_mask``, ``sparse_mask`` and ``alternating_bits`` — with an ordinary arbitrary
``st.integers`` draw, generic in the bit width.

**The property.** Not a property of its own: ``interesting_unsigned`` is the input strategy behind
:ref:`differential testing <property-differential>` above.

**Why not plain random stimulus.** An arbitrary integer draws a single bit set, a sign bit or a full
mask only rarely; sampling these structured patterns explicitly puts them within reach on every run.

**What it shrinks.** Hypothesis shrinks ``sampled_from`` towards earlier elements and ``one_of`` towards
earlier branches, so the simplest patterns — few or one bit set — come first.

**Bugs it finds.** Boundary and single-bit bugs: an MSB dropped, a carry mishandled, a mask off by one
bit.

``bit_patterns.py`` is part of the example, not of the package: copy the whole file into the ``python/``
directory of your own testbench, since ``interesting_unsigned`` uses the other strategies in it, and import
it from your strategy module, as ``bits_strategies.py`` does.

Python (strategy module):

.. literalinclude:: ../../examples/property/python/bit_patterns.py
   :caption: examples/property/python/bit_patterns.py
   :language: python
   :start-after: # docs-start: interesting_unsigned
   :end-before: # docs-end: interesting_unsigned

.. _property-occupancy:

Occupancy targeting
-------------------

Use when a bug hides in a deep internal state, such as a full FIFO or a nearly exhausted pool, that
random stimulus seldom reaches, and the testbench can measure how close an example got.

**What Hypothesis generates.** Up to 32 clock cycles, each a ``push``, a ``pop`` or a ``push_pop``.

**The property.** Every pop returns the oldest word, and ``count`` matches a reference model kept in the
testbench. The testbench scores each example with the highest occupancy it reached, and Hypothesis
favours operation lists that fill the FIFO further.

**Why not plain random stimulus.** Filling a depth-8 FIFO needs many more pushes than pops in a row;
random lists rarely get there. With the score removed, the planted bug was found in 2 of 8 runs; with
it, in 8 of 8.

**What it shrinks.** The number of cycles and the operation of each one.

**Bugs it finds.** Corner cases at a full or empty boundary: a lost word, a wrong count or a stuck flag.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_fifo.vhd
   :caption: examples/property/tb_property_fifo.vhd
   :language: vhdl
   :start-after: -- docs-start: fifo
   :end-before: -- docs-end: fifo
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/fifo_strategies.py
   :caption: examples/property/python/fifo_strategies.py
   :language: python
   :start-after: # docs-start: operations
   :end-before: # docs-end: operations

``inject_bug`` makes ``fifo8`` drop the pushed word on a push and pop at once while full. The
counterexample it shrinks to:

.. code-block:: text

   ['push', 'push', 'push', 'push', 'push', 'push', 'push', 'push', 'push_pop']

.. _property-invalid-mutation:

Invalid-input mutation
-------------------------

Use for a parser or protocol checker, to prove each rejection rule is actually enforced, one rule at a
time.

**What Hypothesis generates.** A well-formed packet, then one of six mutations: ``none``, or a single
semantic rule broken (``bad_magic``, ``wrong_length``, ``bad_checksum``, ``truncation``, or
``invalid_reserved_bit``).

The mutation kinds belong to this packet format. For another design, write one mutation per
rejection rule it has, such as a bad stop bit for a UART receiver.

**The property.** The parser accepts exactly when the packet is exactly valid, and rejects for every
mutated one; a valid packet that never finishes is a lockup. A mutated packet that leaves the parser
waiting counts as rejected, so the testbench reports ``timed_out and not passed``: a timeout only when
the example also failed.

**Why not plain random stimulus.** A packet built entirely at random is rejected for many unrelated
reasons at once, drowning out the rule under test; starting from a valid packet and mutating exactly
one rule isolates which check is broken.

**What it shrinks.** The packet (payload length, byte values) and, separately, which single mutation is
applied.

**Bugs it finds.** Parser bugs that only show on one specific malformed input, such as a rejection rule
that is never actually checked.

VHDL (testbench):

.. literalinclude:: ../../examples/property/tb_property_corruption.vhd
   :caption: examples/property/tb_property_corruption.vhd
   :language: vhdl
   :start-after: -- docs-start: invalid_packet_mutation
   :end-before: -- docs-end: invalid_packet_mutation
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/corruption_strategies.py
   :caption: examples/property/python/corruption_strategies.py
   :language: python
   :start-after: # docs-start: packet_mutation
   :end-before: # docs-end: packet_mutation

``inject_bug`` makes ``packet_parser`` skip the reserved-bits check. The counterexample it shrinks to:

.. code-block:: text

   {'packet': [165, 0, 2, 167], 'mutation': 'invalid_reserved_bit', 'valid': False}

.. _property-axi-ready:

AXI4-Stream TVALID must not wait for TREADY
-----------------------------------------------

Use to check whether an output's timing depends on a downstream ready signal it must not wait for, on
any source, sink or pipeline stage that claims a streaming handshake.

A black-box AXI4-Stream interface cannot tell "no data" from "data waiting illegally for TREADY" just by
watching TVALID and TREADY on one run. ``test_tready_fork`` runs two identical copies of the same
source, ``axis_word_source``, side by side with the same clock, reset, load and data. At the fork cycle
both copies have TVALID low; copy A then sees TREADY held low for that one cycle while copy B sees
it high, and both are low again after. If the two copies' TVALID histories ever diverge after that, the
divergence can only be caused by that one TREADY cycle, so TVALID depended on TREADY. This is a check of
one behaviour on this example source, not a proof of AXI4-Stream compliance.

**What Hypothesis generates.** How many idle cycles precede the load, which case the fork falls in
(``before_load`` or ``pending_window``), the fork cycle itself, and how many cycles to watch afterwards.

**The property.** One cycle of TREADY must not change TVALID: the two copies' TVALID, TDATA and
handshake histories must stay identical (``test_tready_fork``). A second, stronger test case,
``test_known_pending``, checks that once a word is known to be pending, TVALID rises the very next
cycle and stays high, whatever TREADY does.

**Why not plain random stimulus.** A single run can't separate "TVALID is low because nothing is
pending" from "TVALID is low because it is waiting for TREADY"; the paired fork turns that into a
property with no expected value, by comparing two runs that must not differ.

**What it shrinks.** The idle offset before the load, the fork cycle and the window length.

**Bugs it finds.** Handshake bugs where an output improperly depends on the peer's readiness, such as
TVALID waiting for TREADY instead of following the pending word.

VHDL (testbench), the TREADY fork itself:

.. literalinclude:: ../../examples/property/tb_property_axi_ready.vhd
   :caption: examples/property/tb_property_axi_ready.vhd
   :language: vhdl
   :start-after: -- docs-start: fork
   :end-before: -- docs-end: fork
   :dedent: 8

VHDL (testbench), the property loop of ``test_tready_fork``:

.. literalinclude:: ../../examples/property/tb_property_axi_ready.vhd
   :caption: examples/property/tb_property_axi_ready.vhd
   :language: vhdl
   :start-after: -- docs-start: tready-fork
   :end-before: -- docs-end: tready-fork
   :dedent: 8

Python (strategy module):

.. literalinclude:: ../../examples/property/python/axi_ready_strategies.py
   :caption: examples/property/python/axi_ready_strategies.py
   :language: python
   :start-after: # docs-start: ready-fork
   :end-before: # docs-end: ready-fork

``inject_bug`` makes ``axis_word_source``'s TVALID wait until TREADY is seen. The counterexamples it
shrinks to:

.. code-block:: text

   test_tready_fork:
   {'data': 0, 'idle': 0, 'case': 'pending_window', 'fork': 1, 'window': 3}
   -- READY_A 00000, READY_B 01000, VALID_A 00000, VALID_B 00111, first divergence at cycle 2

   test_known_pending:
   {'data': 0, 'idle': 0, 'case': 'before_load', 'fork': 0, 'window': 3}
   -- TVALID never rises

Related recipes
-----------------

* :doc:`../cookbook/property_testing`

API reference
---------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`
