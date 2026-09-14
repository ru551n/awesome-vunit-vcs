Ethernet frames in Python
=========================

The Ethernet Python API works without a simulator. Each recipe is a complete script in
:repo-file:`examples/python` that runs as it is:

.. code-block:: console

   $ python examples/python/build_frames.py

How do I build frames and malformed traffic?
--------------------------------------------

**Goal:** make a frame, see what goes on the wire, and describe deliberate errors.

.. literalinclude:: ../../examples/python/build_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

**When to use this:** to prepare expected frames, or to try out malformed traffic before simulating.

* ``WireOptions`` describes errors, and ``expected_violations`` tells which checks will report them.

**Full example:** :repo-file:`examples/python/build_frames.py`

**See also:** :doc:`../python_guide`

How do I decode samples from any interface?
-------------------------------------------

**Goal:** turn recorded GMII, MII or XGMII samples into frames.

.. literalinclude:: ../../examples/python/decode_samples.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

**When to use this:** to test your own Python checks against realistic input without a simulator.

* ``eth.GMII``, ``eth.MII`` and ``eth.XGMII(...)`` are the interfaces; ``with_rate`` changes the rate.

**Full example:** :repo-file:`examples/python/decode_samples.py`

**See also:** :doc:`../python_guide`

How do I check frames and get statistics?
-----------------------------------------

**Goal:** run the protocol checks and read the results.

.. literalinclude:: ../../examples/python/check_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

**When to use this:** in ``pytest`` tests of traffic generators or reference models.

* Use ``with eth.Monitor(...)``; leaving the block finishes the last frame.

**Full example:** :repo-file:`examples/python/check_frames.py`

**See also:** :doc:`../python_guide`, :doc:`../ethernet/checks`

How do I write a PCAPNG file?
-----------------------------

**Goal:** save frames for Wireshark.

.. literalinclude:: ../../examples/python/capture_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

**When to use this:** to look at generated traffic in Wireshark, or share it with others.

* ``write_pcapng`` writes any frames; ``rx.capture`` writes what a monitor receives.

**Full example:** :repo-file:`examples/python/capture_frames.py`

**See also:** :doc:`../ethernet/captures`

How do I react to each frame in Python?
---------------------------------------

**Goal:** run a function for every frame or violation a monitor finds.

.. literalinclude:: ../../examples/python/monitor_subscribers.py
   :language: python
   :start-after: # docs-start: subscribers
   :end-before: # docs-end: subscribers

**When to use this:** for custom checks, scoreboards or logging on received traffic.

* ``@rx.on_frame`` and ``@rx.on_violation`` work as decorators or as plain calls.
* Inside a simulation, use ``@vc.on_frame``; see :doc:`monitors`.

**Full example:** :repo-file:`examples/python/monitor_subscribers.py`

**See also:** :doc:`../python_guide`

How do I write my own Hypothesis strategy?
------------------------------------------

**Goal:** generate frames and malformations for property-based tests.

.. literalinclude:: ../../examples/python/property_based.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

**When to use this:** when you want Hypothesis to find the frames that break your Python code.

* Build strategies with ``st.builds`` on the constructors, bounded by ``eth.LIMITS``.
* Install Hypothesis yourself; the package doesn't need it.

**Full example:** :repo-file:`examples/python/property_based.py`

.. code-block:: console

   $ pytest examples/python/property_based.py

**See also:** :doc:`../python_guide`, :doc:`properties`
