Contributing
============

Contributions are welcome: new verification component (VC) families, new interfaces for an existing
family, bug fixes and documentation. This guide describes how the repository is organized and what a
change needs before it can be merged.

.. toctree::
   :maxdepth: 1

   new_family
   conventions
   releasing

Follow the core rule
--------------------

**VHDL handles simulation timing. Python handles verification semantics.**

VHDL samples and drives pins at the right simulation edges and exchanges batched observations with a
Python backend object. Python never accesses simulator signals and never schedules simulation time. A
VHDL user controls a component through VHDL procedures only; Python-specific features are additive.
`ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md>`__ explains the boundary and
the reasons for it.

Set up a development environment
--------------------------------

The package depends on two unreleased packages: a VUnit with package setup hooks and
vunit-python-bridge. ``tests/packaging/unreleased-requirements.txt`` pins both to tested commits.

.. code-block:: bash
   :caption: Terminal

    git clone https://github.com/ru551n/awesome-vunit-vcs.git
    cd awesome-vunit-vcs
    python -m venv .venv
    source .venv/bin/activate
    pip install -r tests/packaging/unreleased-requirements.txt
    pip install -e ".[dev,reference]"

On Linux and macOS the bridge compiles its simulator library on first use, so a C compiler and the
Python development headers (for example ``python3-dev``) are needed. Install GHDL, NVC or both for
the HDL tests.

Run the checks
--------------

These are the checks CI runs. A pull request must pass all of them.

.. code-block:: bash
   :caption: Terminal

    ruff check .                                   # lint
    ruff format --check .                          # formatting, including code blocks in Markdown
    mypy                                           # strict type checking
    vsg-rs $(git ls-files "*.vhd" ":!:tests/python/golden") -c vsg.yaml   # VHDL style, add --fix to format
    pytest                                         # Python unit tests
    VUNIT_SIMULATOR=ghdl python tests/vhdl/run.py --output-path ../vunit_out -p 2
    VUNIT_SIMULATOR=nvc python tests/vhdl/run.py --output-path ../vunit_out -p 2
    pytest tests/packaging                         # slow: builds and installs the wheel

The documentation is built with warnings as errors:

.. code-block:: bash
   :caption: Terminal

    pip install -r docs/requirements.txt
    sphinx-build -W --keep-going -b html docs docs/_build

The bridge benchmark is not part of CI; see `ARCHITECTURE.md <https://github.com/ru551n/awesome-vunit-vcs/blob/main/ARCHITECTURE.md#performance>`__.

Make commits and pull requests
------------------------------

* Keep commits atomic, each with a message that says what changed and why.
* Every commit on ``main`` passes the checks above.
* A change that users can notice gets a release notes entry.
* A new component or interface comes with its documentation page; see the
  :ref:`documentation checklist <documentation-checklist>`.
