Python and VHDL together
========================

Most testbenches never need Python code of their own. The recipes on this page show how to add some
when it helps. They come from :repo-file:`examples/cookbook`.

Choose VHDL or Python
---------------------

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - Write it in VHDL
     - Write it in Python
   * - Driving and sampling pins, clocks and resets
     - Building complex frames and packets
   * - Deciding *when* something happens
     - Deciding *what* to send or expect
   * - Short directed tests with known frames
     - Reference models and lookup tables
   * - Waiting, timeouts and test structure
     - Long or random traffic, and property-based testing

Use the components without writing Python
-----------------------------------------

**Goal:** verify a design with VHDL only.

**When to use this:** for most tests. The components already reconstruct, check and count frames.

* Start from :doc:`sources` and :doc:`monitors`; none of their recipes needs Python code.

**Full example:** :repo-file:`examples/quickstart/tb_quickstart.vhd`

Call your own Python function
-----------------------------

**Goal:** get a value from a Python function, such as a lookup table.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: call-python
   :end-before: -- docs-end: call-python
   :dedent:

.. literalinclude:: ../../examples/cookbook/python/cookbook_model.py
   :caption: examples/cookbook/python/cookbook_model.py
   :language: python
   :start-after: # docs-start: helper
   :end-before: # docs-end: helper

**When to use this:** when a value is easier to compute in Python than in VHDL.

* Import the file once with ``import_module_from_file``, then call its functions by ``module.function``.
* Pass arguments with ``arg`` and ``kwarg``; pick the call that matches the result, such as ``call``
  for an integer or ``call_integer_vector`` for a list.

**Full example:** ``test_call_a_python_function``

.. code-block:: console

   $ python examples/cookbook/run.py "*test_call_a_python_function"

**See also:** `Calling Python from VHDL <https://github.com/ru551n/vunit-python-bridge>`__

Check against a Python reference model
--------------------------------------

**Goal:** let Python predict a result and check it in VHDL.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: reference-model
   :end-before: -- docs-end: reference-model
   :dedent:

.. literalinclude:: ../../examples/cookbook/python/cookbook_model.py
   :caption: examples/cookbook/python/cookbook_model.py
   :language: python
   :start-after: # docs-start: model
   :end-before: # docs-end: model

**When to use this:** when the expected result follows rules that are awkward to write in VHDL.

* Keep the model a plain function, so you can unit test it without a simulator.
* To check every received frame in Python instead, use a subscriber; see the next recipe.

**Full example:** ``test_python_reference_model``

Run Python on every received frame
----------------------------------

**Goal:** check frames with Python code in a monitor's session.

**When to use this:** when each frame needs a Python check, such as a scoreboard or packet decoding.

* Use ``@vc.on_frame`` for the check.
* Report problems with ``vc.error(check, message)``, so negative tests can count them.

**Full example:** :repo-file:`examples/gmii/python/frame_sizes.py` and ``test_python_subscriber`` in
:repo-file:`examples/gmii/tb_gmii_example.vhd`

**See also:** :doc:`../ethernet/python`, :doc:`../ethernet/monitors`

Generate traffic in Python with VUnit's seed
--------------------------------------------

**Goal:** send random traffic that repeats exactly for the same seed.

**When to use this:** for long or random traffic you want to replay after a failure.

* Pass ``get_string_seed(runner_cfg)`` to both the source and the monitor.

**Full example:** *Send a reproducible random sequence* in :doc:`sources`

Share data structures between Python and VHDL
---------------------------------------------

**Goal:** define a record once as a Python dataclass and read it in VHDL.

**When to use this:** when Python generates structured data that many tests read.

**Full example:** *Use a record from a Python dataclass* in :doc:`properties`

**See also:** :doc:`../property_testing/records`

Find bugs with property-based testing
-------------------------------------

**Goal:** let Hypothesis generate inputs and find the smallest one that fails.

**When to use this:** when a rule should hold for every input.

**Full example:** :doc:`properties`

Keep the Python files next to the testbench
-------------------------------------------

**Goal:** make Python files importable without hardcoded paths.

.. literalinclude:: ../../examples/cookbook/run.py
   :caption: examples/cookbook/run.py
   :language: python
   :start-after: # docs-start: python-path
   :end-before: # docs-end: python-path

**When to use this:** when a testbench names Python functions, such as in ``push_ethernet_packet``.

* Put the Python files in a ``python`` directory next to the testbench.
* Build paths from ``tb_path(runner_cfg)`` in VHDL, as in *Call your own Python function*.

**Full example:** :repo-file:`examples/cookbook/run.py`

Unit test the Python part
-------------------------

**Goal:** test models and traffic functions with ``pytest``, without a simulator.

.. literalinclude:: ../../examples/cookbook/python/test_cookbook_model.py
   :caption: examples/cookbook/python/test_cookbook_model.py
   :language: python
   :start-after: # docs-start: unit-test
   :end-before: # docs-end: unit-test

**When to use this:** for every Python file a testbench uses. A unit test fails in seconds.

.. code-block:: console

   $ PYTHONPATH=examples/cookbook/python pytest examples/cookbook/python

**Full example:** :repo-file:`examples/cookbook/python/test_cookbook_model.py`

Do and don't
------------

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - Do
     - Don't
   * - Pass arguments with ``arg`` and ``kwarg``
     - Build Python code as strings
   * - Keep Python functions free of simulator signals
     - Read or drive signals from Python
   * - Pass seeds explicitly
     - Use unseeded random numbers
   * - Report problems with ``vc.error``
     - Raise exceptions for expected errors
   * - Keep state in the component's backend or your own module
     - Share global variables between components
