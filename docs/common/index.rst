Common
======

What every component family shares: the rules for Python code next to the VHDL components, the VHDL
package the components use to reach Python, and the package-wide Python infrastructure.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`vhdl_api`
     - ``vc_python_pkg``, for authors of verification components
   * - :doc:`python_api`
     - The package-wide error class, events, reports and sample batches

Rules for Python in a simulation
--------------------------------

* **Python never touches signals.** It sees what a VHDL component recorded (frames, events) and
  returns what the component should drive (symbols). Pin timing stays in VHDL.
* **Errors become VUnit failures.** A violation is logged as an error on the checker of the
  component. An exception raised by a subscriber, or while processing samples, is caught and logged
  as a failure on the logger of the component; it never ends the simulation with a Python traceback.
* **Keep subscribers fast.** They run while the monitor processes a batch of samples.

The VHDL side of the bridge
---------------------------

Verification components in this repository talk to their backends only through
``awesome_vunit_vcs.vc_python_pkg``, which isolates the bridge API. It is meant for writing new
components (see :doc:`../contributing/index`); testbenches use the component procedures and, where
needed, the bridge directly as shown above. The batch encoding on the Python side is
:mod:`awesome_vunit_vcs.common.vunit_bridge`, and the report queue the backends log through is
:mod:`awesome_vunit_vcs.common.reports`.

.. toctree::
   :hidden:

   vhdl_api
   python_api
