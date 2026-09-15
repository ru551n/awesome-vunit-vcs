Python and VHDL together
========================

Most tests never need a line of Python: the components already rebuild, check and count frames. But
some things are easier in Python, such as building an IP packet, generating thousands of varied frames,
or computing what a design should answer. In this article we add Python to the GMII testbench from
:doc:`first_test`. We start with the simplest case, calling one Python function from VHDL, and build up
to Python checking every received frame.

What goes in Python and what goes in VHDL
-----------------------------------------

A rule of thumb: VHDL decides *when* something happens, Python decides *what*.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - Write it in VHDL (your testbench)
     - Write it in Python (your module)
   * - Clocks, resets and waiting
     - Building frames and packets
   * - The test structure and the checks on results
     - Lookup tables and reference models
   * - Short directed tests with known frames
     - Long or random traffic

In this article the code lives in these files:

.. list-table::
   :header-rows: 1
   :widths: 40 15 45

   * - File
     - Language
     - What it holds
   * - ``examples/cookbook/run.py``
     - Python
     - The run script. It makes the ``python`` directory importable.
   * - ``examples/cookbook/tb_cookbook.vhd``
     - VHDL
     - The testbench. It calls the Python functions by name.
   * - ``examples/cookbook/python/cookbook_model.py``
     - Python
     - Your module: a lookup table and a reference model.
   * - ``examples/cookbook/python/cookbook_traffic.py``
     - Python
     - Your module: functions that build frames.
   * - ``examples/cookbook/python/test_cookbook_model.py``
     - Python
     - pytest tests of your modules, run without a simulator.

Python never touches signals. It gets values from VHDL and returns values to VHDL.

Step 1: make your Python files importable (Python, run script)
--------------------------------------------------------------

Keep your Python files in a ``python`` directory next to the testbench. The run script puts that
directory on the Python path, so the simulator can import the files by name:

.. literalinclude:: ../../examples/cookbook/run.py
   :caption: examples/cookbook/run.py
   :language: python
   :start-after: # docs-start: python-path
   :end-before: # docs-end: python-path

That's the only setup.

Step 2: call a Python function from VHDL
----------------------------------------

The simplest use of Python is one function that returns a value. **In your Python module**, write an
ordinary function:

.. literalinclude:: ../../examples/cookbook/python/cookbook_model.py
   :caption: examples/cookbook/python/cookbook_model.py
   :language: python
   :start-after: # docs-start: helper
   :end-before: # docs-end: helper

**In the testbench**, import the file once and call the function as ``module.function``:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: call-python
   :end-before: -- docs-end: call-python
   :dedent:

Arguments are built with ``kwarg("name", value)`` for keyword arguments and ``arg(value)`` for
positional ones, joined with ``&``. They arrive in Python as typed values: ``length`` is an ``int``.
Pick the call that matches what the function returns: ``call`` for an integer, ``call_integer_vector``
for a list of integers. :ref:`passing-arguments` shows the other kinds of arguments, such as text and
times.

Step 3: send a packet built in Python
-------------------------------------

Now let Python decide what frame to send. **In your Python module**, write a :term:`packet function`
that returns a frame. This one builds an IPv4 frame whose payload starts with a port number:

.. literalinclude:: ../../examples/cookbook/python/cookbook_traffic.py
   :caption: examples/cookbook/python/cookbook_traffic.py
   :language: python
   :start-after: # docs-start: packet-function
   :end-before: # docs-end: packet-function

**In the testbench**, name the function as ``"module:function"`` and pass its arguments:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: packet
   :end-before: -- docs-end: packet
   :dedent:

The function may return a ``Frame``, the frame octets as ``bytes``, or a Scapy packet. The source adds
the preamble, SFD and FCS in every case.

``label`` and ``sent_at`` show the two arguments that need decoding. **In the testbench**,
``kwarg_text`` sends text that may contain any character and ``kwarg_time`` a simulation time; **in the
Python module**, ``decode_text`` turns the text back into a ``str`` and ``decode_time_fs`` the time into
an integer number of femtoseconds. Their type hints also allow a ``str`` or an ``int`` so you can call
the same function from a Python test; from VHDL they always get a list of integers. Both VHDL functions
come with ``ethernet_context``, like ``arg`` and ``kwarg``. :ref:`passing-arguments` lists every kind of
argument.

Step 4: unit test the Python part
---------------------------------

Your Python modules are plain Python, so test them with pytest, in seconds and without a simulator.
**In a test file next to your modules:**

.. literalinclude:: ../../examples/cookbook/python/test_cookbook_model.py
   :caption: examples/cookbook/python/test_cookbook_model.py
   :language: python
   :start-after: # docs-start: unit-test
   :end-before: # docs-end: unit-test

.. code-block:: console
   :caption: Terminal

   $ PYTHONPATH=examples/cookbook/python pytest examples/cookbook/python

A broken function then fails in pytest, not halfway through a simulation.

Going further
-------------

The steps above cover most Python use. The sections below build on them for longer and more automatic
tests.

Send a reproducible random sequence
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A packet function sends one frame. For long traffic, **in your Python module**, write a generator that
yields frames and takes a seed:

.. literalinclude:: ../../examples/cookbook/python/cookbook_traffic.py
   :caption: examples/cookbook/python/cookbook_traffic.py
   :language: python
   :start-after: # docs-start: sequence-function
   :end-before: # docs-end: sequence-function

**In the testbench**, give the same generator and seed to both components. The source sends the frames
and the monitor expects exactly those frames:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: sequence
   :end-before: -- docs-end: sequence
   :dedent:

The seed comes from VUnit, which prints it for every test. When a random test fails, run it again with
the same seed and it sends the same frames.

Check results against a Python reference model
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A reference model is a Python function that predicts what the design should do. **In your Python
module:**

.. literalinclude:: ../../examples/cookbook/python/cookbook_model.py
   :caption: examples/cookbook/python/cookbook_model.py
   :language: python
   :start-after: # docs-start: model
   :end-before: # docs-end: model

**In the testbench**, send frames, then compare what the monitor counted with the model's prediction:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: reference-model
   :end-before: -- docs-end: reference-model
   :dedent:

Like the function in step 2, the model is plain Python, so the pytest tests of step 4 cover it too.

Check every received frame in Python
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

To look at *every* frame a monitor receives, attach a :term:`subscriber`. **This Python file** runs in the
monitor's Python session, where the monitor is available as the object ``vc``:

.. literalinclude:: ../../examples/cookbook/python/cookbook_subscriber.py
   :caption: examples/cookbook/python/cookbook_subscriber.py
   :language: python
   :start-after: # docs-start: subscriber
   :end-before: # docs-end: subscriber

``@vc.on_frame`` calls the function for each frame. To report a problem, call ``vc.error("ETH_USER", ...)``.
The monitor counts it on the ``eth_user`` check, which only counts errors reported from Python, so a
negative test can count it and ``set_check_enabled`` can switch it off without touching the scoreboard.
An exception, by contrast, stops the test.

**In the testbench**, load the file into the monitor's session with ``exec_file``, then count the error
on the monitor's logger:

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :caption: examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: python-subscriber-errors
   :end-before: -- docs-end: python-subscriber-errors
   :dedent:

``exec_file`` and ``new_session`` come with ``ethernet_context``. :doc:`error_handling` shows which
logger counts which errors, and :doc:`../ethernet/python_simulation` what else a subscriber can use.

Do and don't
------------

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - Do
     - Don't
   * - Pass arguments with ``arg`` and ``kwarg``
     - Build Python code as strings
   * - Keep Python functions free of simulator signals
     - Read or drive signals from Python
   * - Pass seeds explicitly
     - Use unseeded random numbers
   * - Report problems with ``vc.error``
     - Raise exceptions for expected errors
   * - Keep state in your own module
     - Share global variables between components

Where to go next
----------------

* :doc:`python_standalone` uses frames, checks and captures in plain Python.
* :doc:`property_testing` lets Hypothesis generate test data inside the simulation.
* :doc:`../ethernet/packets_and_sequences` lists every option of packets and sequences.
