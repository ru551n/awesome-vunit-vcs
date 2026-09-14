Performance
===========

Calls between VHDL and Python are the main cost of a component with a Python backend. This page
records how much a GMII monitor costs, how that cost depends on the way samples are transferred, and
how to reproduce the measurement.

Bridge benchmark
----------------

**Setup.** A GMII source sends 200 frames of 1500 octets, about 302,600 valid samples, observed by a
monitor in each configuration. Wall clock time is measured in Python around the traffic, one
configuration at a time.

**Environment.** Measured on 2026-09-14 with GHDL 7.0.0-dev (mcode backend), NVC 1.23-devel, CPython
3.12, VUnit ``feature/package-setup-hooks`` (1ecac00) and vunit-python-bridge (28ff9b4), on a Linux
workstation. Absolute numbers depend on the machine; the ratios are what matters.

.. list-table:: Wall clock time in seconds
   :header-rows: 1
   :widths: 34 10 10 23 23

   * - Configuration
     - GHDL
     - NVC
     - Monitor cost, GHDL
     - Monitor cost, NVC
   * - No monitor
     - 1.84
     - 0.81
     -
     -
   * - Batched, 4096 samples per call
     - 2.32
     - 0.96
     - +0.48 (1.6 µs per sample)
     - +0.15 (0.5 µs per sample)
   * - Whole frame, one call per frame
     - 2.33
     - 0.97
     - +0.49
     - +0.16
   * - One call per clock cycle
     - 16.55
     - 10.32
     - +14.7 (48 µs per call)
     - +9.5 (31 µs per call)

What the numbers mean
---------------------

* **One call per clock cycle costs 30 to 60 times as much as batching.** A bridge call costs tens of
  microseconds, which is far more than the work done per sample.
* **Batched and whole-frame transfers cost the same** at this frame size. Batching wins anyway
  because its memory use is bounded for jumbo frames and long runs of traffic.
* **A monitor adds well under a second per 300,000 samples** with the defaults, on both simulators.

The monitor defaults follow from this: ``batch_length => 4096`` and ``flush_at_frame_end => true``.
Every frame is checked as soon as it ends, so a violation is logged at a simulation time close to the
frame that caused it.

Tuning
------

``batch_length``
    Samples per bridge call. Larger batches save little once calls are rare; smaller batches only
    cost time. The default suits almost every testbench.

``flush_at_frame_end``
    Flush after every frame. Turn it off only for very small frames at very high rates, where a check
    result a few frames later is acceptable.

``delta_unit``
    The time unit of sample deltas, 1 ps by default. It limits the timestamp resolution of IFG and
    rate measurements, not the speed of the monitor.

Idle periods cost almost nothing: a monitor records a sample only when data is valid, the word
changes or an error or metavalue bit is set.

Components that must respond to a bus call their backend once per transfer unit instead of batching.
They measure that cost the same way and report it with the component.

Reproducing the benchmark
-------------------------

The benchmark is in ``benchmarks/`` and is not part of CI. It runs the testbench
``tb_bridge_benchmark`` in four configurations (``no_monitor``, ``per_cycle``, ``whole_frame`` and
``batched``). Run one configuration at a time, so they do not compete for CPU, and collect the
``BENCHMARK`` lines:

.. code-block:: bash

    VUNIT_SIMULATOR=ghdl python benchmarks/run.py -p 1 -v | grep BENCHMARK
    VUNIT_SIMULATOR=nvc python benchmarks/run.py -p 1 -v | grep BENCHMARK
