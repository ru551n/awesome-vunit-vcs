Glossary
========

.. glossary::
   :sorted:

   octet
      Eight bits of Ethernet data. The documentation counts Ethernet data in octets.

   frame octets
      A frame from the destination address up to and including the FCS. ``min_frame_octets`` and
      ``max_frame_octets`` count these.

   frame data
      What ``push_ethernet_frame`` and ``check_ethernet_frame`` take: the frame from the destination
      address up to, not including, the FCS.

   payload
      The octets after the 14-octet header (destination, source, EtherType), up to the FCS.

   wire octets
      Everything a frame occupies on the line: preamble, SFD, frame octets.

   preamble
      The ``0x55`` octets before the SFD; seven in a standard frame.

   SFD
      Start frame delimiter, the ``0xD5`` octet that ends the preamble.

   FCS
      Frame check sequence, the CRC-32 at the end of a frame.

   IFG
      Inter-frame gap: the idle octets between the end of a frame and the start of the next one.

   runt
      A frame shorter than ``min_frame_octets``.

   giant
      A frame longer than ``max_frame_octets``.

   column
      The data and control of all lanes of an XGMII interface in one clock edge.

   lane
      One octet and its control bit in an XGMII column; lane 0 is in the low bits.

   control character
      An XGMII octet with its control bit set: Idle, Start, Terminate, Error or Sequence.

   ordered set
      A Sequence control character on lane 0 followed by three data octets, such as a link fault.

   VC
      Verification component: a VHDL entity with a handle, controlled through VUnit's ``com`` messages.

   VCI
      Verification component interface, such as VUnit's sync and stream interfaces.

   handle
      The constant created by ``new_<vc>`` that identifies a VC; the only generic of its entity.

   source
      A VC that drives one direction of an interface with the frames a test pushes.

   monitor
      A VC that observes one direction of an interface and reconstructs, counts, compares and captures
      its frames. It never drives.

   protocol checker
      A VC that observes one direction of an interface and checks the protocol. A monitor can create one.

   subscriber
      A function or VUnit actor that a monitor notifies of every frame it receives: ``on_frame`` in Python,
      ``subscribe`` and ``ethernet_frame_msg`` in VHDL.

   scoreboard
      The comparison of received frames with the frames ``check_ethernet_frame`` expects.

   backend
      The Python object behind a VC, ``vc`` in the Python session of its id.

   session
      A Python namespace of the bridge, one per VC id, so VCs never share Python state.

   sample word
      What a monitor records per sample: the data, valid and error bits and metavalue flags.

   batch
      Sample words sent to Python in one bridge call, with their times.

   delta_unit
      The time resolution of the samples in a batch.

   packet function
      A Python function named ``"module:function"`` that returns a frame for ``push_ethernet_packet``.
