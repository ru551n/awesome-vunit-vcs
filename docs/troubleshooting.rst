Troubleshooting
===============

Installation and compilation
----------------------------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Symptom
     - Cause and fix
   * - ``Could not find package awesome_vunit_vcs``
     - The package is not installed in the Python environment running ``run.py``. Activate the virtual
       environment, then ``pip install``.
   * - ``design unit COM_CONTEXT not found in library VUNIT_LIB`` or ``VC_PKG not found``
     - ``vu.add_verification_components()`` is missing from the run script.
   * - ``library python_bridge`` not found
     - ``vu.add_package("vunit-python-bridge")`` is missing.
   * - An error about package setup hooks, or ``add_package`` rejecting ``setup``
     - VUnit is too old. Install the pinned VUnit from ``tests/packaging/unreleased-requirements.txt``.
   * - The bridge library fails to compile
     - Linux and macOS need a C compiler and the Python development headers (``python3-dev``), and a
       CPython with a shared ``libpython``.
   * - The bridge reports a ``sys.prefix`` mismatch
     - The simulator's embedded Python is not the environment that started VUnit. Run ``run.py`` with the
       interpreter of the environment where the packages are installed.
   * - ``ModuleNotFoundError`` for a packet or sequence function
     - Put the module's directory on ``sys.path`` (``PYTHONPATH``) or install it.

Simulation
----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Symptom
     - Cause and fix
   * - ``ETH_METAVALUE`` at the start of a test
     - Design outputs without reset are ``U`` until driven. Give them an initial value or reset the design
       before the monitor sees traffic.
   * - ``ETH_FRAME_STATE`` at ``test_runner_cleanup``
     - A frame was still on the wire when the test ended. Call ``wait_until_idle`` on sources and monitors
       before ``test_runner_cleanup``.
   * - ``ETH_SCOREBOARD`` for expected frames never received
     - The frames were not sent, were dropped by the design, or the test ended too early. Check the order
       of ``check_ethernet_frame`` and ``push_ethernet_frame``, and wait until idle.
   * - ``ETH_SCOREBOARD`` differences on short frames
     - The expected frame includes padding or an FCS. Expect the frame data only: from the destination
       address up to, not including, the FCS.
   * - The test stops at the first deliberate error
     - Errors stop the simulation by default. Use ``disable_stop`` and count them; see
       :doc:`ethernet/checks`.
   * - ``Got unexpected message``
     - A procedure was called with a handle of another kind, or a message was sent to a VC that does not
       handle it. Use the procedure's overload for that handle.
   * - ``An actor already exists``
     - Two VCs were given the same ``id``. Give each VC its own id.
   * - ``wait_until_idle`` never returns
     - The clock is stopped or the design holds the line. Use the ``timeout`` of ``wait_until_idle``;
       ``reset(net, vc)`` recovers a VC even without a clock.
   * - A Python subscriber never runs
     - It was registered after the frames arrived (subscribers only get frames received from then on), or
       in another session: execute the module in ``new_session(get_id(monitor))``, the monitor's own. A
       subscriber that raises is not silent; look for a failure naming it on the monitor's logger. See
       :ref:`python-monitors-in-simulation`.
   * - Wrong IFG or utilization
     - ``link_rate_mbps`` does not match the clock of the interface.

Performance
-----------

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Symptom
     - Cause and fix
   * - A slow simulation with many small frames
     - Keep the default ``batch_length`` and ``flush_at_frame_end``; see :doc:`explanation/performance`.
   * - Large output directories
     - Captures grow with the traffic; capture only the tests you inspect. See :doc:`ethernet/captures`.

Simulators
----------

GHDL and NVC are tested in CI. Questa/ModelSim, Riviera-PRO and Active-HDL are supported by
vunit-python-bridge but not tested with these components. Report problems on `GitHub <https://github.com/ru551n/awesome-vunit-vcs/issues>`__.
