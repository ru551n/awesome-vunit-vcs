Conventions
===========

Code and documentation in this repository follow VUnit's conventions for verification components,
plus the style rules below.

VHDL components
---------------

Components should feel like VUnit's own verification components:

* A handle record with private ``p_`` fields around a ``std_cfg_t``, created by a ``new_*`` function
  with ``id``, the component options and ``unexpected_msg_type_policy``.
* Accessors ``get_id``, ``get_logger``, ``get_checker`` and ``as_sync``, with
  ``wait_until_idle(net, as_sync(vc))`` from ``sync_pkg`` supported.
* Procedures taking ``signal net : inout network_t`` that send ``com`` messages, and message types
  created with ``new_msg_type``.
* A ``<family>_pkg`` with the handles and procedures, and a ``<family>_context`` that a testbench
  uses.
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
     - Ethernet data is counted in *octets*, never bytes. Frame lengths, gaps and offsets are in
       octets.
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
     - Names of VHDL and Python objects are set as code: ``send_ethernet_frame``, ``EthernetFrame``.

Pages are written in reStructuredText. Admonitions are used sparingly and consistently: ``warning``
for unreleased dependencies, ``note`` for limitations, ``tip`` for performance and tooling hints, and
``important`` for steps a test must not skip.
