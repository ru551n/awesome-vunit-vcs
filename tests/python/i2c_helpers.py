"""
Independent references for the I2C tests.

Nothing here imports the package under test. :class:`Bus` bit-bangs SCL and
SDA the way the I2C-bus specification draws its timing diagram, and records a
sample word (bit 0 SCL, bit 1 SDA) whenever a line changes, as the VHDL
monitor does. :func:`reference_pec` is a bitwise CRC-8 with the polynomial 0x07.
"""

from __future__ import annotations

from dataclasses import dataclass, field

NS = 1_000_000
US = 1_000 * NS


def reference_pec(data: bytes) -> int:
    """Bitwise CRC-8, polynomial x^8 + x^2 + x + 1, initial value 0, as SMBus specifies the PEC."""
    crc = 0
    for value in data:
        for bit in range(7, -1, -1):
            feedback = ((crc >> 7) & 1) ^ ((value >> bit) & 1)
            crc = (crc << 1) & 0xFF
            if feedback:
                crc ^= 0x07
    return crc


@dataclass
class Bus:
    """
    A bus master drawn by hand. Times in fs; the defaults are Fast-mode with some margin.

    Every method advances the time and records the samples of the lines it changes.
    """

    t_low: int = 1_300 * NS
    t_high: int = 1_200 * NS
    t_hd_dat: int = 300 * NS
    t_su_sta: int = 700 * NS
    t_hd_sta: int = 700 * NS
    t_su_sto: int = 700 * NS
    t_buf: int = 1_300 * NS
    time: int = 0
    scl: int = 1
    sda: int = 1
    words: list[int] = field(default_factory=list)
    times: list[int] = field(default_factory=list)

    def __post_init__(self) -> None:
        self._record()

    def _record(self) -> None:
        self.words.append(self.scl | self.sda << 1)
        self.times.append(self.time)

    def wait(self, duration: int) -> Bus:
        self.time += duration
        return self

    def set(self, scl: int | None = None, sda: int | None = None, after: int = 0) -> Bus:
        """Change lines together after a delay, recording a sample if one changed."""
        self.time += after
        new_scl = self.scl if scl is None else scl
        new_sda = self.sda if sda is None else sda
        if (new_scl, new_sda) != (self.scl, self.sda):
            self.scl, self.sda = new_scl, new_sda
            self._record()
        return self

    def metavalue(self, line: str, after: int = 0) -> Bus:
        """Record a sample with a metavalue on SCL or SDA; the line keeps its level."""
        self.time += after
        self.words.append(self.scl | self.sda << 1 | (4 if line == "scl" else 8))
        self.times.append(self.time)
        return self

    def start(self) -> Bus:
        if self.scl:
            self.set(sda=0)
        else:
            self.set(sda=1, after=self.t_hd_dat)
            self.set(scl=1, after=self.t_low - self.t_hd_dat)
            self.set(sda=0, after=self.t_su_sta)
        return self.set(scl=0, after=self.t_hd_sta)

    def bit(self, value: int) -> Bus:
        self.set(sda=value, after=self.t_hd_dat)
        self.set(scl=1, after=self.t_low - self.t_hd_dat)
        return self.set(scl=0, after=self.t_high)

    def byte(self, value: int, ack: bool = True) -> Bus:
        for bit in range(7, -1, -1):
            self.bit(value >> bit & 1)
        return self.bit(0 if ack else 1)

    def stop(self) -> Bus:
        self.set(sda=0, after=self.t_hd_dat)
        self.set(scl=1, after=self.t_low - self.t_hd_dat)
        self.set(sda=1, after=self.t_su_sto)
        return self.wait(self.t_buf)

    def write(self, address: int, data: bytes = b"", acks: list[bool] | None = None) -> Bus:
        """A complete 7-bit write; every byte acknowledged unless ``acks`` says otherwise."""
        acks = acks or [True] * (len(data) + 1)
        self.start().byte(address << 1, acks[0])
        for value, ack in zip(data, acks[1:], strict=True):
            self.byte(value, ack)
        return self.stop()
