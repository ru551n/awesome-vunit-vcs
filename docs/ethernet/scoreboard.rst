Scoreboard and received frames
==============================

A :term:`monitor` offers three ways to use the frames it receives: compare them with expected
frames, read them in the testbench, or subscribe to them. :doc:`monitors` shows how to create the
monitor.

Expect frames
-------------

.. code-block:: vhdl
   :caption: Three ways to expect a frame

   check_ethernet_frame(net, monitor, frame, blocking => false);  -- queue and continue
   check_ethernet_frame(net, monitor, frame);                     -- wait until checked
   check_ethernet_frame(net, monitor, frame, msg => "frame 3");   -- with context

The monitor compares expected and received frames in order. ``frame`` is the :term:`frame data`. A
received frame padded to ``min_frame_octets`` matches its unpadded expectation.

A difference is an ``ETH_SCOREBOARD`` error. Expected frames that never arrive are reported at
``test_runner_cleanup``.

Queue expectations with ``blocking => false`` before you push the frames, as the
:doc:`../getting_started/quickstart` does. For long traffic, ``check_ethernet_sequence`` expects the
frames of a Python generator; see :doc:`packets_and_sequences`.

Read frames in the testbench
----------------------------

.. code-block:: vhdl
   :caption: Wait for the next frame and read it

   variable data : std_ulogic_vector(0 to 8 * 1518 - 1);
   variable length : natural;
   variable fcs_ok : boolean;
   ...
   pop_ethernet_frame(net, monitor, data, length, fcs_ok);   -- waits for the next frame

``length`` is the number of frame octets written to ``data``. Start the pop before the frame arrives:
the monitor keeps frames only while a pop is waiting.

The stream interface does the same octet by octet: ``pop_stream(net, as_stream(monitor), octet, last)``.

Subscribe to frames
-------------------

While a monitor has subscribers, it publishes every frame as an ``ethernet_frame_msg``. See
:doc:`monitors` for an example. In Python, use ``@vc.on_frame`` and ``vc.frames``; see
:ref:`python-monitors-in-simulation`.

Good to know
------------

* Frames are matched first in, first out. For out-of-order or filtered traffic, write a subscriber of
  your own.

Related recipes
---------------

* :doc:`../cookbook/monitors`: *Wait for one frame to be checked*, *Get the frames a monitor received*,
  *Get every frame as a message*

API reference
-------------

:vhdl:`ethernet_pkg.check_ethernet_frame`, :vhdl:`ethernet_pkg.check_ethernet_sequence`,
:vhdl:`ethernet_pkg.pop_ethernet_frame`, :vhdl:`ethernet_pkg.ethernet_frame_msg`
