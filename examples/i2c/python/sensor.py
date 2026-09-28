# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""A temperature sensor for the I2C target of examples/i2c."""

# docs-start: sensor-model
from awesome_vunit_vcs.i2c import I2cDevice


class TemperatureSensor(I2cDevice):
    """
    Register 0 holds the temperature in 1/256 degrees Celsius, two bytes, most significant first.
    Register 1 is a configuration byte; writing 1 to it starts a conversion that takes 100 us, during
    which the sensor does not acknowledge its address.
    """

    def __init__(self, celsius: float = 21.5) -> None:
        super().__init__()
        self.temperature = round(celsius * 256)
        self.config = 0
        self.register = 0
        self.busy_until_fs = 0
        self._first_byte = True

    def start(self, address: int, read: bool, now_fs: int) -> bool:
        self._first_byte = not read
        self._read_index = 0
        return now_fs >= self.busy_until_fs

    def write(self, value: int, now_fs: int) -> bool:
        if self._first_byte:
            self._first_byte = False
            self.register = value
            return value in (0, 1)
        if self.register == 1:
            self.config = value
            if value == 1:
                self.busy_until_fs = now_fs + 100_000_000_000
        return True

    def read(self, now_fs: int) -> int:
        if self.register == 1:
            return self.config
        value = self.temperature.to_bytes(2, "big")[self._read_index % 2]
        self._read_index += 1
        return value


# docs-end: sensor-model
