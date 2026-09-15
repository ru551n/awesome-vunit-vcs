Python on its own
=================

The Python side of awesome-vunit-vcs doesn't need a simulator. The same frames, checks and captures the
components use inside a simulation work in a plain Python script or a pytest test. That's handy for
trying out traffic before you simulate, and for testing your own traffic generators and reference
models in seconds.

Everything in this article is Python. Each step is a complete script in :repo-file:`examples/python`
that runs as it is; there is no VHDL and no simulator involved:

.. code-block:: console
   :caption: Terminal

   $ python examples/python/build_frames.py

We start with a single frame and build up to letting Hypothesis generate frames for us.

Step 1: build a frame (Python)
------------------------------

Everything starts with one import, ``from awesome_vunit_vcs import ethernet as eth``. A ``Frame`` holds
the frame data, and ``to_wire`` shows what goes on the wire, including deliberate errors:

.. literalinclude:: ../../examples/python/build_frames.py
   :caption: examples/python/build_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

``WireOptions`` describes what to break, like ``frame_options`` does in VHDL. Its ``fcs`` is ``"bad"`` or
``"none"`` where VHDL has ``fcs_bad`` and ``fcs_none``, and ``"append"`` where VHDL has ``fcs_append``.
The default, ``"auto"``, appends the correct FCS. ``expected_violations``
tells you in advance which checks will report it.

Step 2: turn frames into samples and back (Python)
--------------------------------------------------

An interface, such as ``eth.GMII``, ``eth.MII``, ``eth.RGMII``, ``eth.RMII``, ``eth.XGMII(...)`` or
``eth.AXIS(...)``, encodes frames as the samples a design would see, and decodes samples back into
frames:

.. literalinclude:: ../../examples/python/decode_samples.py
   :caption: examples/python/decode_samples.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

``with_rate`` changes an interface's link rate.

Step 3: check frames and read the statistics (Python)
-----------------------------------------------------

A ``Monitor`` runs the same checks as a monitor in the simulation. Used with ``with``, it finishes the
last frame when the block ends:

.. literalinclude:: ../../examples/python/check_frames.py
   :caption: examples/python/check_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

This is the natural place to test a traffic generator: generate, check, and assert that the violations
are the ones you meant.

Step 4: save traffic for Wireshark (Python)
-------------------------------------------

``write_pcapng`` saves any frames to a file Wireshark opens:

.. literalinclude:: ../../examples/python/capture_frames.py
   :caption: examples/python/capture_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

To save what a monitor receives instead, use ``rx.capture``.

Going further
-------------

React to each frame (Python)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A monitor can call your functions for every frame and every violation it finds:

.. literalinclude:: ../../examples/python/monitor_subscribers.py
   :caption: examples/python/monitor_subscribers.py
   :language: python
   :start-after: # docs-start: subscribers
   :end-before: # docs-end: subscribers

``@rx.on_frame`` and ``@rx.on_violation`` work as decorators or as plain calls. Inside a simulation the
same idea is ``@vc.on_frame``, as :doc:`python_traffic` shows.

Work with Scapy packets (Python)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With Scapy installed (``pip install awesome-vunit-vcs[scapy]``), frames convert to and from Scapy
packets. Build a packet with Scapy, send it through an interface and look at it on the other side:

.. literalinclude:: ../../examples/python/scapy_packets.py
   :caption: examples/python/scapy_packets.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Write your own Hypothesis strategy (Python)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Finally, let Hypothesis generate frames and malformations in a pytest test. The constructors are typed
and ``eth.LIMITS`` holds the valid ranges, so a strategy takes only a few lines:

.. literalinclude:: ../../examples/python/property_based.py
   :caption: examples/python/property_based.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

.. code-block:: console
   :caption: Terminal

   $ pytest examples/python/property_based.py

The package doesn't depend on Hypothesis, so install it yourself (``pip install hypothesis``).

Talk to the flash model directly (Python)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The flash model works without a simulator too. This script sends the command that reads a flash's
JEDEC ID, one byte at a time:

.. literalinclude:: ../../examples/python/flash_jedec_id.py
   :caption: examples/python/flash_jedec_id.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Where to go next
----------------

* :doc:`../ethernet/python` covers the Ethernet Python API in full, and :doc:`../ethernet/python_api` lists
  every class and function.
* :doc:`../flash/python` covers the flash model in Python.
* :doc:`python_traffic` connects Python to a simulation.
