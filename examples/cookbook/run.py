# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Cookbook
--------

One short test case per common construct, for the Examples library in the
documentation: sending frames, checking them, negative tests, statistics,
captures, subscribers, resets and the MII, RGMII, RMII and XGMII interfaces.
"""

import os
from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

# docs-start: python-path
# The packet and sequence functions in python/ are imported by name in the simulator
os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, [str(ROOT / "python"), os.environ.get("PYTHONPATH")]))
# docs-end: python-path

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "*.vhd")

# docs-start: interface-configs
tb = lib.test_bench("tb_cookbook_interfaces")
tb.add_config(
    name="low_rates",
    generics={
        "mii_link_rate_mbps": 10,
        "rgmii_link_rate_mbps": 100,
        "rmii_link_rate_mbps": 10,
        "xgmii_lanes": 4,
        "xgmii_link_rate_mbps": 10_000,
    },
)
tb.add_config(
    name="high_rates",
    generics={
        "mii_link_rate_mbps": 100,
        "rgmii_link_rate_mbps": 1000,
        "rmii_link_rate_mbps": 100,
        "xgmii_lanes": 8,
        "xgmii_link_rate_mbps": 400_000,
    },
)
# docs-end: interface-configs

if __name__ == "__main__":
    vu.main()
