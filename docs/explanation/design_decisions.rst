Design decisions
================

The decisions that shaped awesome-vunit-vcs, with the evidence behind them. They were investigated on
2026-09-14 against the VUnit branch with package setup hooks (``feature/package-setup-hooks``,
1ecac00), vunit-python-bridge (28ff9b4), vunit-json-for-vhdl 0.1.0 and cocotbext-eth 0.1.28.

.. contents:: On this page
   :local:
   :depth: 1

A VUnit package, found through the installed Python package
------------------------------------------------------------

**Decision:** awesome-vunit-vcs is a VUnit package with a ``vunit_pkg.toml`` next to its Python
modules, and no entry points or registration code.

**How VUnit finds it.** ``VUnit.add_package(name)``:

#. normalizes the name, so ``-`` and ``.`` become ``_`` (``awesome-vunit-vcs`` becomes
   ``awesome_vunit_vcs``),
#. locates the package with ``importlib.util.find_spec``, which does not import it, and rejects
   namespace packages,
#. reads ``vunit_pkg.toml`` from the package directory and validates its ``[package]`` table: the keys
   ``requires-vunit``, ``requires-vhdl``, ``library``, ``sources`` (each with an ``include`` list of
   glob patterns relative to the package directory) and ``setup``,
#. checks the VUnit version and the VHDL standard, and refuses a pattern that matches no file,
#. adds the sources to the named library,
#. calls the ``setup`` function (``module:function``), if any, with a ``PackageContext`` after the
   sources are added.

awesome-vunit-vcs ships ``src/awesome_vunit_vcs/vunit_pkg.toml`` with the library
``awesome_vunit_vcs`` and the pattern ``vhdl/**/*.vhd``, which covers every VC family directory. The
wheel includes the whole package directory, so the TOML file and the VHDL sources are installed next
to the Python modules. ``tests/packaging/check_package.py`` builds the wheel, installs it into a clean
environment and checks that VUnit finds it outside the repository.

**Prior art.** vunit-json-for-vhdl does exactly the same with no code involved. Its wheel contains
``vunit_json_for_vhdl/vunit_pkg.toml``:

.. code-block:: toml

    [package]
    requires-vunit = ">=5.0.0.dev9"
    requires-vhdl = ">=2008"
    library = "json"

    [[package.sources]]
    include=["hdl/src/*.vhdl"]

and its ``__init__.py`` holds only JSON helper functions for run scripts.

**No setup hook.** The package needs vunit-python-bridge, but ``vunit_pkg.toml`` cannot declare a
dependency on another VUnit package, and ``PackageContext`` offers no way to add one without reaching
into private VUnit state. A run script therefore adds both packages, in either order.

Timing in VHDL, not cocotb's simulator objects
----------------------------------------------

**Decision:** pin timing lives in VHDL, and cocotb's simulator-facing classes are not used.

cocotb and cocotbext-eth provide mature Ethernet models (``GmiiSource``, ``GmiiSink``, ``RgmiiSink``
and more), but they are built on cocotb's execution model: Python coroutines scheduled by cocotb,
which owns the simulator through VPI/VHPI/FLI callbacks, and ``Signal`` handles, ``RisingEdge`` and
``Timer`` triggers that suspend a coroutine until the simulator reaches an event.

The VUnit Python bridge is the opposite. A VHDL process calls Python synchronously through a foreign
function interface, and Python returns a value. There is no scheduler, no signal handle and no trigger
on the Python side, and no way to suspend Python until an edge. Running cocotb's classes through the
bridge would need a second scheduler emulating cocotb inside a function call, and pin timing would
move to the language that cannot see the simulation. Keeping timing in VHDL makes the components
simulator independent through VUnit, deterministic, and fast enough (see :doc:`performance`).

cocotbext-eth is not a dependency
---------------------------------

**Decision:** the Ethernet framing core is implemented here, and cocotbext-eth is used only as an
independent reference in the test suite.

**What could be reused.** The frame classes (``GmiiFrame`` in ``gmii.py``, ``XgmiiFrame`` in
``xgmii.py``, ``EthMacFrame`` in ``eth_mac.py``) are simulator independent in what they do (preamble,
SFD, padding, FCS), but they live in the modules that define the simulator-facing sources and sinks.
Only ``constants.py`` (preamble octets, XGMII and BASE-R control codes) and ``version.py`` are free of
simulator code.

**What importing them costs.** ``gmii.py``, ``mii.py``, ``rgmii.py``, ``xgmii.py``, ``eth_mac.py``,
``ptp.py`` and ``reset.py`` all ``import cocotb`` and import from ``cocotb.triggers``,
``cocotb.queue`` and ``cocotb.utils`` at module level. The package ``__init__.py`` imports all of
them, and the distribution requires ``cocotb>=1.6.0`` and ``cocotbext-axi``. Importing ``GmiiFrame``
therefore imports cocotb.

**Why that is not worth it.** The framing needed here is small: the FCS is ``zlib.crc32``, and
preamble, SFD, padding and frame limits are a few lines each. A dependency that brings in a simulator
runtime for that would couple the package to cocotb for no gain. Instead, the ``reference`` extra
installs cocotbext-eth, and ``tests/python/test_references.py`` compares wire frames and FCS results
against ``GmiiFrame``; those tests are skipped when it is not installed. No cocotbext-eth source is
copied.

Batched samples in flat integer arrays
--------------------------------------

**Decision:** monitors record samples in VHDL and send them in batches of 32-bit integers, 4096
samples per call by default, flushed at the end of every frame.

The alternatives were one bridge call per clock cycle, one call per complete frame, and structured
records (a dataclass per sample). The benchmark on :doc:`performance` shows that one call per cycle
costs 30 to 60 times as much as batching, while batches and whole frames cost the same. The cost is
in the number of bridge calls and Python objects, so flat integer arrays, decoded with NumPy, keep
both low. A bounded batch length keeps memory in check for jumbo frames and long runs, and the flush
at the end of a frame logs a violation at a simulation time close to the frame. The layout is
described in :doc:`architecture`.

Responders call once per transfer unit
--------------------------------------

**Decision:** a component that must answer a bus may call its backend once per octet or word.

A passive monitor can always batch, but an active responder, such as a memory model answering an
opcode, decides what to drive next from what it has just received. It cannot batch in advance. Such a
component may call the bridge once per transfer unit, never once per clock cycle, must measure that
cost, and moves bulk content (preloading and checking memory contents) through batched procedures.

One VHDL file talks to the bridge
---------------------------------

**Decision:** only ``vhdl/common/vc_python_pkg.vhd`` names the subprograms of vunit-python-bridge.

The bridge is the VUnit package ``vunit-python-bridge``, compiled into the library ``python_bridge``
and used with ``library python_bridge; context python_bridge.python_context;``. Its setup function
selects the foreign language interface for the simulator, and the interpreter is initialized on the
first call. The subprograms this package relies on are:

* ``new_session(id : id_t) return python_session_t``: a namespace per identity, whose errors are
  logged on ``get_logger(id)``,
* ``exec(code, session)``, ``eval_integer``, ``eval_boolean``, ``eval_string`` and
  ``eval_integer_array(expr, session)``,
* ``call(name, arg(integer_array_t), arg(integer)..., session => s)`` returning ``integer``, and
  ``call_string``.

Components call ``new_vc_session``, ``create_backend``, ``backend_call`` and its typed variants
(``backend_call_integer``, ``backend_call_string``, ...), ``log_reports`` and the sample batch subprograms
instead. The bridge is still under development, so a change in its API is absorbed in one file.

Unresolved port types
---------------------

**Decision:** component ports are ``std_ulogic`` and ``std_ulogic_vector``.

VUnit's own verification components use ``std_logic``. Unresolved types catch multiple drivers at
elaboration instead of producing ``X`` during simulation, and they connect to resolved testbench
signals without conversion.
