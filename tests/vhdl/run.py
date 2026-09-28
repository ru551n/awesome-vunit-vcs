# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
HDL tests of awesome-vunit-vcs.

The packages are added the way a user adds them, so the tests also prove that
the installed VHDL library and Python backend modules are found without paths.
"""

import os
import sys
from pathlib import Path

from vunit import VUnit

from awesome_vunit_vcs.gen_vhdl import write_vhdl

ROOT = Path(__file__).parent

# The records of tb_records, generated from the dataclasses at build time; the
# package is rewritten only when it changes, so it is not recompiled needlessly
sys.path.insert(0, str(ROOT / "python"))
from record_types import Link  # noqa: E402

write_vhdl([Link], "record_types_pkg", ROOT / "generated" / "record_types_pkg.vhd")

# The device models of tb_i2c are imported by name in the simulator
os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, [str(ROOT / "python"), os.environ.get("PYTHONPATH")]))

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_osvvm()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "*.vhd")
lib.add_source_files(ROOT / "generated" / "*.vhd")

# The XGMII family: 4-lane single edge (32-bit SDR), 4-lane both edges
# (Clause 46 XGMII) and 8 lanes (64-bit variants, XLGMII, CGMII), and 8 lanes
# at 200 and 400 Gbit/s (200GMII, 400GMII)
tb_xgmii = lib.test_bench("tb_xgmii")
for lanes, both_edges, link_rate_mbps in (
    (4, False, 10000),
    (4, True, 10000),
    (8, False, 10000),
    (8, False, 200000),
    (8, False, 400000),
):
    tb_xgmii.add_config(
        name=f"{lanes}_lanes_{'both_edges' if both_edges else 'rising_edge'}"
        + (f"_{link_rate_mbps // 1000}g" if link_rate_mbps != 10000 else ""),
        generics={"lanes": lanes, "both_edges": both_edges, "link_rate_mbps": link_rate_mbps},
    )

# MII at both of its link rates
tb_mii = lib.test_bench("tb_mii")
for link_rate_mbps in (10, 100):
    tb_mii.add_config(name=f"{link_rate_mbps}_mbps", generics={"link_rate_mbps": link_rate_mbps})

tb_axis_mac = lib.test_bench("tb_axis_mac")
for bytes_per_beat, ready_high_percent, valid_low_percent in ((8, 100, 0), (1, 60, 20), (4, 70, 30)):
    tb_axis_mac.add_config(
        name=f"{bytes_per_beat}_bytes_ready_{ready_high_percent}_valid_low_{valid_low_percent}",
        generics={
            "bytes_per_beat": bytes_per_beat,
            "ready_high_percent": ready_high_percent,
            "valid_low_percent": valid_low_percent,
        },
    )

# RGMII at its three link rates with centered data, and at 1000 Mbit/s with edge aligned data
tb_rgmii = lib.test_bench("tb_rgmii")
for link_rate_mbps, edge_aligned in ((1000, False), (100, False), (10, False), (1000, True)):
    tb_rgmii.add_config(
        name=f"{link_rate_mbps}_mbps" + ("_edge_aligned" if edge_aligned else ""),
        generics={"link_rate_mbps": link_rate_mbps, "edge_aligned": edge_aligned},
    )

# RMII at both of its link rates
tb_rmii = lib.test_bench("tb_rmii")
for link_rate_mbps in (10, 100):
    tb_rmii.add_config(name=f"{link_rate_mbps}_mbps", generics={"link_rate_mbps": link_rate_mbps})

# The I2C loopback in each speed mode
tb_i2c_loopback = lib.test_bench("tb_i2c_loopback")
for speed_mode, name in enumerate(("standard", "fast", "fast_plus")):
    tb_i2c_loopback.add_config(name=name, generics={"speed_mode": speed_mode})

if __name__ == "__main__":
    vu.main()
