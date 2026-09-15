Records from Python dataclasses
===============================

Instead of reading field by field, describe the data once as frozen dataclasses. Bounds are markers
in ``typing.Annotated``: :class:`Range(min, max) <awesome_vunit_vcs.records.Range>` for integers,
:class:`Length(max=..., min=...) <awesome_vunit_vcs.records.Length>` for strings, binary values and
lists, and :class:`Choices(...) <awesome_vunit_vcs.records.Choices>` for a fixed set of integers or
strings. :func:`~awesome_vunit_vcs.records.strategy_for` turns the dataclasses into a Hypothesis
strategy and :func:`~awesome_vunit_vcs.records.validate` checks a value against the bounds.

.. include:: ../_includes/vunit_names.inc

.. literalinclude:: ../../examples/property/python/example_records.py
   :caption: examples/property/python/example_records.py
   :language: python
   :pyobject: Pair

The run script generates a VHDL package from the dataclasses with
:func:`~awesome_vunit_vcs.gen_vhdl.write_vhdl`, rewriting it only when it changes:

.. literalinclude:: ../../examples/property/run.py
   :caption: examples/property/run.py
   :language: python
   :start-after: # docs-start: generate
   :end-before: # docs-end: generate

The package has a record type ``<name>_t``, a getter ``get_<name>(prop, path)`` and
``to_string(value)`` for every dataclass, so a test reads a whole example with one call. The snippet uses
the testbench helpers :ref:`apply <property-helper-apply>` and :ref:`new_example <property-helper-new-example>`:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: generated_record
   :end-before: -- docs-end: generated_record
   :dedent: 8

The same package can be generated from the command line:

.. code-block:: bash
   :caption: Terminal

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
