Conventions
===========

Code and documentation in this repository follow VUnit's conventions for verification components,
plus the style rules below.

VHDL components
---------------

Components should feel like VUnit's own verification components (VCs). The Ethernet VCs follow
``axi_stream_pkg`` and ``vc_pkg`` of VUnit, and every family does the same:

* **One handle type per VC**, such as ``gmii_source_t``, ``gmii_monitor_t`` and
  ``gmii_protocol_checker_t``: a record of private ``p_`` fields created by ``new_<vc name>``. The
  entity takes the handle as its only generic and sizes its ports with accessor functions such as
  ``data_length``; entities never read ``p_`` fields.
* **Constructor parameters** are the VC configuration, then ``id : id_t := null_id``,
  ``logger : logger_t := null_logger``, ``actor : actor_t := null_actor``,
  ``checker : checker_t := null_checker`` and
  ``unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail``.
* **Identity** is resolved like ``vc_pkg.create_std_cfg``. A null id becomes
  ``awesome_vunit_vcs:<vc name>:<n>`` (``enumerate``). A null logger is the logger of the id, a null
  actor a new actor of the id (an id that already has an actor is an error), a null checker a new
  checker reporting to the logger. The accessors are ``get_id``, ``get_logger``, ``get_actor`` and
  ``get_checker``.
* **Inherited ids**: a sub-VC handle given to a parent constructor, such as the protocol checker of a
  monitor, is rebuilt with the id ``<parent id>:<name>`` (``protocol_checker``). Its logger, actor
  and checker derive from that id unless they were given explicitly, so logs trace through the
  entities, for example ``tb_gmii:monitor:protocol_checker``.
* **Python sessions**: the backend of a VC is the object ``vc`` in the Python session of its id,
  created with ``new_vc_session(get_id(handle), get_logger(handle))`` from ``vc_python_pkg``. That
  function is also the guard every family inherits: a second session for the same id is a failure on
  the logger, since the two VCs would share one backend. Families do not keep their own copy.
* **Protocol checks** run in a separate ``<interface>_protocol_checker`` entity, which a monitor
  instantiates when its handle has one, as ``axi_stream_monitor`` does. The monitor keeps the
  scoreboard.
* **Standard VCIs** where they apply: ``as_sync`` (``wait_until_idle``, ``wait_for_time``) for every
  VC, ``as_stream`` for stream masters and slaves, and the family VCI, such as
  ``as_ethernet_monitor``. Every VC handles ``reset(net, handle)``, which also returns when the VC
  waits for a stopped clock.
* **Procedures** take ``signal net : inout network_t`` and send ``com`` messages. A procedure that
  returns a value blocks, and has a non-blocking overload with a reference and an
  ``await_<procedure>_reply`` procedure.
* **Message types** are verb first and family scoped, ``push_ethernet_frame_msg`` created with
  ``new_msg_type("push ethernet frame")``, and a request with a reply has a ``*_reply_msg`` type. A
  message no handler takes is a check failure on the checker of the VC,
  ``Got unexpected message <name>``, unless the policy is ``ignore``.
* **Packages**: a ``<family>_pkg`` or ``<interface>_pkg`` with the handles and procedures, and one
  ``<family>_context`` that is the only context clause a testbench needs.
* Errors a VC detects go to its checker, everything else to its logger.
* The MPL-2.0 license header at the top of every file.

VHDL style
----------

* Names are ``lower_snake_case`` without prefixes: no ``g_``, ``c_``, ``C_``, ``v_`` or ``p_`` on
  generics, constants, variables or processes. Types and subtypes end in ``_t``, and enumeration
  literals are lowercase. The private ``p_`` record fields above are VUnit's convention and the only
  exception.
* Architectures are named ``a`` for components and ``tb`` for testbenches. The main process is
  ``main``, and instance labels end in ``_inst``.
* Declarations, generic maps and port maps are not column aligned.
* Public declarations, and non-obvious generics and ports, have a ``--`` comment directly above them.
* Ports are ``std_ulogic`` and ``std_ulogic_vector``. VUnit's own VCs use ``std_logic``, which is
  compatible when a testbench connects them to resolved signals; unresolved types catch multiple
  drivers at elaboration.
* Integer counts in simulation-only code may be unconstrained ``natural``. Range constraints matter
  for synthesizable code, such as example DUTs.
* Code is VHDL-2008. No unfinished ``--@`` markers in merged code.

Python style
------------

* Formatted and linted with ruff (line length 120), which also formats Python code blocks in Markdown
  files. The ruff version is pinned in ``pyproject.toml``, so formatting changes only on purpose.
* Type checked with mypy in strict mode.
* Compatible with Python 3.10.
* Dataclasses and explicit types rather than unstructured dictionaries, small public APIs listed in
  ``__all__``, and no global mutable state.
* Google style docstrings for every public name.

Documentation style
-------------------

Consistent terms make the documentation read as one text. Use these in docs, docstrings, comments and
log messages:

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Topic
     - Rule
   * - Octet
     - Ethernet data is counted in *octets*. Frame lengths, gaps and offsets are in octets.
   * - Frame and wire octets
     - *Frame octets* are the octets from the destination address up to and including the FCS
       (``mac_octets`` in Python). *Wire octets* also include the preamble and SFD. The *payload* is
       what follows the 14-octet header.
   * - Times
     - Logs and APIs give simulation times in femtoseconds (``fs``). Prose may use ns or ps, always
       with the unit.
   * - Rates
     - Link rates are in Mbit/s in VHDL (``link_rate_mbps``) and bit/s in Python
       (``link_rate_bps``).
   * - Check IDs
     - A short family prefix and the check, ``<family>_<check>``: lowercase enumeration literals in
       VHDL (``eth_fcs``), upper case in logs and in Python ``CheckId`` (``ETH_FCS``).
   * - Monitor and source
     - A *monitor* observes an interface without driving it. A *source* drives traffic into the
       design. Not sink, driver or BFM.
   * - VC
     - Write *verification component (VC)* on first use in a page.
   * - Code names
     - Names of VHDL and Python objects are set as code: ``push_ethernet_frame``, ``Frame``.

Pages are written in reStructuredText. Admonitions are used sparingly and consistently: ``warning``
for unreleased dependencies, ``note`` for limitations, ``tip`` for performance and tooling hints, and
``important`` for steps a test must not skip.
