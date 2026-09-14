Scoreboard and received frames
==============================

A monitor offers three ways to use the frames it receives: compare them with expected frames, read
them in the testbench, or subscribe to them.

Expecting frames
----------------

.. code-block:: vhdl

   check_ethernet_frame(net, monitor, frame, blocking => false);  -- queue and continue
   check_ethernet_frame(net, monitor, frame);                     -- wait until checked
   check_ethernet_frame(net, monitor, frame, msg => "frame 3");   -- with context

Expected frames are compared with received frames in order. ``frame`` is the frame data from the
destination address up to, not including, the FCS; a received frame padded up to ``min_frame_octets``
matches its unpadded expectation. A difference is an ``ETH_SCOREBOARD`` error on the monitor's checker.
Expected frames that never arrive are reported at ``test_runner_cleanup``.

Queue expectations with ``blocking => false`` before pushing the frames, as in the
:doc:`../getting_started/quickstart`, so the check never waits on a frame that has not been sent.

For long traffic, ``check_ethernet_sequence`` expects the frames of a Python generator; see
:doc:`packets_and_sequences`.

Reading frames
--------------

.. code-block:: vhdl

   variable data : std_ulogic_vector(0 to 8 * 1518 - 1);
   variable length : natural;
   variable fcs_ok : boolean;
   ...
   pop_ethernet_frame(net, monitor, data, length, fcs_ok);   -- waits for the next frame

``length`` is the number of frame octets written to ``data``. Frames are kept only while a pop is
pending, so start the pop before the frame arrives. The monitor's stream slave interface does the same
octet by octet: ``pop_stream(net, as_stream(monitor), octet, last)``.

Subscribing
-----------

While a monitor has subscribers it publishes every frame as an ``ethernet_frame_msg``:

.. code-block:: vhdl

   subscribe(my_actor, get_actor(monitor));
   ...
   receive(net, my_actor, msg);
   pop_ethernet_frame(msg, data, length, fcs_ok);

In Python, the backend of the monitor offers ``vc.on_frame(function)`` and ``vc.frames``; see
:doc:`../python_guide`.

Limitations
-----------

Matching is first in, first out only. Out-of-order or filtered traffic needs a subscriber of its own.
