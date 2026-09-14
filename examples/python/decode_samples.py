# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Decode the sample words a VHDL monitor records, on any interface.

An Interface turns frames into Samples, the words and femtosecond times a VHDL
monitor sends to Python, and decode runs them through the same pipeline.
"""

from awesome_vunit_vcs import ethernet as eth

frames = [eth.Frame.from_payload(bytes(100)), eth.Frame.from_payload(b"hello")]

for interface in (eth.GMII, eth.MII.with_rate("10M"), eth.XGMII(lanes=8, rate="100G")):
    samples = interface.encode(frames)
    result = eth.decode(interface, samples)
    # What was sent is what is received, padded to the minimum frame size
    assert result.ok and result.frames == tuple(frame.padded() for frame in frames)
    print(f"{interface.name} x{interface.lanes}: {len(samples)} samples, {len(result.frames)} frames")

# Samples recorded elsewhere, as words and times in femtoseconds
recorded = eth.Samples.from_arrays(samples.words.tolist(), samples.times.tolist())
assert eth.decode(eth.XGMII(lanes=8, rate="100G"), recorded).frames[1].payload == b"hello" + bytes(41)
assert eth.fs("8 ns") == eth.GMII.clock_period_fs
