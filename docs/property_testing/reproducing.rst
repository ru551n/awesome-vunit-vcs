Reproduce failures
==================

Pin known failures and set budgets
----------------------------------

* **Pins.** Decorate a strategy function with ``@pin(example, ...)`` from
  ``awesome_vunit_vcs.common.property`` to try those examples first on every run, like
  ``hypothesis.example``. Pin a counterexample once it is found, and it stays a regression test.
* **Profiles.** ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=quick``, the default, runs ``max_examples``
  examples; ``long`` runs up to ten times as many. Hypothesis stops earlier when a strategy has fewer
  distinct examples than that, such as one byte. Pull request CI runs the quick profile and a nightly
  workflow the long one.
* **Saved failures in CI.** CI keeps ``property_failures/`` in the Actions cache between runs, so a
  failure one run found is tried first by the next. Locally, rerun with the same ``--output-path``
  and the saved failure is replayed first; the seed VUnit printed repeats the other examples.

Replay a failure
----------------

* **Seed.** ``seed => get_seed(runner_cfg)`` makes the examples follow VUnit's seed: rerunning a test
  with the seed VUnit printed repeats its examples.
* **Journal.** With ``output_path``, each example is written to ``property_journal_<name>.jsonl`` in
  the test output path before it runs, so the input that crashed a simulation or hit the watchdog is
  known.
* **Replay.** The smallest failing example is saved in ``<output-path>/test_output/property_failures/``
  and replayed first on the next run with the same ``--output-path``.
* **Timeouts.** Hypothesis's deadline is disabled; the simulation-time budget of the testbench is the
  only timeout that matters.

.. _expect-a-failure:

Expect a failure
----------------

``check_property`` is what fails a test when a property failed. A test that expects a failure, for
example to prove that a planted bug is found, doesn't call it. It reads the result with ``get_outcome``
and ``get_counterexample`` instead:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: expect-failure
   :end-before: -- docs-end: expect-failure
   :dedent:

Without ``check_property`` and without these checks, a failing property doesn't fail the test.

Good to know
------------

* Simulation time grows with the number of examples, and shrinking runs more examples. Keep examples
  short and set ``max_examples`` to what the design needs.
* Every getter is a call to Python. ``get_integer_vector`` reads a whole
  vector in one call, and a generated record getter makes one call per scalar field.
* Saved failures and pins are for strategies. A stateful property replays its failing sequence
  through its seed, not through a saved file.
* A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.

Related recipes
---------------

* :doc:`../cookbook/property_errors`: *Keep a bug from coming back*

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`
