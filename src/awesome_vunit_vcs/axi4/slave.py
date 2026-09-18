# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The decisions of an AXI4 read or write slave: what a burst reads or writes and what it responds.

The VHDL slaves (``axi4_read_slave``, ``axi4_write_slave``) drive the handshakes and the timing. For
every burst they ask an :class:`Axi4Slave` which bytes each beat moves, whether the memory allows it
and which response to give. Everything is simulator independent and works on a
:class:`~awesome_vunit_vcs.axi4.memory_model.MemoryModel`.

Byte lanes are numbered from 0, the lane of RDATA[7:0] and WDATA[7:0].
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from .burst import BurstType, beat_addresses, beat_lanes, crosses_4k
from .errors import Axi4ValueError
from .memory_model import MemoryModel
from .transaction import Response

__all__ = ["Axi4Slave", "SlaveBurst", "SlaveRead"]


@dataclass(frozen=True)
class SlaveBurst:
    """
    A burst a slave accepted.

    Attributes:
        id: AxID.
        address: AxADDR.
        len: AxLEN; the burst has ``len + 1`` beats.
        size: AxSIZE; a beat has ``2 ** size`` bytes.
        burst: AxBURST.
        index: The number of bursts with this ID the slave accepted before, as VUnit numbers them in
            messages (``#0 for id 2``).
        supported: False for a burst the slave does not serve, answered with SLVERR.
    """

    id: int
    address: int
    len: int
    size: int
    burst: int
    index: int
    supported: bool = True

    def describe(self) -> str:
        """``#<index> for id <id>``, the name of a burst in messages."""
        return f"#{self.index} for id {self.id}"


@dataclass(frozen=True)
class SlaveRead:
    """
    The beats of a read burst.

    Attributes:
        resps: RRESP of every beat.
        data: For every beat (row), the byte of each lane (column), -1 for a lane the beat does not use.
        failures: The failures to report.
    """

    resps: npt.NDArray[np.int32]
    data: npt.NDArray[np.int32]
    failures: list[str]


class Axi4Slave:
    """
    One AXI4 read or write slave on a memory.

    Args:
        memory: The memory, which other slaves and the testbench may share.
        data_width: The width of RDATA or WDATA in bits.
        is_write: A write slave; a read slave otherwise.
        check_4kbyte_boundary: Fail on INCR bursts crossing a 4 KB boundary.

    Attributes:
        memory: The memory.
        check_4kbyte_boundary: Fail on INCR bursts crossing a 4 KB boundary.
        burst_lengths: The number of bursts accepted of each length in beats, the statistics of VUnit's
            ``axi_statistics_t``.

    Raises:
        Axi4ValueError: The data width is not a multiple of 8.
    """

    def __init__(
        self, memory: MemoryModel, data_width: int, is_write: bool, check_4kbyte_boundary: bool = True
    ) -> None:
        if data_width <= 0 or data_width % 8:
            raise Axi4ValueError(f"The data width {data_width} is not a positive multiple of 8")
        self.memory = memory
        self.data_bytes = data_width // 8
        self.is_write = is_write
        self.check_4kbyte_boundary = check_4kbyte_boundary
        self.burst_lengths: Counter[int] = Counter()
        self._indexes: Counter[int] = Counter()

    def reset(self) -> None:
        """Start numbering the bursts of every ID from 0 again."""
        self._indexes.clear()

    def accept(self, id_: int, address: int, len_: int, size: int, burst: int) -> tuple[SlaveBurst, list[str]]:
        """
        Accept a burst at its address handshake: count it and check what the slave supports.

        Returns:
            The burst, and the failures: a reserved burst type, a beat wider than the bus, a WRAP burst
            of an illegal length or alignment (these make the burst unsupported), and a 4 KB crossing.
        """
        index = self._indexes[id_]
        self._indexes[id_] += 1
        self.burst_lengths[len_ + 1] += 1
        kind = "write burst" if self.is_write else "read burst"
        name = f"{kind} #{index} for id {id_}"
        failures = []
        beat_bytes = 1 << size
        if burst == BurstType.RESERVED:
            failures.append(f"Unsupported burst type 0b11 (reserved) of {name}")
        elif beat_bytes > self.data_bytes:
            failures.append(f"The {beat_bytes} byte beats of {name} are wider than the {self.data_bytes} byte bus")
        elif burst == BurstType.WRAP and (len_ + 1 not in (2, 4, 8, 16) or address % (1 << size)):
            failures.append(f"Unsupported wrapping {name}: {len_ + 1} beats of {beat_bytes} bytes from {address}")
        supported = not failures
        if self.check_4kbyte_boundary and crosses_4k(address, len_, size, burst):
            first = address // (1 << size) * (1 << size)
            last = first + (len_ + 1) * (1 << size) - 1
            failures.append(
                f"Crossing 4KByte boundary. First page = {first // 4096} ({first}/4096), "
                f"last page = {last // 4096} ({last}/4096)"
            )
        return SlaveBurst(id_, address, len_, size, burst, index, supported), failures

    def _lanes(self, burst: SlaveBurst) -> tuple[int, npt.NDArray[np.int64], npt.NDArray[np.bool_]]:
        """
        The address of every lane of every beat (beats by lanes) as an origin plus offsets, since a
        64-bit address does not fit an int64, and whether the beat uses the lane.
        """
        lane = np.arange(self.data_bytes, dtype=np.int64)
        addresses = beat_addresses(burst.address, burst.len, burst.size, burst.burst)
        bounds = np.array(beat_lanes(burst.address, burst.len, burst.size, burst.burst, self.data_bytes))
        bases = [address // self.data_bytes * self.data_bytes for address in addresses]
        origin = min(bases)
        offsets = np.array([base - origin for base in bases], dtype=np.int64)[:, None] + lane[None, :]
        active = (lane[None, :] >= bounds[:, :1]) & (lane[None, :] <= bounds[:, 1:])
        return origin, offsets, active

    def read(self, burst: SlaveBurst) -> SlaveRead:
        """
        Read the data of every beat of a burst, checking the permissions.

        A beat with a byte the slave may not read gets SLVERR and reads 0 there; an unsupported burst
        SLVERR on every beat and no data.
        """
        beats = burst.len + 1
        if not burst.supported:
            return SlaveRead(
                np.full(beats, Response.SLVERR, dtype=np.int32),
                np.full((beats, self.data_bytes), -1, dtype=np.int32),
                [],
            )
        origin, addresses, active = self._lanes(burst)
        # The bytes of a legal burst are one contiguous range: read it and its permissions at once.
        first = int(addresses[active].min())
        length = int(addresses[active].max()) + 1 - first
        allowed, failures = self.memory.access(origin + first, length, reading=True)
        data = np.frombuffer(self.memory.data.read(origin + first, length), dtype=np.uint8)
        offsets = np.where(active, addresses - first, 0)
        lane_allowed = allowed[offsets] | ~active
        values = np.where(active, data[offsets].astype(np.int32) * allowed[offsets], -1).astype(np.int32)
        resps = np.where(lane_allowed.all(axis=1), Response.OKAY, Response.SLVERR).astype(np.int32)
        return SlaveRead(resps, values, failures)

    def write(
        self, burst: SlaveBurst, data: npt.NDArray[np.integer], strobes: npt.NDArray[np.bool_]
    ) -> tuple[Response, list[str]]:
        """
        Write the strobed bytes of every beat of a burst, checking permissions and expected data.

        Like VUnit, a strobed byte is written at the address of its lane in the bus aligned beat, and a
        later beat to the same address wins.

        Args:
            burst: The burst.
            data: For every beat (row), the byte of each lane (column).
            strobes: For every beat, WSTRB of each lane.

        Returns:
            BRESP, SLVERR when a strobed byte could not be written or the burst is unsupported, and the
            failures.
        """
        if not burst.supported:
            return Response.SLVERR, []
        origin, addresses, _ = self._lanes(burst)
        addresses = addresses[: len(data)]
        if not strobes.any():
            return Response.OKAY, []
        first = int(addresses[strobes].min())
        length = int(addresses[strobes].max()) + 1 - first
        buffer = np.zeros(length, dtype=np.uint8)
        written = np.zeros(length, dtype=np.bool_)
        offsets = addresses - first
        # Beat by beat, so a later beat of a FIXED burst wins
        for row in range(len(data)):
            buffer[offsets[row][strobes[row]]] = data[row][strobes[row]]
            written[offsets[row][strobes[row]]] = True
        allowed, failures = self.memory.access(origin + first, length, reading=False, touched=written)
        failures += self.memory.write(origin + first, buffer.tobytes(), written & allowed, skip_mismatches=False)
        return (Response.SLVERR if (written & ~allowed).any() else Response.OKAY), failures
