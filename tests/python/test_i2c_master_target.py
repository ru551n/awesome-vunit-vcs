"""The I2C master's transfers, the target engine and the device models."""

from __future__ import annotations

import pytest
from i2c_helpers import reference_pec

from awesome_vunit_vcs.i2c import (
    Eeprom24,
    I2cDevice,
    I2cStatus,
    I2cTarget,
    I2cValueError,
    RegisterDevice,
    compile_ops,
    compile_transfer,
)
from awesome_vunit_vcs.i2c.target import Action

# Operation words written out by hand: value | kind << 8 | flag << 11 | bits << 12
START, STOP = 0x000, 0x300


def WRITE(value: int, abort: bool = True) -> int:
    return value | 0x100 | (0x800 if abort else 0)


def READ(ack: bool) -> int:
    return 0x200 | (0x800 if ack else 0)


# Master transfers
def test_a_write() -> None:
    assert compile_transfer(0x50, [0x12, 0x34]).words == (START, WRITE(0xA0), WRITE(0x12), WRITE(0x34), STOP)


def test_an_address_alone_and_no_stop() -> None:
    assert compile_transfer(0x50).words == (START, WRITE(0xA0), STOP)
    assert compile_transfer(0x50, [1], stop=False).words == (START, WRITE(0xA0), WRITE(0x01))


def test_a_read_acknowledges_all_but_the_last_byte() -> None:
    assert compile_transfer(0x48, num_read=3).words == (START, WRITE(0x91), READ(True), READ(True), READ(False), STOP)


def test_a_write_then_read() -> None:
    words = compile_transfer(0x50, [0x07], 1).words
    assert words == (START, WRITE(0xA0), WRITE(0x07), START, WRITE(0xA1), READ(False), STOP)


def test_ten_bit_addresses() -> None:
    assert compile_transfer(0x2A5, [0x11], ten_bit=True).words == (START, WRITE(0xF4), WRITE(0xA5), WRITE(0x11), STOP)
    read = compile_transfer(0x2A5, num_read=1, ten_bit=True).words
    assert read == (START, WRITE(0xF4), WRITE(0xA5), START, WRITE(0xF5), READ(False), STOP)
    write_read = compile_transfer(0x2A5, [0x01], 1, ten_bit=True).words
    assert write_read == (START, WRITE(0xF4), WRITE(0xA5), WRITE(0x01), START, WRITE(0xF5), READ(False), STOP)


def test_pec_is_appended_to_a_write_and_read_after_a_read() -> None:
    words = compile_transfer(0x50, [0x10, 0x55], pec=True).words
    assert words[-2] == WRITE(reference_pec(bytes([0xA0, 0x10, 0x55])))
    words = compile_transfer(0x50, [0x10], 2, pec=True).words
    assert words[-4:] == (READ(True), READ(True), READ(False), STOP)


def test_invalid_transfers() -> None:
    with pytest.raises(I2cValueError):
        compile_transfer(0x80)
    with pytest.raises(I2cValueError):
        compile_transfer(0x400, ten_bit=True)
    with pytest.raises(I2cValueError):
        compile_transfer(0x50, [256])
    with pytest.raises(I2cValueError):
        compile_ops("S 0xA0 X P")
    with pytest.raises(I2cValueError):
        compile_ops("")


def test_operations() -> None:
    program = compile_ops("S 0xA0, 16 B101 RN R P")
    assert program.words == (
        START,
        WRITE(0xA0, False),
        WRITE(0x10, False),
        0x4 << 8 | 0b101 | 3 << 12,
        0x200,
        0xA00,
        STOP,
    )


def test_results() -> None:
    program = compile_transfer(0x50, [0x07], 2)
    ok = program.result([0, 0, 0, 0, 0, 0x12, 0x34, 0])
    assert (ok.status, ok.data, ok.acks) == (I2cStatus.OK, b"\x12\x34", (True, True, True))
    nack = program.result([0, 1, -1, -1, -1, -1, -1, 0])
    assert (nack.status, nack.acks) == (I2cStatus.ADDRESS_NACK, (False,))
    data_nack = program.result([0, 0, 1, -1, -1, -1, -1, 0])
    assert data_nack.status is I2cStatus.DATA_NACK
    lost = program.result([0, -2, -1, -1, -1, -1, -1, -1])
    assert lost.status is I2cStatus.ARBITRATION_LOST
    assert program.result([0, 0, -3, -1, -1, -1, -1, -1]).status is I2cStatus.SCL_TIMEOUT
    with pytest.raises(I2cValueError):
        program.result([0])


def test_the_pec_of_a_read_is_checked() -> None:
    program = compile_transfer(0x50, [0x10], 1, pec=True)
    good = reference_pec(bytes([0xA0, 0x10, 0xA1, 0x42]))
    assert program.result([0, 0, 0, 0, 0, 0x42, good, 0]).status is I2cStatus.OK
    wrong = program.result([0, 0, 0, 0, 0, 0x42, good ^ 1, 0])
    assert (wrong.status, wrong.data) == (I2cStatus.PEC_ERROR, b"\x42")


# Target engine, driven the way the VHDL target drives it
class Driver:
    def __init__(self, target: I2cTarget) -> None:
        self.target = target
        self.time = 0

    def write(self, *values: int, stop: bool = True) -> list[bool]:
        """A START and the bytes; the acknowledge bits the target gave."""
        self.target.start(self.time)
        acks = []
        for value in values:
            directive = self.target.received(value, self.time)
            acks.append(directive.ack)
        if stop:
            self.target.stop(self.time)
        return acks

    def read(self, address_byte: int, count: int, *, repeated: bool = False) -> tuple[bool, bytes]:
        if not repeated:
            self.target.start(self.time)
        else:
            self.target.start(self.time)
        directive = self.target.received(address_byte, self.time)
        data = bytearray()
        while directive.action is Action.TRANSMIT and len(data) < count:
            data.append(directive.byte_out)
            directive = self.target.transmitted(len(data) < count, self.time)
        self.target.stop(self.time)
        return directive.ack or bool(data), bytes(data)


def test_register_device_write_and_read_back() -> None:
    device = RegisterDevice(size_bytes=16)
    driver = Driver(I2cTarget(device, 0x20))
    assert driver.write(0x40, 0x0E, 0xAA, 0xBB, 0xCC) == [True] * 5
    assert device.memory[14:] == b"\xaa\xbb" and device.memory[0] == 0xCC
    driver.write(0x40, 0x0E, stop=False)
    assert driver.read(0x41, 3, repeated=True) == (True, b"\xaa\xbb\xcc")


def test_other_addresses_are_ignored() -> None:
    driver = Driver(I2cTarget(RegisterDevice(), 0x20))
    assert driver.write(0x42, 0x01) == [False, False]
    assert driver.read(0x43, 1) == (False, b"")


def test_two_byte_register_addresses_without_auto_increment() -> None:
    device = RegisterDevice(size_bytes=1024, address_bytes=2, auto_increment=False)
    driver = Driver(I2cTarget(device, 0x20))
    driver.write(0x40, 0x03, 0x10, 0x01, 0x02)
    assert device.memory[0x310] == 0x02 and device.memory[0x311] == 0


def test_eeprom_page_write_rollover_and_acknowledge_polling() -> None:
    eeprom = Eeprom24(size_bytes=256, page_bytes=8, t_wr_fs=5_000)
    driver = Driver(I2cTarget(eeprom, 0x50))
    # Six bytes from 0x06 in a page of 8 wrap to 0x00
    assert all(driver.write(0xA0, 0x06, 1, 2, 3, 4, 5, 6))
    assert eeprom.memory[0x06:0x08] == b"\x01\x02" and eeprom.memory[0x00:0x04] == b"\x03\x04\x05\x06"
    assert eeprom.memory[0x08] == 0xFF
    # The write cycle: the address is not acknowledged for t_wr
    driver.time = 4_999
    assert driver.write(0xA0) == [False]
    driver.time = 5_000
    assert driver.write(0xA0) == [True]
    assert eeprom.write_cycles == 1


def test_eeprom_block_bits_address_wrap_and_abandoned_write() -> None:
    eeprom = Eeprom24(size_bytes=2048, page_bytes=16, t_wr_fs=0)
    driver = Driver(I2cTarget(eeprom, 0x50))
    # 24C16: 0x57 selects the last 256-byte block
    driver.write(0xAE, 0xFF, 0x42)
    assert eeprom.memory[0x7FF] == 0x42
    # A sequential read wraps at the end of the memory
    driver.write(0xAE, 0xFF, stop=False)
    assert driver.read(0xAF, 2, repeated=True) == (True, b"\x42\xff")
    # A repeated START instead of a STOP abandons the write
    driver.write(0xA0, 0x00, 0x99, stop=False)
    driver.target.start(0)
    driver.target.stop(0)
    assert eeprom.memory[0] == 0xFF
    assert not eeprom.responds_to(0x58)


def test_ten_bit_addressing() -> None:
    device = RegisterDevice()
    driver = Driver(I2cTarget(device, 0x2A5, ten_bit=True))
    assert driver.write(0xF4, 0xA5, 0x00, 0x77) == [True] * 4
    assert driver.write(0xF4, 0xA4) == [True, False]
    assert driver.write(0xF2, 0xA5) == [False, False]
    # A read after a repeated START needs the full address written first in the transaction
    driver.write(0xF4, 0xA5, 0x00, stop=False)
    assert driver.read(0xF5, 1, repeated=True) == (True, b"\x77")
    assert driver.read(0xF5, 1) == (False, b"")


def test_general_call() -> None:
    device = RegisterDevice()
    assert Driver(I2cTarget(device, 0x20)).write(0x00, 0x06) == [False, False]
    assert Driver(I2cTarget(device, 0x20, general_call=True)).write(0x00, 0x06) == [True, True]


def test_nack_injection_and_stretch() -> None:
    target = I2cTarget(RegisterDevice(), 0x20, stretch_fs=1000)
    target.inject_nack(2)
    driver = Driver(target)
    assert driver.write(0x40, 0x00, 0x01, 0x02) == [True, True, False, False]
    assert driver.write(0x40, 0x00, 0x01) == [True, True, True]
    target.start(0)
    assert target.received(0x40, 0).stretch_fs == 1000
    with pytest.raises(I2cValueError):
        target.inject_nack(-1)


def test_pec_write_is_checked_before_the_device_sees_it() -> None:
    device = RegisterDevice()
    target = I2cTarget(device, 0x20, pec=True)
    errors: list[str] = []
    target.errors.subscribe(errors.append)
    driver = Driver(target)
    good = reference_pec(bytes([0x40, 0x05, 0x99]))
    driver.write(0x40, 0x05, 0x99, good)
    assert device.memory[5] == 0x99 and device.memory[6] == 0 and errors == []
    driver.write(0x40, 0x05, 0x11, good)
    assert device.memory[5] == 0x99
    assert len(errors) == 1 and errors[0].startswith("I2C_PEC: wrong PEC")


def test_pec_read() -> None:
    device = RegisterDevice()
    device.memory[3] = 0x5A
    target = I2cTarget(device, 0x20, pec=True, pec_read_bytes=1)
    driver = Driver(target)
    driver.write(0x40, 0x03, stop=False)
    _, data = driver.read(0x41, 3, repeated=True)
    assert data == bytes([0x5A, reference_pec(bytes([0x40, 0x03, 0x41, 0x5A])), 0xFF])


def test_device_defaults_and_errors() -> None:
    device = I2cDevice()
    assert device.start(0, False, 0) and device.write(1, 0) and device.read(0) == 0xFF
    with pytest.raises(I2cValueError):
        device.preload(0, b"\x00")
    with pytest.raises(I2cValueError):
        device.read_memory(0, 1)
    with pytest.raises(I2cValueError):
        RegisterDevice(size_bytes=4).preload(3, b"\x00\x00")
    with pytest.raises(I2cValueError):
        Eeprom24(size_bytes=100, page_bytes=8)
    with pytest.raises(I2cValueError):
        Eeprom24(size_bytes=4096)
    with pytest.raises(I2cValueError):
        I2cTarget(device, 0x80)
