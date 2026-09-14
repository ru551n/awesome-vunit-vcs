# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Image loading: Intel HEX, S-record, raw binary and JSON.

The sparseness assertions are the point: a hex file with two records
64 KiB apart must produce two segments, not a 64 KiB buffer, and must leave
the gap reading 0xFF once loaded into a device."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from awesome_vunit_vcs.flash import images
from awesome_vunit_vcs.flash.config import FlashConfig
from awesome_vunit_vcs.flash.device import FlashDevice
from awesome_vunit_vcs.flash.errors import FlashValueError


def ihex(records: list[tuple[int, int, bytes]]) -> str:
    """Build an Intel HEX file from `(type, offset, data)` records, with
    correct checksums."""
    lines = []
    for rtype, offset, data in records:
        body = bytes([len(data), offset >> 8, offset & 0xFF, rtype]) + data
        checksum = (-sum(body)) & 0xFF
        lines.append(":" + (body + bytes([checksum])).hex().upper())
    lines.append(":00000001FF")
    return "\n".join(lines) + "\n"


def srec(kind: str, addr: int, data: bytes) -> str:
    n = {"1": 2, "2": 3, "3": 4}[kind]
    body = addr.to_bytes(n, "big") + data
    body = bytes([len(body) + 1]) + body
    checksum = 0xFF - (sum(body) & 0xFF)
    return "S" + kind + (body + bytes([checksum])).hex().upper()


@pytest.fixture
def dev() -> FlashDevice:
    return FlashDevice(FlashConfig())


# -- format resolution ---------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("a.hex", "hex"),
        ("a.HEX", "hex"),
        ("a.s19", "srec"),
        ("a.srec", "srec"),
        ("a.bin", "bin"),
        ("a.json", "json"),
    ],
)
def test_format_inferred_from_extension(name: str, expected: str) -> None:
    assert images.format_for(name) == expected


def test_explicit_format_overrides_the_extension() -> None:
    assert images.format_for("a.txt", "hex") == "hex"
    assert images.format_for("a.txt", "s19") == "srec"


def test_unknown_extension_asks_for_an_explicit_format() -> None:
    with pytest.raises(ValueError, match="cannot infer"):
        images.format_for("firmware.elf")
    with pytest.raises(ValueError, match="unknown image format"):
        images.format_for("a.bin", "coe")


# -- Intel HEX ------------------------------------------------------------------


def test_intel_hex_contiguous_records_coalesce(tmp_path: Path) -> None:
    path = tmp_path / "a.hex"
    path.write_text(ihex([(0, 0x0000, bytes(range(16))), (0, 0x0010, bytes(range(16, 32)))]))
    segments = images.load(path)
    assert len(segments) == 1
    assert segments[0].addr == 0 and segments[0].data == bytes(range(32))


def test_intel_hex_stays_sparse(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.hex"
    path.write_text(
        ihex(
            [
                (0, 0x0000, b"\x01\x02"),
                (4, 0x0000, b"\x00\x01"),  # extended linear: 0x0001_0000
                (0, 0x0000, b"\x03\x04"),
            ]
        )
    )
    segments = images.load(path)
    assert [(s.addr, s.data) for s in segments] == [
        (0x0000, b"\x01\x02"),
        (0x1_0000, b"\x03\x04"),
    ]
    dev.load_image(str(path))
    # The 64 KiB gap was never specified, so it must read erased -- and must
    # not have been materialized either.
    assert dev.read_back(0x0002, 4) == b"\xff" * 4
    assert dev.array.materialized_pages == 2


def test_intel_hex_extended_segment_records(tmp_path: Path) -> None:
    path = tmp_path / "a.hex"
    path.write_text(ihex([(2, 0x0000, b"\x10\x00"), (0, 0x0004, b"\xaa")]))
    # A segment base of 0x1000 is a paragraph count: the address is x16.
    assert images.load(path)[0].addr == 0x1000 * 16 + 4


def test_intel_hex_bad_checksum_raises(tmp_path: Path) -> None:
    path = tmp_path / "a.hex"
    good = ihex([(0, 0, b"\xaa")])
    path.write_text(good.replace(good.splitlines()[0][-2:], "00"))
    with pytest.raises(ValueError, match="checksum"):
        images.load(path)


def test_intel_hex_truncated_record_raises(tmp_path: Path) -> None:
    path = tmp_path / "a.hex"
    path.write_text(":10000000AABBCC\n")
    with pytest.raises(ValueError):
        images.load(path)


def test_intel_hex_stops_at_eof_record(tmp_path: Path) -> None:
    path = tmp_path / "a.hex"
    path.write_text(ihex([(0, 0, b"\xaa")]) + ":01001000BB54\n")
    assert len(images.load(path)) == 1


# -- S-record ---------------------------------------------------------------------


@pytest.mark.parametrize("kind", ["1", "2", "3"])
def test_srecord_address_widths(tmp_path: Path, kind: str) -> None:
    path = tmp_path / "a.srec"
    path.write_text("S00600004844521B\n" + srec(kind, 0x1234, b"\xde\xad") + "\nS9030000FC\n")
    segments = images.load(path)
    assert [(s.addr, s.data) for s in segments] == [(0x1234, b"\xde\xad")]


def test_srecord_stays_sparse_and_coalesces(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.s19"
    path.write_text(
        "\n".join(
            [
                srec("1", 0x0000, b"\x01\x02"),
                srec("1", 0x0002, b"\x03\x04"),
                srec("1", 0x8000, b"\x05"),
            ]
        )
        + "\n"
    )
    segments = images.load(path)
    assert [(s.addr, s.size) for s in segments] == [(0x0000, 4), (0x8000, 1)]
    dev.load_image(str(path))
    assert dev.read_back(0, 5) == b"\x01\x02\x03\x04\xff"
    assert dev.read_back(0x8000, 2) == b"\x05\xff"


def test_srecord_bad_checksum_raises(tmp_path: Path) -> None:
    path = tmp_path / "a.s19"
    line = srec("1", 0, b"\xaa")
    path.write_text(line[:-2] + "00\n")
    with pytest.raises(ValueError, match="checksum"):
        images.load(path)


def test_srecord_unsupported_type_raises(tmp_path: Path) -> None:
    path = tmp_path / "a.s19"
    path.write_text("S40300000FC\n")
    with pytest.raises(ValueError):
        images.load(path)


# -- binary and JSON -----------------------------------------------------------------


def test_raw_binary_loads_at_base(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.bin"
    path.write_bytes(bytes(range(8)))
    dev.load_image(str(path), base=0x1_0000)
    assert dev.read_back(0x1_0000, 8) == bytes(range(8))
    assert dev.read_back(0x0_FFFF, 1) == b"\xff"


def test_json_regions(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.json"
    path.write_text(
        json.dumps(
            {
                "base": 0x1000,
                "regions": [
                    {"addr": 0x00, "hex": "deadbeef"},
                    {"addr": 0x10, "data": [1, 2, 3]},
                    {"addr": 0x1_0000, "fill": 0x00, "length": 1 << 20},
                ],
            }
        )
    )
    dev.load_image(str(path))
    assert dev.read_back(0x1000, 4) == bytes.fromhex("deadbeef")
    assert dev.read_back(0x1010, 3) == b"\x01\x02\x03"
    assert dev.read_back(0x11000, 1) == b"\x00"
    # The 1 MiB fill must stay a run: no megabyte of Python bytes.
    assert dev.array.materialized_pages == 1
    assert dev.read_back(0x11000 + (1 << 20), 1) == b"\xff"


def test_json_bare_list_and_base_offset(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.json"
    path.write_text(json.dumps([{"addr": 0, "hex": "aabb"}]))
    dev.load_image(str(path), base=0x40)
    assert dev.read_back(0x40, 2) == b"\xaa\xbb"


def test_json_region_without_content_raises(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.json"
    path.write_text(json.dumps({"regions": [{"addr": 0}]}))
    with pytest.raises(ValueError, match="needs one of"):
        dev.load_image(str(path))


@pytest.mark.parametrize(
    "text",
    ["{not json", '{"regions": [{"addr": "zz", "hex": "00"}]}', '[{"hex": "0g"}]', '[{"fill": 0}]'],
    ids=["syntax", "address", "hex", "fill_without_length"],
)
def test_a_malformed_json_image_raises_flash_value_error(tmp_path: Path, dev: FlashDevice, text: str) -> None:
    path = tmp_path / "a.json"
    path.write_text(text)
    with pytest.raises(FlashValueError):
        dev.load_image(str(path))


def test_loading_past_the_end_of_the_device_raises(tmp_path: Path, dev: FlashDevice) -> None:
    path = tmp_path / "a.bin"
    path.write_bytes(b"\x00" * 16)
    with pytest.raises(ValueError):
        dev.load_image(str(path), base=dev.size_bytes - 8)
