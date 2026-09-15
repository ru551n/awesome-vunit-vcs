Reproduce failures
==================

Pin known failures and set budgets
----------------------------------

* **Pins.** Decorate a strategy function with ``@pin(example, ...)`` from
  ``awesome_vunit_vcs.common.property`` to try those examples first on every run, like
  ``hypothesis.example``. Pin a counterexample once it is found, and it stays a regression test.
  Pinned examples run in addition to ``max_examples``: 100 examples and one pin run 101.
* **Profiles.** A property without ``max_examples`` runs 100 examples with
  ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=quick``, the default, and 1000 with ``long``. A property that
  sets ``max_examples`` runs that many in every profile, so set it only where a property needs a fixed
  budget. Hypothesis stops earlier when a strategy has fewer distinct examples, such as one byte. Pull
  request CI runs the quick profile and a nightly workflow the long one.
* **Saved failures in CI.** CI keeps ``property_failures/`` in the Actions cache between runs, so a
  failure one run found is tried first by the next.

Replay a failure
----------------

* **Seed.** ``seed => get_seed(runner_cfg)`` makes the examples follow VUnit's seed: rerunning a test
  with the seed VUnit printed repeats its examples.
* **Journal.** With ``output_path``, each example is written to ``property_journal_<name>.jsonl`` in
  the test output path before it runs, so the input that crashed a simulation or hit the watchdog is
  known. Each line is a JSON object of one of two kinds:

  .. list-table::
     :header-rows: 1
     :widths: 30 70

     * - Line
       - Fields
     * - An example, before it runs
       - ``index``, counting from 1; ``example``, the example as Python shows it; ``seed``, the seed the
         testbench gave ``new_property``
     * - Its verdict, after ``report_example``
       - ``index``, the same number; ``verdict``: ``passed``, ``failed``, ``timed out`` or
         ``did not recover``; ``message``, the message the testbench passed to ``report_example``, empty
         when it passed none

  The last example without a verdict is the one that crashed or hung. ``get_seed(runner_cfg)`` derives
  the ``seed`` field from the seed VUnit printed, so the two look different: rerun with VUnit's printed
  seed, ``--seed <printed seed>``, not with the journal's.
* **Replay.** The smallest failing example is saved in ``<output-path>/test_output/property_failures/``.
  The file name is the test's output directory name (the test name and a hash), a dot, and the property
  name with ``:`` written as ``_``, for example ``lib.tb_fail.all_<hash>.tb_fail_sum.txt`` for the id
  ``tb_fail:sum``. The failure message prints the exact path. The file holds one line with the
  example as Python writes it, such as ``200`` or ``[64, 0, 0]``. The next run with the same
  ``--output-path`` tries it first. If it still fails, the property ends right there, after that one
  example, so you see at once whether a fix works. To repeat the whole search instead, rerun with the
  seed VUnit printed and a new ``--output-path``.
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

A strategy with a bug is different: the property can't run, so it ends with the outcome ``error`` and
logs one ``failure`` on its logger, whose first line names your strategy function and the line in your
code. To expect that, give ``new_property`` a logger, allow failures on it and count them:

.. literalinclude:: ../../examples/property/tb_property_examples.vhd
   :caption: examples/property/tb_property_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: expect-strategy-error
   :end-before: -- docs-end: expect-strategy-error
   :dedent:

Good to know
------------

* Simulation time grows with the number of examples, and shrinking runs more examples. Keep examples
  short and set ``max_examples`` to what the design needs.
* Every getter is a call to Python. ``get_integer_vector`` reads a whole
  vector in one call, and a generated record getter makes one call per scalar field.
* Saved failures and pins are for strategies. A stateful property replays its failing sequence
  through its seed, not through a saved file.
* For a stateful property, ``max_examples`` is the number of step sequences, and each sequence runs up
  to 50 steps. ``get_example_count`` counts steps, the ``"start"`` steps included, so ``max_examples
  => 20`` gives roughly 1000.
* A path reaches fields by name only for dicts with string keys, dataclasses and named tuples.

Related recipes
---------------

* :doc:`../cookbook/property_errors`: *Keep a bug from coming back*

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`
