Common
======

What every component family shares: how your Python code works next to the components, how to pass
arguments to Python, and the shared API.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`vhdl_api`
     - ``vc_python_pkg``, for authors of verification components
   * - :doc:`python_api`
     - The package-wide error class, events, reports and sample batches

Follow the rules for Python in a simulation
-------------------------------------------

* **Python never touches signals.** It works on the frames a component received and decides what a
  component sends. The pins stay in VHDL.
* **Errors become VUnit failures.** A violation is an error on the checker of the component. An
  exception in your Python code becomes a failure on the component's logger, not a Python traceback.
* **Keep subscribers fast.** They run while the monitor processes traffic.

.. _passing-arguments:

Pass arguments to Python
------------------------

Write arguments as VHDL values and combine them with ``&``. Your function receives Python values.

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
   :caption: Arguments for a packet function

   push_ethernet_packet(
     net, source, "my_packets:udp_to_dut",
     kwarg("port", 1234) & kwarg("size", 128) & kwarg_text("label", "first ""burst""")
   );

Use it wherever a procedure takes ``arguments``, such as ``push_ethernet_packet``,
``push_ethernet_sequence``, ``check_ethernet_sequence`` and ``new_property``. A function that takes a
``kwarg_text`` or ``kwarg_time`` argument turns it into a ``str`` or femtoseconds with
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_text` and
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_time_fs`.

Write your own components
-------------------------

``awesome_vunit_vcs.vc_python_pkg`` is the package components use to reach Python. You only need it to
write a new component; see :doc:`../contributing/index`. Testbenches use the component procedures,
and the bridge directly where needed.

Catch every package error
-------------------------

Every error the package raises derives from ``awesome_vunit_vcs.AwesomeVunitVcsError``. Catch it to
handle all of them in one place.

Related recipes
---------------

* :doc:`../cookbook/python_and_vhdl`: every recipe on that page

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`

.. toctree::
   :hidden:

   vhdl_api
   python_api
