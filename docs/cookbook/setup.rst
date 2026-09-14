Setup
=====

How do I write the run script?
------------------------------

**Goal:** add VUnit, the Python bridge and awesome-vunit-vcs to a VUnit project.

.. literalinclude:: ../../examples/quickstart/run.py
   :language: python
   :start-after: # docs-start: run-script
   :end-before: # docs-end: run-script

**When to use this:** in every project that uses the components.

* Keep ``add_verification_components()``: the components need it.
* Add both packages by name; never point at installed VHDL files.

**Full example:** :repo-file:`examples/quickstart/run.py`

.. code-block:: console

   $ python examples/quickstart/run.py

**See also:** :doc:`../getting_started/vunit_integration`

How do I make the components visible in a testbench?
----------------------------------------------------

**Goal:** one context clause gives a testbench everything it needs.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: context
   :end-before: -- docs-end: context

**When to use this:** at the top of every testbench file that uses the Ethernet components.

* The context already includes ``std_logic_1164`` and VUnit's contexts, so you need no other clauses.

**Full example:** :repo-file:`examples/cookbook/tb_cookbook.vhd`

**See also:** :doc:`../getting_started/vunit_integration`

How do I create a source and a monitor?
---------------------------------------

**Goal:** declare the handles that the entities and procedures use.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: handles
   :end-before: -- docs-end: handles
   :dedent:

**When to use this:** once per interface you drive or watch.

* Declare handles as constants in the architecture; pass them to the entity and to every procedure.
* Use ``default_gmii_protocol_checker`` unless you need custom limits; without a protocol checker a
  monitor checks nothing.
* Pass ``id => get_id("tb:rx")`` when the log should name the component.

**Full example:** :repo-file:`examples/cookbook/tb_cookbook.vhd`

**See also:** :doc:`../ethernet/monitors`

How do I structure the tests?
-----------------------------

**Goal:** one VUnit test case per behaviour.

.. literalinclude:: ../../examples/cookbook/tb_cookbook.vhd
   :language: vhdl
   :start-after: -- docs-start: test-structure
   :end-before: -- docs-end: test-structure
   :dedent:

**When to use this:** in every testbench; each ``run("test_...")`` branch is a test VUnit runs on its
own.

* Name tests after the behaviour they check, such as ``test_bad_fcs_is_counted``.
* Call ``test_runner_cleanup(runner)`` after the loop.

**Full example:** :repo-file:`examples/cookbook/tb_cookbook.vhd`

**See also:** `VUnit run library <https://vunit.github.io/run/user_guide.html>`__
