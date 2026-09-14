Property-based testing in simulation
====================================

A property is a statement that must hold for every input. Instead of writing the inputs, you
describe them with a `Hypothesis <https://hypothesis.readthedocs.io>`_ strategy, a plain Python
function, and ``property_pkg`` runs the design with the examples Hypothesis draws, all inside one
simulation. When an example fails, Hypothesis shrinks it to a minimal counterexample by running more
examples through the same loop.

The package does not depend on Hypothesis; install it where the simulation runs:

.. code-block:: bash

   pip install hypothesis

The examples are in ``examples/property``; run them with ``python examples/property/run.py``. The
strategies are the functions of ``examples/property/python/strategies.py``, and most examples are
test cases of ``tb_property_examples.vhd``, which shares an ALU and a register bank between them.

A first property
----------------

The strategy returns a Hypothesis strategy:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: scalar

The testbench loops over the examples: read the example, simulate, report the verdict, and check the
property when the loop ends.

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: scalar
   :end-before: -- docs-end: scalar
   :dedent: 8

``new_property`` names the strategy as ``"module:function"`` and ``search_path`` makes the module
importable; the example's ``new_example`` passes ``get_seed(runner_cfg)`` so the examples follow
VUnit's seed and ``output_path(runner_cfg)`` to journal and replay them (see below).

Reading composite examples
--------------------------

An example can be any combination of dicts, dataclasses, named tuples, lists, tuples, binary data,
integers, booleans and strings. VHDL reads a value through a path: field names joined by dots and
indexes in parentheses, as in ``"frames(2).payload"``. The empty path is the whole example.

.. list-table::
   :header-rows: 1

   * - Getter
     - Returns
   * - ``get_integer(prop, path)``
     - an integer
   * - ``get_boolean(prop, path)``
     - a boolean
   * - ``get_string(prop, path)``
     - a string, or the lower-case name of an ``Enum`` member
   * - ``get_integer_vector(prop, path)``
     - the items of a list, tuple or binary value, in one bridge call
   * - ``get_unsigned(prop, path, length)``
     - an unsigned integer, or a binary value read big-endian, as ``length`` bits
   * - ``get_length(prop, path)``
     - the number of items of a list, tuple or binary value
   * - ``has_field(prop, path)``
     - whether an optional field exists and is not None

A wrong path fails with a message that names the fields that exist, for example
``'confg.lanes': the example has no field 'confg'; its fields are config, frames, vlan``.

A record with a list:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: composite

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: composite
   :end-before: -- docs-end: composite
   :dedent: 8

A tagged union, where each kind of example has fields of its own:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: tagged_union

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: tagged_union
   :end-before: -- docs-end: tagged_union
   :dedent: 8

Stateful properties
-------------------

A design with state is tested with sequences of steps. Return a
``hypothesis.stateful.RuleBasedStateMachine`` subclass instead of a strategy: its rules keep a
reference model in Python and run each step in VHDL with ``step(rule, **fields)``, which returns the
value VHDL reports. Hypothesis shrinks a failure to the shortest failing sequence of steps.

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: Registers

The testbench dispatches on ``get_rule(prop)``, reads the arguments of the rule by name and answers
with ``report_step(prop, value)``. Every sequence starts with the rule ``"start"``, where the
design is reset. The register bank of the example loses writes to address 5, and the property finds
that:

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: stateful
   :end-before: -- docs-end: stateful
   :dedent: 8

``get_counterexample`` then gives ``write(address=5, data=1); read(address=5)``.

Records from Python dataclasses
-------------------------------

Instead of reading field by field, describe the data once as frozen dataclasses. Bounds are markers
in ``typing.Annotated``: ``Range(min, max)`` for integers, ``Length(max=..., min=...)`` for strings,
binary values and lists, and ``Choices(...)`` for a fixed set of integers or strings.
``strategy_for`` turns the dataclasses into a Hypothesis strategy and ``validate`` checks a value
against the bounds.

.. literalinclude:: ../examples/property/python/example_records.py
   :language: python
   :pyobject: Pair

The run script generates a VHDL package from the dataclasses, rewriting it only when it changes:

.. literalinclude:: ../examples/property/run.py
   :language: python
   :start-after: # docs-start: generate
   :end-before: # docs-end: generate

The package has a record type ``<name>_t``, a getter ``get_<name>(prop, path)`` and
``to_string(value)`` for every dataclass, so a test reads a whole example with one call:

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: generated_record
   :end-before: -- docs-end: generated_record
   :dedent: 8

The same package can be generated from the command line:

.. code-block:: bash

   python -m awesome_vunit_vcs.gen_vhdl example_records:Pair --package example_records_pkg \
     --output example_records_pkg.vhd

.. list-table:: Type mapping
   :header-rows: 1

   * - Python field
     - VHDL record element
   * - ``bool``
     - ``boolean``
   * - ``int`` with ``Range`` or ``Choices``; without a marker the whole integer range
     - ``integer range <min> to <max>``
   * - ``str`` with ``Length`` or ``Choices``, printable ASCII
     - ``string(1 to <max>)`` and ``<field>_length``
   * - a binary value with ``Length``, and ``list[int]`` with ``Length``
     - ``integer_vector(0 to <max> - 1)`` and ``<field>_length``, read in one bridge call
   * - ``list`` of ``bool``, an ``Enum`` or a dataclass, with ``Length``
     - ``<record>_<field>_array_t`` and ``<field>_length``
   * - an ``Enum``
     - an enumeration type of the member names in lower case
   * - a dataclass
     - its record type
   * - ``T | None``
     - the element of ``T`` and ``has_<field> : boolean``

Records have fixed capacities, so they can be signals and be compared and assigned; a maximum length
of 0 still reserves one item. The examples do not commit the generated package: the run scripts
generate it at build time, and golden-file tests guard the generator.

Everything else raises ``RecordError`` naming the class and the field:

* ``float``, ``dict``, ``tuple``, ``set`` and other types: ``WithFloat.speed: float is not
  supported; supported are bool, int with Range or Choices, ...``
* strings, binary values and lists without ``Length``: ``a str field needs Length(max=...) or
  Choices, since a VHDL record has a fixed size``
* unions other than ``T | None``, and nested optionals: ``... is a union; only Optional[...] unions
  are supported``
* lists of strings, binary values, lists or optionals: ``list items of kind str are not supported``
* a marker on a type it does not apply to: ``Range does not apply to a bool field``
* names that are not VHDL identifiers or are reserved words, such as a field named ``range`` or an
  enum member ``IN``: ``Field WithReservedField.range 'range' is a VHDL reserved word``
* generated names that collide, such as a field ``items_length`` next to a field ``items``, or a
  class whose getter would shadow ``property_pkg``, such as ``Integer``

Ethernet frames
---------------

``tb_property_ethernet.vhd`` has a testbench of its own, since it instantiates the GMII source and
monitor. Every frame the source sends, the monitor must receive unchanged:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: frame_data

.. literalinclude:: ../examples/property/tb_property_ethernet.vhd
   :language: vhdl
   :start-after: -- docs-start: ethernet
   :end-before: -- docs-end: ethernet
   :dedent: 4

The typed Python API of the Ethernet VCs (``Frame``, ``WireOptions``, ``Malformation``,
``expected_violations``) gives strategies for malformed traffic and the violations a protocol checker
must count.

Lockups
-------

An example can make a design lock up. Wait for the design with a simulation-time budget and report a
missed deadline with ``timed_out``: Hypothesis treats a lockup and wrong behavior as different
failures, so shrinking a lockup does not slip into another bug. ``example_budget(base, per_item,
items)`` scales a budget with the example. Reset the design after a lockup and report whether it
works again as ``recovered``; a design that does not recover ends the property as aborted, with the
smallest failing example found so far.

``tb_property_lockup.vhd`` has a testbench of its own, with a sink that stops taking octets after
0xFF. The property found the lockup and shrank it to ``[255, 0]``, which its strategy now pins (see
`Regressions and budgets`_):

.. literalinclude:: ../examples/property/tb_property_lockup.vhd
   :language: vhdl
   :start-after: -- docs-start: lockup
   :end-before: -- docs-end: lockup
   :dedent: 4

Examples must be independent. Reset the design, and every verification component that keeps state
(``reset`` of the Ethernet VCs), before each example. A property whose example fails once and passes
when repeated is reported as flaky, which usually means state leaked between examples.

Scores
------

``report_score(prop, name, value)`` reports a score of the current example before its verdict, for
example the fill level a FIFO reached. It is forwarded to ``hypothesis.target``, which steers
generation towards higher scores, so rare corner cases are reached sooner. Report each name at most
once per example.

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: score
   :end-before: -- docs-end: score
   :dedent: 8

Metamorphic properties
----------------------

When the expected result is hard to compute, check a relation between two runs instead: the same
design with a transformed input must give a related output. Both runs belong to one example:

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: metamorphic
   :end-before: -- docs-end: metamorphic
   :dedent: 8

Timing
------

Draw the timing of an example, such as idle cycles between operations or where a reset lands,
separately from its data. Hypothesis then shrinks the two on their own, so a counterexample shows the
smallest data together with the simplest timing that still fails:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: timed_writes

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: timing
   :end-before: -- docs-end: timing
   :dedent: 8

Swarm testing
-------------

A strategy that mixes every kind of operation in every example can hide a bug that needs many of one
kind. Swarm testing first draws which kinds an example enables, then draws operations of those kinds
only:

.. literalinclude:: ../examples/property/python/strategies.py
   :language: python
   :pyobject: swarm

.. literalinclude:: ../examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: swarm
   :end-before: -- docs-end: swarm
   :dedent: 8

Regressions and budgets
-----------------------

* **Pins.** Decorate a strategy function with ``@pin(example, ...)`` from
  ``awesome_vunit_vcs.common.property`` to try those examples first on every run, like
  ``hypothesis.example``. Pin a counterexample once it is found, and it stays a regression test.
* **Profiles.** ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=quick``, the default, runs ``max_examples``
  examples; ``long`` runs ten times as many. Pull request CI runs the quick profile and a nightly
  workflow the long one.
* **Saved failures in CI.** CI keeps ``property_failures/`` in the Actions cache between runs, so a
  failure one run found is tried first by the next. Locally, rerun with the same ``--output-path``
  and the saved failure is replayed first; the seed VUnit printed repeats the other examples.

Seeds, journals and replay
--------------------------

* **Seed.** ``seed => get_seed(runner_cfg)`` makes the examples follow VUnit's seed: rerunning a test
  with the seed VUnit printed repeats its examples.
* **Journal.** With ``output_path``, each example is written to ``property_journal_<name>.jsonl`` in
  the test output path before it runs, so the input that crashed a simulation or hit the watchdog is
  known.
* **Replay.** The smallest failing example is saved next to the output path, which VUnit clears on
  every run, in ``property_failures/``, and replayed first on the next run. Hypothesis's own example
  database is not used, because a seeded Hypothesis test does not use it.
* **Timeouts.** Hypothesis's deadline is disabled; the simulation-time budget of the testbench is the
  only timeout that matters.

Limitations
-----------

* Simulation time grows with the number of examples, and shrinking runs more examples. Keep examples
  short and set ``max_examples`` to what the design needs.
* Each getter is a call through the Python bridge, about 20 µs on NVC: reading 50 fields per example
  added 0.2 s to 200 examples, which took 0.6 s without reads. ``get_integer_vector`` reads a whole
  vector in one call, and a generated record getter makes one call per scalar field.
* Saved failures and pins are for strategies. A stateful property replays its failing sequence
  through its seed, not through a saved file.
* A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.
