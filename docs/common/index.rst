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

.. _passing-arguments:

Passing arguments to Python
---------------------------

Arguments are VHDL values, combined with ``&``. The function receives them as Python values.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Write
     - When
   * - ``kwarg("size", 128)``
     - A named argument: integer, real, boolean, a short name such as ``"udp"``, or an
       ``integer_vector``
   * - ``arg(1234)``
     - A positional argument, before any named ones
   * - ``kwarg_text("note", msg)``
     - Any text, such as a message or a file name, that may contain quotes or backslashes
   * - ``kwarg_time("delay", 10 ns)``
     - A simulation time; the function gets femtoseconds

.. code-block:: vhdl

   push_ethernet_packet(
     net, source, "my_packets:udp_to_dut",
     kwarg("port", 1234) & kwarg("size", 128) & kwarg_text("label", "first ""burst""")
   );

Use it wherever a procedure takes ``arguments``, such as ``push_ethernet_packet``,
``push_ethernet_sequence``, ``check_ethernet_sequence`` and ``new_property``. A function that takes a
``kwarg_text`` or ``kwarg_time`` argument turns it into a ``str`` or femtoseconds with
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_text` and
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_time_fs`.

The VHDL side of the bridge
---------------------------

Verification components in this repository talk to their backends only through
``awesome_vunit_vcs.vc_python_pkg``, which isolates the bridge API. It is meant for writing new
components (see :doc:`../contributing/index`); testbenches use the component procedures and, where
needed, the bridge directly. The batch encoding on the Python side is
:mod:`awesome_vunit_vcs.common.vunit_bridge`, and the report queue the backends log through is
:mod:`awesome_vunit_vcs.common.reports`.

.. toctree::
   :hidden:

   vhdl_api
   python_api
