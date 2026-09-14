# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Memory-image readers: Intel HEX, Motorola S-record, raw binary, JSON.

All four decode to the same thing: a list of `Segment`s. Intel HEX and
S-record are *natively sparse* formats -- a linker emits a few kilobytes of
code at 0x0000 and a config word at 0xFF00, and nothing in between -- so
the reader preserves that and hands the device two segments. Expanding them
to a dense buffer would turn "load a 2 KiB bootloader into a 16 MiB part"
into a 16 MiB allocation, and would additionally destroy the information
that the gap was never specified at all (it must read 0xFF, not 0x00).

Contiguous records are coalesced as they are parsed, so a normal hex file
with one record every 16 bytes becomes one segment, not thousands.

Checksums are verified and a bad one raises: a truncated or corrupted image
silently loading the wrong bytes is exactly the kind of thing that costs an
afternoon.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

FORMATS = ("hex", "srec", "bin", "json")

_EXTENSIONS = {
    ".hex": "hex",
    ".ihex": "hex",
    ".ihx": "hex",
    ".srec": "srec",
    ".s19": "srec",
    ".s28": "srec",
    ".s37": "srec",
    ".mot": "srec",
    ".bin": "bin",
    ".img": "bin",
    ".raw": "bin",
    ".json": "json",
}


@dataclass(frozen=True)
class Segment:
    """One contiguous piece of an image. Either literal `data`, or a
    constant `fill` repeated `length` times -- the latter exists so a JSON
    image can describe "1 MiB of 0x00" without carrying 1 MiB."""

    addr: int
    data: bytes | None = None
    fill: int | None = None
    length: int = 0

    def __post_init__(self) -> None:
        if (self.data is None) == (self.fill is None):
            raise ValueError("a segment is either data or a fill, not both/neither")

    @property
    def size(self) -> int:
        return len(self.data) if self.data is not None else self.length


def format_for(path: str | Path, fmt: str | None = None) -> str:
    """Resolve the format, from an explicit name or the file extension."""
    if fmt and fmt not in ("", "auto"):
        name = fmt.lower().lstrip(".")
        name = {"ihex": "hex", "s19": "srec", "s-record": "srec"}.get(name, name)
        if name not in FORMATS:
            raise ValueError(f"unknown image format {fmt!r}; known: {FORMATS}")
        return name
    suffix = Path(path).suffix.lower()
    if suffix not in _EXTENSIONS:
        raise ValueError(f"cannot infer image format from {Path(path).name!r}; pass fmt explicitly")
    return _EXTENSIONS[suffix]


def load(path: str | Path, fmt: str | None = None, base: int = 0) -> list[Segment]:
    """Read an image file into sparse segments. `base` is the load address
    for a raw binary and an offset added to every address otherwise."""
    kind = format_for(path, fmt)
    if kind == "bin":
        return [Segment(addr=base, data=Path(path).read_bytes())]
    if kind == "json":
        return _load_json(Path(path), base)
    text = Path(path).read_text()
    segments = _load_hex(text) if kind == "hex" else _load_srec(text)
    if base:
        segments = [Segment(addr=s.addr + base, data=s.data, fill=s.fill, length=s.length) for s in segments]
    return segments


class _Coalescer:
    """Accumulates records, merging each onto the previous one when it
    starts exactly where that one ended."""

    def __init__(self) -> None:
        self._segments: list[tuple[int, bytearray]] = []

    def add(self, addr: int, data: bytes) -> None:
        if not data:
            return
        if self._segments:
            start, buf = self._segments[-1]
            if start + len(buf) == addr:
                buf += data
                return
        self._segments.append((addr, bytearray(data)))

    def result(self) -> list[Segment]:
        return [Segment(addr=a, data=bytes(b)) for a, b in self._segments]


def _load_hex(text: str) -> list[Segment]:
    out = _Coalescer()
    upper = 0
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if not line.startswith(":"):
            raise ValueError(f"{lineno}: Intel HEX record must start with ':'")
        try:
            record = bytes.fromhex(line[1:])
        except ValueError as exc:
            raise ValueError(f"{lineno}: not hexadecimal: {exc}") from exc
        if len(record) < 5:
            raise ValueError(f"{lineno}: Intel HEX record too short")
        count = record[0]
        if len(record) != count + 5:
            raise ValueError(f"{lineno}: record says {count} data bytes but carries {len(record) - 5}")
        if sum(record) & 0xFF:
            raise ValueError(f"{lineno}: Intel HEX checksum mismatch")
        offset = int.from_bytes(record[1:3], "big")
        rtype = record[3]
        data = record[4:-1]
        if rtype == 0x00:
            out.add(upper + offset, data)
        elif rtype == 0x01:
            break
        elif rtype == 0x02:
            upper = int.from_bytes(data, "big") << 4
        elif rtype == 0x04:
            upper = int.from_bytes(data, "big") << 16
        elif rtype in (0x03, 0x05):
            pass  # start address: meaningless for a flash image
        else:
            raise ValueError(f"{lineno}: unsupported Intel HEX record type {rtype:#04x}")
    return out.result()


_SREC_ADDR_BYTES = {"1": 2, "2": 3, "3": 4}


def _load_srec(text: str) -> list[Segment]:
    out = _Coalescer()
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if len(line) < 4 or line[0] not in "Ss":
            raise ValueError(f"{lineno}: S-record must start with 'S'")
        kind = line[1]
        try:
            body = bytes.fromhex(line[2:])
        except ValueError as exc:
            raise ValueError(f"{lineno}: not hexadecimal: {exc}") from exc
        if not body:
            raise ValueError(f"{lineno}: S-record too short")
        count = body[0]
        if len(body) != count + 1:
            raise ValueError(f"{lineno}: record says {count} bytes but carries {len(body) - 1}")
        if (sum(body[:-1]) + body[-1]) & 0xFF != 0xFF:
            raise ValueError(f"{lineno}: S-record checksum mismatch")
        if kind in _SREC_ADDR_BYTES:
            n = _SREC_ADDR_BYTES[kind]
            addr = int.from_bytes(body[1 : 1 + n], "big")
            out.add(addr, body[1 + n : -1])
        elif kind in ("0", "5", "6", "7", "8", "9"):
            pass  # header, record count, termination: no payload for us
        else:
            raise ValueError(f"{lineno}: unsupported S-record type S{kind}")
    return out.result()


def _load_json(path: Path, base: int) -> list[Segment]:
    """JSON images, for tests that want to describe content inline:

        {"base": 0, "regions": [
            {"addr": 4096, "hex": "deadbeef"},
            {"addr": 8192, "data": [1, 2, 3]},
            {"addr": 65536, "fill": 0, "length": 1048576}
        ]}

    A bare list of regions is accepted as shorthand. `fill` regions stay
    sparse all the way into the array.
    """
    doc = json.loads(path.read_text())
    if isinstance(doc, list):
        regions = doc
        origin = base
    elif isinstance(doc, dict):
        regions = doc.get("regions", [])
        origin = base + int(doc.get("base", 0))
    else:
        raise ValueError("JSON image must be an object or a list of regions")
    segments: list[Segment] = []
    for index, region in enumerate(regions):
        if not isinstance(region, dict):
            raise ValueError(f"region {index} is not an object")
        addr = origin + int(region.get("addr", 0))
        if "fill" in region:
            length = int(region["length"])
            if length < 0:
                raise ValueError(f"region {index}: negative length")
            segments.append(Segment(addr=addr, fill=int(region["fill"]) & 0xFF, length=length))
        elif "hex" in region:
            segments.append(Segment(addr=addr, data=bytes.fromhex(region["hex"])))
        elif "data" in region:
            segments.append(Segment(addr=addr, data=bytes(bytearray(region["data"]))))
        else:
            raise ValueError(f"region {index} needs one of 'hex', 'data' or 'fill'+'length'")
    return segments
