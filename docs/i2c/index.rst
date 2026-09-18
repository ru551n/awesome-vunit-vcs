I2C
===

The I2C family verifies designs on an I2C bus, following the I2C-bus specification (NXP UM10204) and,
for Packet Error Checking, SMBus 3. It has four verification components (:term:`VCs <VC>`) that share
one bus, so a test combines them as its design needs.

.. include:: ../_includes/vunit_names.inc

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - VC
     - Role
   * - :vhdl:`i2c_master`
     - A controller: writes, reads, writes followed by a read after a repeated START, and transfers
       written as operations for malformed traffic. Use it to test a target design.
   * - :vhdl:`i2c_target`
     - A target that answers at its address with a device model: a register map, a 24Cxx EEPROM or a
       Python class of your own. Use it to test a controller design.
   * - :vhdl:`i2c_monitor`
     - Observes the bus and reconstructs the transfers, for checks, pops, subscribers and statistics.
       Never drives.
   * - :vhdl:`i2c_protocol_checker`
     - Observes the bus and checks its timing and bit-level protocol against a speed mode. Never
       drives.

The VHDL components only drive and sample SCL and SDA. What the bits mean, from START conditions to
acknowledge decisions and device behavior, is decided by the Python package
``awesome_vunit_vcs.i2c``, which also works in plain ``pytest``.

What's here
-----------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What's here
   * - :doc:`i2c_master`, :doc:`i2c_target`, :doc:`i2c_monitor`, :doc:`i2c_protocol_checker`
     - One page per VC: pins, constructors, procedures and options
   * - :doc:`python`
     - Device models of your own, and the Python API without a simulator
   * - :doc:`vhdl_api`
     - Every VHDL package, context and entity of the family
   * - :doc:`python_api`
     - Every public Python name of ``awesome_vunit_vcs.i2c``

.. _i2c-quick-start:

The pattern
-----------

A testbench needs one context clause:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

``i2c_context`` makes ``i2c_pkg``, ``i2c_master_pkg``, ``i2c_target_pkg``, ``i2c_monitor_pkg`` and
``i2c_protocol_checker_pkg`` visible, together with ``ieee.std_logic_1164``, ``vunit_context``,
``com_context``, ``sync_pkg``, ``integer_array_pkg``, ``vc_pkg`` and the typed Python arguments of
``vc_python_pkg``.

Each VC is created with a handle in the architecture. Here a master, a temperature sensor modelled in
Python, a 24C02 EEPROM and a monitor with a protocol checker:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

I2C lines are open drain. Declare SCL and SDA as ``std_logic``, pull them up with ``'H'``, and connect
every VC and your design to the same two signals:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: bus
   :end-before: -- docs-end: bus
   :dedent:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: instances
   :end-before: -- docs-end: instances
   :dedent:

A test then talks to the targets through the master:

.. literalinclude:: ../../examples/i2c/tb_i2c_examples.vhd
   :caption: examples/i2c/tb_i2c_examples.vhd
   :language: vhdl
   :start-after: -- docs-start: read-register
   :end-before: -- docs-end: read-register
   :dedent:

The run script adds the bridge and the package, and puts the directory of the device model on the
Python path of the simulator:

.. literalinclude:: ../../examples/i2c/run.py
   :caption: examples/i2c/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

In a test of your design, the design takes the place of the master or of a target. A design with
separate output enables connects through two lines per signal: ``scl <= '0' when scl_oe = '1' else 'Z';``
drives the bus and ``scl_in <= to_x01(scl);`` reads it.

Combine the components on one bus
---------------------------------

.. code-block:: text
   :caption: One I2C bus

            'H'      'H'         pull-ups in the testbench
             |        |
     SCL ----+--------)-------+------------+------------+
     SDA -------------+-------)-+----------)-+----------)-+
                              | |          | |          | |
                         i2c_master    i2c_target    i2c_monitor
                          or a DUT      or a DUT     + protocol checker

* Several masters and targets can share a bus. Masters synchronize their clocks and arbitrate as the
  specification describes; :vhdl:`i2c_master_pkg.i2c_transfer` returns ``i2c_arbitration_lost`` to
  the master that lost.
* A protocol checker can be instantiated on any bus as an entity of its own, or passed to
  :vhdl:`i2c_monitor_pkg.new_i2c_monitor`, which then instantiates it on its own pins.
  :vhdl:`protocol_checker(monitor) <i2c_monitor_pkg.protocol_checker>` returns that checker, for
  ``set_check_enabled``, ``get_check_count`` and its logger.

Handles and identity
--------------------

Constructors take the VC configuration first, then the standard VUnit parameters ``id``, ``logger``,
``actor``, ``checker`` and ``unexpected_msg_type_policy``, all with defaults. The logger, actor and
checker of a component derive from its id unless they are passed explicitly.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Constructed with
     - Id
   * - No ``id``
     - ``awesome_vunit_vcs:<vc>:<n>``, where ``<vc>`` is ``i2c_master``, ``i2c_target``,
       ``i2c_monitor`` or ``i2c_protocol_checker`` and ``<n>`` numbers the default ids from 1
   * - ``id => get_id("tb:sensor")``
     - ``tb:sensor``
   * - A protocol checker without an explicit ``id``, passed to ``new_i2c_monitor``
     - ``<monitor id>:protocol_checker``. The logger, actor and checker that were not passed
       explicitly are derived from this id, and the checker uses up no default id.

* Two VCs with the same id are a failure on the logger of the second:
  ``Two verification components have the id tb:sensor and would share one Python backend``.
* ``get_id``, ``get_logger``, ``get_actor`` and ``get_checker`` return them.
* A message a VC does not handle is a check failure ``Got unexpected message <name>`` on its checker
  unless ``unexpected_msg_type_policy`` is ``ignore``.

Standard interfaces
-------------------

Every VC has ``as_sync(vc)``, VUnit's sync interface: ``wait_until_idle`` and ``wait_for_time``.

.. list-table::
   :widths: 25 75

   * - Master
     - ``wait_until_idle`` returns when every transfer requested before it is done.
   * - Target
     - ``wait_until_idle`` returns when every request sent before it is handled.
   * - Monitor, protocol checker
     - ``wait_until_idle`` returns when Python has processed everything sampled so far.

Procedures
----------

Every procedure takes ``net`` first. A procedure that returns nothing only sends a message, handled in
order. A procedure that returns a value blocks, and has a non-blocking form returning a reference,
read later with the matching ``await_`` procedure.

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Procedure
     - Page
   * - ``i2c_write``, ``i2c_read``, ``i2c_write_read``, ``i2c_transfer``
     - :doc:`i2c_master`
   * - ``set_i2c_target_stretch``, ``inject_i2c_target_nack``, ``i2c_target_preload``,
       ``i2c_target_check_memory``, ``i2c_target_read_memory``
     - :doc:`i2c_target`
   * - ``pop_i2c_transfer``, ``check_i2c_transfer``, ``get_i2c_statistics``
     - :doc:`i2c_monitor`
   * - ``set_check_enabled``, ``get_check_count``
     - :doc:`i2c_protocol_checker`
   * - ``reset``
     - Below

Recover a component with ``reset(net, vc)``:

.. list-table::
   :widths: 25 75

   * - Master
     - Releases SCL and SDA and takes the bus as free, also after a transaction left without a STOP.
       Transfers requested before the reset run first.
   * - Target
     - Releases SCL and SDA and forgets a transfer in progress. The device model keeps its memory.
   * - Monitor
     - Forgets a transaction in progress, the kept transfers and the expected ones; cancels pending
       pops. Keeps statistics unless ``clear_statistics => true``.
   * - Protocol checker
     - Sets its counts to 0 and forgets the timing history. Keeps its check switches.

Every declaration is listed in the :doc:`vhdl_api`.

.. toctree::
   :maxdepth: 1
   :hidden:

   i2c_master
   i2c_target
   i2c_monitor
   i2c_protocol_checker
   python
   vhdl_api
   python_api
