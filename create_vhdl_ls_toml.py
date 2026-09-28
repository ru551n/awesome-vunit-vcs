# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Write vhdl_ls.toml for the VHDL language server (rust_hdl).

The libraries come from VUnit the way the run scripts add them, so the file
points at the installed VUnit, OSVVM and bridge sources of the active
environment. The testbenches and examples all go in ``lib``. Run it again after
changing environment.
"""

from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent
OWN = {"awesome_vunit_vcs", "lib"}

vu = VUnit.from_argv(argv=["--output-path", str(ROOT / "vunit_out")])
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_osvvm()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

libraries: dict[str, list[str]] = {}
for source_file in vu.get_source_files():
    libraries.setdefault(source_file.library.name, []).append(str(Path(source_file.name).resolve()))
libraries["lib"] = [
    str(ROOT / "tests" / "vhdl" / "**" / "*.vhd"),
    str(ROOT / "examples" / "**" / "*.vhd"),
]

lines = ["[libraries]"]
for name, files in sorted(libraries.items()):
    lines.append(f"{name}.files = [")
    lines += [f'    "{file}",' for file in sorted(files)]
    lines.append("]")
    if name not in OWN:
        lines.append(f"{name}.is_third_party = true")
(ROOT / "vhdl_ls.toml").write_text("\n".join(lines) + "\n")
print(f"Wrote {ROOT / 'vhdl_ls.toml'}")
