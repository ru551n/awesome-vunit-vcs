Architecture
============

.. note::

   This page is in progress. It will include ARCHITECTURE.md from the repository root.

The boundary between the languages is the central design decision: VHDL owns pin timing and
sampling, including the double edge semantics of RGMII, and sends batches of normalized
observations to Python. Python never accesses simulator signals.
