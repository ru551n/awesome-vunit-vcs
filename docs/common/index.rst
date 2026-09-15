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
     - A simulation time; decode it with ``decode_time_fs()`` to get femtoseconds

.. code-block:: vhdl
   :caption: Arguments for a packet function

   push_ethernet_packet(
     net, source, "my_packets:udp_to_dut",
     kwarg("port", 1234) & kwarg("size", 128) & kwarg_text("label", "first ""burst""")
   );

Use it wherever a procedure takes ``arguments``, such as ``push_ethernet_packet``,
``push_ethernet_sequence``, ``check_ethernet_sequence`` and ``new_property``.

**In VHDL**, ``arg`` and ``kwarg`` come from the Python bridge, and ``arg_text``, ``kwarg_text``,
``arg_time`` and ``kwarg_time`` from ``awesome_vunit_vcs.vc_python_pkg``. ``ethernet_context`` includes
both, so an Ethernet testbench needs nothing more. Any other testbench, such as a property testbench,
adds these lines:

.. code-block:: vhdl
   :caption: The context clauses for arguments, outside ethernet_context

   library python_bridge;
   context python_bridge.python_context;

   library awesome_vunit_vcs;
   use awesome_vunit_vcs.vc_python_pkg.all;

**In Python**, a function receives ``arg`` and ``kwarg`` values as ``int``, ``float``, ``bool``, ``str``
or a list. A ``kwarg_text`` or ``kwarg_time`` value needs decoding with
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_text` or
:func:`~awesome_vunit_vcs.common.vunit_bridge.decode_time_fs`, as ``label`` shows here:

.. literalinclude:: ../../examples/cookbook/python/cookbook_traffic.py
   :caption: examples/cookbook/python/cookbook_traffic.py
   :language: python
   :start-after: # docs-start: packet-function
   :end-before: # docs-end: packet-function

The rest of the Python bridge package
-------------------------------------

``awesome_vunit_vcs.vc_python_pkg`` also holds what the components use to reach Python, such as
``create_backend`` and ``backend_call``. A testbench rarely needs those; they matter when you write a
component of your own, see :doc:`../contributing/index`.

Catch every package error
-------------------------

Every error the package raises derives from ``awesome_vunit_vcs.AwesomeVunitVcsError``. Catch it to
handle all of them in one place.

Related recipes
---------------

* :doc:`../cookbook/python_traffic`

API reference
-------------

* VHDL: :doc:`vhdl_api`
* Python: :doc:`python_api`

.. toctree::
   :hidden:

   vhdl_api
   python_api
