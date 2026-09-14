Ethernet in Python
==================

Use the Python API to build frames and malformed traffic, decode samples, run checks and write
captures, without a simulator. It is also what you use to test your own checks with ``pytest`` and
Hypothesis. To add Python code to a running simulation, see :doc:`python_simulation`.

.. code-block:: python
   :caption: The one import you need

   from awesome_vunit_vcs import ethernet as eth

Every example on this page is a file that the test suite runs.

.. list-table::
   :widths: 30 70

   * - Times
     - Integers in femtoseconds. ``eth.fs("8 ns")`` converts a readable string.
   * - Sizes
     - Octets.
   * - Rates
     - Bits per second. ``eth.bps("2.5G")`` converts a readable string.
   * - Errors
     - Every invalid argument raises :class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`.

.. contents:: On this page
   :local:
   :depth: 1

Build frames and malformed traffic
----------------------------------

.. literalinclude:: ../../examples/python/build_frames.py
   :caption: examples/python/build_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

A :class:`~awesome_vunit_vcs.ethernet.api.Frame` holds the octets from the destination address up to
and including the FCS. Build one with ``Frame.from_payload``, ``Frame.from_bytes`` or
``Frame.from_packet``. Monitors return the same type, with its time and violations added.

Frames compare by content, so a received frame equals the frame that was sent.

``frame.to_wire()`` builds what a transmitter puts on the line. A
:class:`~awesome_vunit_vcs.ethernet.api.WireOptions` value describes deliberate errors: FCS, padding,
preamble, SFD, error signal and gap. :func:`~awesome_vunit_vcs.ethernet.api.expected_violations` tells
you which checks a monitor reports for it.

Error offsets count from the first octet after the SFD, as in the VHDL ``frame_options``.

Decode samples from any interface
---------------------------------

.. literalinclude:: ../../examples/python/decode_samples.py
   :caption: examples/python/decode_samples.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Pick an interface: ``eth.GMII``, ``eth.MII``, ``eth.RGMII``, ``eth.RMII`` or
``eth.XGMII(lanes=8, rate="100G")``. Use
``with_rate`` for other rates. ``interface.encode(frames)`` gives the pin samples, and
:func:`~awesome_vunit_vcs.ethernet.api.decode` turns samples back into frames.

A frame sent with default options comes back padded to the minimum size, ``frame.padded()``.

Check frames and get statistics
-------------------------------

.. literalinclude:: ../../examples/python/check_frames.py
   :caption: examples/python/check_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

A :class:`~awesome_vunit_vcs.ethernet.api.Monitor` keeps its state across calls. Feed it samples or
frames, and it returns the finished frames. It collects every
:class:`~awesome_vunit_vcs.ethernet.checker.Violation` and keeps
:class:`~awesome_vunit_vcs.ethernet.metrics.Statistics`.

Use it as a context manager. Then a frame still in progress is reported, and captures are closed.

Checks have the VHDL check names in upper case, such as ``"ETH_FCS"``.
``Monitor(interface, checks=["ETH_FCS"])`` runs only some; ``checks=False`` runs none.

React to frames with subscribers
--------------------------------

.. literalinclude:: ../../examples/python/monitor_subscribers.py
   :caption: examples/python/monitor_subscribers.py
   :language: python
   :start-after: # docs-start: subscribers
   :end-before: # docs-end: subscribers

A :term:`subscriber` is a function the monitor calls as it finds frames or violations. Use it to react
while you feed traffic, instead of inspecting ``rx.frames`` and ``rx.violations`` afterwards.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Subscriber
     - Called with
   * - ``rx.on_frame``
     - Every :class:`~awesome_vunit_vcs.ethernet.api.Frame` received from now on: ``data``, ``payload``,
       ``dst``, ``src``, ``ethertype``, ``fcs_ok``, ``ok``, ``index``, ``timestamp_fs`` and the
       ``violations`` found on it.
   * - ``rx.on_violation``
     - Every :class:`~awesome_vunit_vcs.ethernet.checker.Violation` from now on: ``check``, ``message``,
       ``timestamp_fs`` and ``frame_index``. A frame's violations come before the frame.

* Both work as decorators and as plain calls.
* Subscribe before ``feed``: only what you feed afterwards is delivered.
* Subscribers run in the order they subscribed. If one raises, the others still run, and then the
  exception comes out of ``feed``.

Write a capture
---------------

.. literalinclude:: ../../examples/python/capture_frames.py
   :caption: examples/python/capture_frames.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

:func:`~awesome_vunit_vcs.ethernet.api.write_pcapng` writes frames to a file Wireshark reads.
``Monitor.capture`` writes what a monitor receives. Captures start at the destination address.

Build packets with Scapy
------------------------

.. literalinclude:: ../../examples/python/scapy_packets.py
   :caption: examples/python/scapy_packets.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

Scapy is optional: ``pip install awesome-vunit-vcs[scapy]``. You only need it for the protocol layers
above Ethernet.

Write your own Hypothesis strategies
------------------------------------

.. literalinclude:: ../../examples/python/property_based.py
   :caption: examples/python/property_based.py
   :language: python
   :start-after: # docs-start: example
   :end-before: # docs-end: example

awesome-vunit-vcs does not depend on `Hypothesis <https://hypothesis.readthedocs.io>`__, but the API
makes strategies short:

* **Typed constructors.** ``st.builds(eth.Frame.from_payload, ...)`` and ``st.builds(eth.WireOptions,
  ...)`` work as they are.
* **One exception.** An invalid combination raises
  :class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`, which a test can reject with
  ``assume``.
* **Public limits.** :data:`~awesome_vunit_vcs.ethernet.limits.LIMITS` bounds addresses, EtherTypes,
  payloads, preambles, gaps, lanes and rates. :class:`~awesome_vunit_vcs.ethernet.limits.Malformation`
  names the deliberate errors.
* **Ready-made oracles.** ``decode(i, i.encode([frame])).frames == (frame.padded(),)`` holds on every
  interface. ``expected_violations`` tells you what the checker must report, and
  :func:`~awesome_vunit_vcs.ethernet.api.supported_malformations` lists the malformations it predicts
  exactly on an interface.

Related recipes
---------------

* :doc:`../cookbook/python`: every recipe on that page

API reference
-------------

:doc:`python_api`
