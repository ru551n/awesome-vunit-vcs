"""A user device model for tb_i2c: reads return twice the last byte written."""

from __future__ import annotations

from awesome_vunit_vcs.i2c import I2cDevice


class Doubler(I2cDevice):
    def __init__(self, offset: int = 0) -> None:
        super().__init__()
        self.value = offset

    def write(self, value: int, now_fs: int) -> bool:
        self.value = value
        return True

    def read(self, now_fs: int) -> int:
        return (2 * self.value) & 0xFF
