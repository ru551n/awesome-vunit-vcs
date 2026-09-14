# Architecture

**VHDL handles simulation timing. Python handles verification semantics.**

```text
 VHDL (simulation time)                          Python (no notion of simulation time)
 -------------------------------------           -------------------------------------------
 monitor entity                                  backend object (one per monitor, own session)
   sample the pins at the right edges              PHY decoder -> octet stream
   record samples, flush batches         ---->     frames -> checker, statistics, capture,
   log the reports it returns            <----               scoreboard, user subscribers
 source entity                                   backend object (one per source, own session)
   receive a com message                 ---->     build preamble, SFD, padding, FCS, errors
   drive one symbol per clock edge       <----     symbols as an integer_array_t
```

Python runs only when a VHDL process calls it and never touches a signal. VHDL never interprets a
frame. Every protocol decision is made once, in Python, on samples recorded with their exact
simulation times.

The full description lives in the documentation:

* [Architecture](https://awesome-vunit-vcs.readthedocs.io/en/latest/explanation/architecture.html):
  the boundary, sessions, sample batches, reports and the split per interface
  ([source](docs/explanation/architecture.rst)).
* [Design decisions](https://awesome-vunit-vcs.readthedocs.io/en/latest/explanation/design_decisions.html):
  VUnit package registration, why cocotb's simulator objects are not used, batching and bridge
  isolation ([source](docs/explanation/design_decisions.rst)).
* [Performance](https://awesome-vunit-vcs.readthedocs.io/en/latest/explanation/performance.html): the
  bridge benchmark and how to rerun it ([source](docs/explanation/performance.rst)).
* [Known limitations](https://awesome-vunit-vcs.readthedocs.io/en/latest/explanation/limitations.html)
  ([source](docs/explanation/limitations.rst)).
