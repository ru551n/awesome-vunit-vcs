Reproduce failures
==================

Pin known failures and set budgets
----------------------------------

* **Pins.** Decorate a strategy function with ``@pin(example, ...)`` from
  ``awesome_vunit_vcs.common.property`` to try those examples first on every run, like
  ``hypothesis.example``. Pin a counterexample once it is found, and it stays a regression test.
* **Profiles.** ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=quick``, the default, runs ``max_examples``
  examples; ``long`` runs ten times as many. Pull request CI runs the quick profile and a nightly
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
* **Replay.** The smallest failing example is saved next to the output path, which VUnit clears on
  every run, in ``property_failures/``, and replayed first on the next run.
* **Timeouts.** Hypothesis's deadline is disabled; the simulation-time budget of the testbench is the
  only timeout that matters.

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
