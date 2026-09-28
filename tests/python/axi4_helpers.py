# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Hand-built AXI4 sample words, written from the layout documented in ``awesome_vunit_vcs.axi4.bus`` and
independent of its code: a :class:`Recorder` writes the records the VHDL components would record, one
clock edge at a time.
"""

from __future__ import annotations

PERIOD_FS = 10_000_000  # 10 ns


def _signed(word: int) -> int:
    return word - (1 << 32) if word >= 1 << 31 else word


def pack(fields: list[tuple[int, int]]) -> list[int]:
    """``(value, bits)`` fields, first in the least significant bits, as 32-bit signed words."""
    value = 0
    offset = 0
    for field, bits in fields:
        assert 0 <= field < 1 << bits or (bits == 0 and field == 0), (field, bits)
        value |= field << offset
        offset += bits
    return [_signed((value >> (32 * index)) & 0xFFFFFFFF) for index in range((offset + 31) // 32)]


def header(
    kind: int,
    *,
    valid: bool = True,
    ready: bool = True,
    resetn: bool = True,
    valid_x: bool = False,
    ready_x: bool = False,
    payload_x: bool = False,
    resetn_x: bool = False,
    control: int = 0,
) -> int:
    return (
        kind
        | valid << 3
        | ready << 4
        | valid_x << 5
        | ready_x << 6
        | payload_x << 7
        | resetn << 8
        | resetn_x << 9
        | control << 10
    )


class Recorder:
    """The records of one interface; each method records at the current edge, :meth:`step` moves on."""

    def __init__(self, data_width: int = 32, address_width: int = 32, id_width: int = 4, user_width: int = 0) -> None:
        self.data_width = data_width
        self.address_width = address_width
        self.id_width = id_width
        self.user_width = user_width
        self.words: list[int] = []
        self.times: list[int] = []
        self.cycle = 0

    @property
    def now(self) -> int:
        return self.cycle * PERIOD_FS

    def step(self, cycles: int = 1) -> Recorder:
        self.cycle += cycles
        return self

    def _emit(self, words: list[int]) -> Recorder:
        self.words += words
        self.times += [self.now] * len(words)
        return self

    def take(self) -> tuple[list[int], list[int]]:
        words, times = self.words, self.times
        self.words, self.times = [], []
        return words, times

    # Control records
    def period(self, period_fs: int = PERIOD_FS) -> Recorder:
        return self._emit([header(5, valid=False, ready=False, control=1), period_fs // 1000])

    def reset(self, active: bool, resetn_x: bool = False) -> Recorder:
        return self._emit([header(5, valid=False, ready=False, resetn=not active, resetn_x=resetn_x, control=0)])

    def tick(self) -> Recorder:
        return self._emit([header(5, valid=False, ready=False, control=2)])

    # Channels
    def _address(self, kind: int, id: int, addr: int, len: int, size: int, burst: int, lock: int, cache: int,
                 prot: int, **flags: bool) -> Recorder:  # fmt: skip
        fields = [
            (id, self.id_width),
            (addr, self.address_width),
            (len, 8),
            (size, 3),
            (burst, 2),
            (lock, 1),
            (cache, 4),
            (prot, 3),
            (0, 4),
            (0, 4),
            (0, self.user_width),
        ]
        return self._emit([header(kind, **flags), *pack(fields)])

    def aw(self, id: int = 0, addr: int = 0, len: int = 0, size: int = 2, burst: int = 1, lock: int = 0,
           cache: int = 0, prot: int = 0, **flags: bool) -> Recorder:  # fmt: skip
        return self._address(0, id, addr, len, size, burst, lock, cache, prot, **flags)

    def ar(self, id: int = 0, addr: int = 0, len: int = 0, size: int = 2, burst: int = 1, lock: int = 0,
           cache: int = 0, prot: int = 0, **flags: bool) -> Recorder:  # fmt: skip
        return self._address(3, id, addr, len, size, burst, lock, cache, prot, **flags)

    def w(self, data: int, strb: int | None = None, last: bool = True, lane_x: int = 0, **flags: bool) -> Recorder:
        lanes = self.data_width // 8
        strobe = (1 << lanes) - 1 if strb is None else strb
        fields = [(data, self.data_width), (strobe, lanes), (int(last), 1), (0, self.user_width), (lane_x, lanes)]
        return self._emit([header(1, **flags), *pack(fields)])

    def b(self, id: int = 0, resp: int = 0, **flags: bool) -> Recorder:
        return self._emit([header(2, **flags), *pack([(id, self.id_width), (resp, 2), (0, self.user_width)])])

    def r(
        self, id: int = 0, data: int = 0, resp: int = 0, last: bool = True, lane_x: int = 0, **flags: bool
    ) -> Recorder:
        lanes = self.data_width // 8
        fields = [
            (id, self.id_width),
            (data, self.data_width),
            (resp, 2),
            (int(last), 1),
            (0, self.user_width),
            (lane_x, lanes),
        ]
        return self._emit([header(4, **flags), *pack(fields)])
