Property-based testing in simulation
====================================

A property is a statement that must hold for every input: "the checksum of every packet is the sum
of its octets modulo 256". Instead of writing the inputs, you describe them with a
`Hypothesis <https://hypothesis.readthedocs.io>`_ strategy, a plain Python function, and
``property_pkg`` runs the design with the examples Hypothesis draws, all inside one simulation.
When an example fails, Hypothesis shrinks it to a minimal counterexample by running more examples
through the same loop, so a failure is reported as the smallest input that still fails.

The package does not depend on Hypothesis; install it where the simulation runs:

.. code-block:: bash

   pip install hypothesis

A first property
----------------

The strategy is a Python function returning a Hypothesis strategy:

.. literalinclude:: ../examples/property/python/property_examples.py
   :language: python
   :start-after: # docs-start: integer
   :end-before: # docs-end: integer

The testbench loops over the examples: read the example, simulate, report the verdict, and check
the property when the loop ends.

.. literalinclude:: ../examples/property/tb_integer_property.vhd
   :language: vhdl
   :start-after: -- docs-start: integer_loop
   :end-before: -- docs-end: integer_loop
   :dedent: 8

``new_property`` names the strategy as ``"module:function"``; ``search_path`` makes the module
importable. Pass VUnit's ``get_seed(runner_cfg)`` so the examples follow VUnit's seed, and
``output_path(runner_cfg)`` to journal the examples and replay failures (see below). The complete
example is ``examples/property``; run it with ``python examples/property/run.py``.

Reading composite examples
--------------------------

An example can be any combination of dicts, dataclasses, named tuples, lists, tuples, binary data,
integers, booleans and strings. VHDL reads a value through a path: names of fields joined by dots
and indexes in parentheses, as in ``"frames(2).payload"``. The empty path is the whole example.

.. list-table::
   :header-rows: 1

   * - Getter
     - Returns
   * - ``get_integer(prop, path)``
     - an integer
   * - ``get_boolean(prop, path)``
     - a boolean
   * - ``get_string(prop, path)``
     - a string
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

A record of configuration fields:

.. literalinclude:: ../examples/property/python/property_examples.py
   :language: python
   :start-after: # docs-start: record
   :end-before: # docs-end: record

.. literalinclude:: ../examples/property/tb_record_property.vhd
   :language: vhdl
   :start-after: -- docs-start: record_loop
   :end-before: -- docs-end: record_loop
   :dedent: 8

A tagged union, where each kind of example has fields of its own:

.. literalinclude:: ../examples/property/python/property_examples.py
   :language: python
   :start-after: # docs-start: tagged_union
   :end-before: # docs-end: tagged_union

.. literalinclude:: ../examples/property/tb_tagged_union_property.vhd
   :language: vhdl
   :start-after: -- docs-start: tagged_union_loop
   :end-before: -- docs-end: tagged_union_loop
   :dedent: 8

Sequences and reference models
------------------------------

A stateful design is tested with sequences of operations. The strategy runs a reference model in
Python and adds the result each operation must give, so the testbench only compares:

.. literalinclude:: ../examples/property/python/property_examples.py
   :language: python
   :start-after: # docs-start: operations
   :end-before: # docs-end: operations

.. literalinclude:: ../examples/property/tb_register_sequence_property.vhd
   :language: vhdl
   :start-after: -- docs-start: operations_loop
   :end-before: -- docs-end: operations_loop
   :dedent: 6

With a planted bug in the register bank, a write to register 3 that also writes register 7,
Hypothesis shrinks the up to 20 generated operations to the minimal failing sequence:
``[{'kind': 'write', 'address': 3, 'data': 1}, {'kind': 'read', 'address': 7, 'expected': 0}]``.

Ethernet traffic
----------------

The typed Python API of the Ethernet VCs (``Frame``, ``WireOptions``, ``Malformation``,
``expected_violations``) makes Ethernet properties short. This one sends random, sometimes
malformed, frames through a design and checks that the protocol checker counts exactly the
predicted violations:

.. literalinclude:: ../examples/property/python/property_examples.py
   :language: python
   :start-after: # docs-start: ethernet
   :end-before: # docs-end: ethernet

.. literalinclude:: ../examples/property/tb_ethernet_property.vhd
   :language: vhdl
   :start-after: -- docs-start: ethernet_loop
   :end-before: -- docs-end: ethernet_loop
   :dedent: 8

Records from Python dataclasses
-------------------------------

Instead of reading field by field, describe the data of a property once as frozen dataclasses. Bounds
are markers in ``typing.Annotated``: ``Range(min, max)`` for integers, ``Length(max=..., min=...)``
for strings, binary values and lists, ``Choices(...)`` for a fixed set of integers or strings.
``strategy_for`` turns the dataclasses into a Hypothesis strategy and ``validate`` checks a value
against the bounds.

.. literalinclude:: ../examples/property/python/register_records.py
   :language: python
   :start-after: # docs-start: register_records
   :end-before: # docs-end: register_records

The run script generates a VHDL package from the dataclasses, rewriting it only when it changes:

.. literalinclude:: ../examples/property/run.py
   :language: python
   :start-after: # docs-start: generate
   :end-before: # docs-end: generate

The package has a record type ``<name>_t``, a getter ``get_<name>(prop, path)`` and
``to_string(value)`` for every dataclass, so the testbench reads a whole example with one call:

.. literalinclude:: ../examples/property/tb_register_records_property.vhd
   :language: vhdl
   :start-after: -- docs-start: register_records_loop
   :end-before: -- docs-end: register_records_loop
   :dedent: 6

The same package can be generated from the command line:

.. code-block:: bash

   python -m awesome_vunit_vcs.gen_vhdl register_records:OperationSequence \
     --package register_records_pkg --output register_records_pkg.vhd

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
of 0 still reserves one item. The generated package is not committed in the examples: the run
scripts generate it at build time, and golden-file tests guard the generator.

Everything else raises ``RecordError`` naming the class and the field:

* ``float``, ``dict``, ``tuple``, ``set`` and other types, for example
  ``WithFloat.speed: float is not supported; supported are bool, int with Range or Choices, ...``
* ``str``, binary values and lists without ``Length``:
  ``a str field needs Length(max=...) or Choices, since a VHDL record has a fixed size``
* unions other than ``T | None``, and nested optionals: ``... is a union; only Optional[...] unions
  are supported``
* lists of strings, binary values, lists or optionals: ``list items of kind str are not supported``
* a marker on a type it does not apply to: ``Range does not apply to a bool field``
* names that are not VHDL identifiers or are reserved words, such as a field named ``range`` or an
  enum member ``IN``: ``Field WithReservedField.range 'range' is a VHDL reserved word``
* generated names that collide, such as a field ``items_length`` next to a field ``items``, or a
  class whose getter would shadow ``property_pkg``, such as ``Integer``

Lockups
-------

An example can make a design lock up. Wait for the design with a simulation-time budget, and report
a missed deadline with ``timed_out``: Hypothesis treats a lockup and wrong behavior as different
failures, so shrinking a lockup does not slip into a different bug. ``example_budget(base,
per_item, items)`` scales the budget with the example.

Reset the design after a lockup and report whether it works again as ``recovered``. A design that
does not recover ends the property as aborted, with the smallest failing example found so far,
instead of failing every following example.

.. literalinclude:: ../examples/property/tb_byte_vectors_property.vhd
   :language: vhdl
   :start-after: -- docs-start: byte_vectors_loop
   :end-before: -- docs-end: byte_vectors_loop
   :dedent: 8

Examples must be independent. Reset the design, and every verification component that keeps state
(``reset`` of the Ethernet VCs), before each example. A property whose example fails once and
passes when repeated is reported as flaky, which usually means state leaked between examples.

Seeds, journals and replay
--------------------------

* **Seed.** ``seed => get_seed(runner_cfg)`` makes the examples follow VUnit's seed: rerunning a
  test with the seed VUnit printed repeats its examples.
* **Journal.** With ``output_path``, each example is written to
  ``property_journal_<name>.jsonl`` in the test output path before it runs, so the input that
  crashed a simulation or hit the watchdog is known.
* **Replay.** The smallest failing example is saved next to the output path, which VUnit clears on
  every run, in ``property_failures/``, and replayed first on the next run. Hypothesis's own example
  database is not used, because a seeded Hypothesis test does not use it.
* **Timeouts.** Hypothesis's deadline is disabled; the simulation-time budget of the testbench is
  the only timeout that matters.

Limitations
-----------

* Simulation time grows with the number of examples, and shrinking runs more examples. Keep examples
  short and set ``max_examples`` to what the design needs.
* Each getter is a call through the Python bridge; reading a vector with ``get_integer_vector`` is
  one call, whatever its length.
* A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.
