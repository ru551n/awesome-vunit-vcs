Adding a component family or interface
======================================

A family (for example ``i2c``, ``axi`` or ``mdio``) is a Python subpackage plus a VHDL directory.
Ethernet is the reference implementation.

Repository layout
-----------------

.. code-block:: text

    src/awesome_vunit_vcs/
    ├── common/                       shared infrastructure, reused by every family
    │   ├── events.py                 Publisher: sample once, fan out to subscribers
    │   ├── reports.py                reports from a backend to the VHDL logger and checker
    │   └── vunit_bridge.py           sample batch encoding (Python side)
    ├── ethernet/                     simulator independent core and backends
    │   ├── frame.py, checker.py, metrics.py, pcap.py, source.py, ...
    │   ├── phy/                      one decoder and encoder per interface
    │   └── vunit_backend.py          the objects the VHDL components create
    ├── vhdl/
    │   ├── common/vcs_python_pkg.vhd     the only VHDL file that uses the bridge
    │   └── ethernet/
    │       ├── ethernet_pkg.vhd          handles, procedures, message types
    │       ├── ethernet_vc_pkg.vhd       what every monitor and source entity shares
    │       ├── gmii_pkg.vhd              constructors of one interface
    │       ├── gmii_monitor.vhd          pin timing of one interface
    │       ├── gmii_source.vhd
    │       └── ethernet_context.vhd      what a testbench uses
    └── vunit_pkg.toml

A new family
------------

For a new family ``<family>``:

#. **Python core** in ``src/awesome_vunit_vcs/<family>/``. It must be usable from plain Python and
   fully unit tested without a simulator. Prefer dataclasses and explicit types, keep public APIs
   small and avoid global mutable state, since several VC instances run in one interpreter.

#. **Backend** in ``src/awesome_vunit_vcs/<family>/vunit_backend.py``, with one class per VC kind.
   VHDL creates one instance per VC, as the object ``vc`` in a Python session with the identity of
   the VC. Backend methods:

   * take and return what the bridge transfers efficiently: integers, strings, booleans and
     ``integer_array_t`` (NumPy arrays),
   * never let an exception escape into the bridge. They catch it and add a report, as
     ``ethernet/vunit_backend.py`` does, so the failure is logged on the VC logger with a useful
     message instead of a traceback,
   * queue protocol violations as reports (``common/reports.py``) and return the number of reports
     waiting, so VHDL only fetches them when there are some.

#. **VHDL** in ``src/awesome_vunit_vcs/vhdl/<family>/``. ``vunit_pkg.toml`` includes
   ``vhdl/**/*.vhd``, so new files are compiled into the ``awesome_vunit_vcs`` library without
   changing it. Reuse ``vcs_python_pkg``: ``new_vc_session``, ``create_backend``,
   ``backend_exec`` and ``backend_*``, ``log_reports``, and for passive components
   ``new_sample_batch``, ``record_sample`` and ``flush_samples``. Never call the bridge from a family
   package directly; ``vcs_python_pkg`` is where bridge API changes are absorbed.

#. **Batching.** Do not make one bridge call per clock cycle.

   * Passive components record samples only when something changes or data is valid, and flush at
     batch end or when the backend must be up to date (end of a transfer, ``wait_until_idle``). The
     benchmark on :doc:`../explanation/performance` shows why.
   * An active responder whose next output depends on what it just received (a memory model
     answering an opcode, say) may call the bridge once per transfer unit (octet or word), never per
     clock cycle. Measure that cost, and move bulk content through batched procedures such as preload
     and check.

#. **Metavalues.** Map ``X``, ``U``, ``Z``, ``W`` and ``-`` on sampled pins to dedicated bits of the
   sample word and report them. Never silently convert them to ``0``.

#. **Shared infrastructure.** Extract something into ``common/`` only when a second family actually
   needs it.

A new Ethernet interface
------------------------

Adding an interface to the Ethernet family (MII, RGMII and so on) needs:

* a PHY decoder and encoder in ``ethernet/phy/``, registered in ``ethernet/phy/__init__.py``,
* a value of ``ethernet_phy_t``,
* constructors in an ``<interface>_pkg.vhd``,
* the monitor and source entities, built on ``ethernet_vc_pkg``,
* tests, and a documentation page.

Handles, procedures and the Python core are shared. If the common model cannot express the interface,
fix the model first rather than working around it in the frontend.

Test requirements
-----------------

* **Python unit tests** (``tests/python``) for all simulator independent logic. Compare against
  independent references, never against the code under test: ``tests/python/helpers.py`` builds wire
  frames octet by octet with a bitwise CRC-32, and ``test_references.py`` cross-checks against
  cocotbext-eth when it is installed.
* **HDL tests** (``tests/vhdl``) for the bridge and pin behavior, passing on both GHDL and NVC. Use
  VUnit test cases named ``test_*``, ``test_runner_watchdog`` at architecture level and a random
  generator seeded with ``get_string_seed(runner_cfg)`` where stimulus is random.
* **Negative tests** assert violations instead of failing: ``disable_stop(get_logger(vc), error)``,
  then check the violation counts and ``get_log_count``, and ``reset_log_count`` afterwards. An error
  that is not counted still fails the test at ``test_runner_cleanup``.
* **Packaging.** When a change affects what is installed, ``pytest tests/packaging`` must pass: it
  builds the wheel, installs it into a clean environment and runs ``examples/external_project``.

.. _documentation-checklist:

Documentation checklist
-----------------------

A new component or interface is not done until its documentation is. Before opening a pull request:

* **A page per interface** in the user guide of its family, with these sections in order:

  #. Overview: what it models, the standard clause, and the monitor and source in a sentence each.
  #. At a glance: link rates, clocking, symbol width and tested simulators.
  #. Pins: port, direction, type and the standard signal name.
  #. Constructor parameters: parameter, type, default and meaning.
  #. Procedures specific to the interface, linked to the shared procedures.
  #. Checks that apply, with their IDs and interface-specific triggers.
  #. Statistics notes.
  #. Python backend: the PHY decoder class and the sample word layout.
  #. Example: an excerpt of a tested testbench.
  #. Limitations, in a ``note`` admonition, also added to :doc:`../explanation/limitations`.

* **Status** updated in :doc:`../roadmap` and in the README status list.
* **Release notes** entry for the change.
* **VHDL excerpts** come from files CI runs, included with ``literalinclude`` between
  ``-- docs-start: <name>`` and ``-- docs-end: <name>`` markers. Never select lines by number.
* **Doc comments** in rst, in ``--`` comments directly above each public declaration of a package and
  each generic and port of an entity.
* **Python docstrings** in Google style for every public name, with units (fs, octets, bps) stated.
* **Python snippets** live in files that a test executes.
* **The build passes** ``sphinx-build -W --keep-going``.
