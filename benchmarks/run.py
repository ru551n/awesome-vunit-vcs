# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Bridge benchmark of the GMII monitor.

Run one configuration at a time, so they do not compete for CPU, and collect
the ``BENCHMARK`` lines::

    python benchmarks/run.py -p 1 -v | grep BENCHMARK
"""

from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

# Largest batch_length, so only the end of a frame flushes
WHOLE_FRAME = 2**31 - 1

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge")
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("bench")
lib.add_source_files(ROOT / "*.vhd")

tb = lib.test_bench("tb_bridge_benchmark")
configs = {
    "no_monitor": {"with_monitor": False},
    "per_cycle": {"batch_length": 1, "flush_at_frame_end": False},
    "whole_frame": {"batch_length": WHOLE_FRAME, "flush_at_frame_end": True},
    "batched": {"batch_length": 4096, "flush_at_frame_end": False},
    "batched_with_protocol_checker": {"batch_length": 4096, "flush_at_frame_end": False, "with_protocol_checker": True},
}
for name, generics in configs.items():
    tb.add_config(name=name, generics={"config_name": name, **generics})

getters = lib.test_bench("tb_property_getters")
for reads in (0, 50):
    getters.add_config(name=f"reads_{reads}", generics={"reads": reads})

if __name__ == "__main__":
    vu.main()
