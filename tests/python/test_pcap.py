"""PCAPNG export, read back with an independent parser and, when installed, Scapy."""

import struct
from pathlib import Path

import numpy as np
import pytest
from helpers import GmiiLine, ethernet_mac_octets, reference_frame

from awesome_vunit_vcs.ethernet import CaptureOptions, EthernetMonitor
from awesome_vunit_vcs.ethernet.phy import GmiiPhy


def parse_pcapng(path: Path) -> tuple[dict[int, bytes], list[dict[str, object]]]:
    """Minimal little-endian PCAPNG reader: returns IDB options and the EPBs."""
    data = path.read_bytes()
    position = 0
    idb_options: dict[int, bytes] = {}
    packets: list[dict[str, object]] = []

    def options(raw: bytes) -> dict[int, bytes]:
        found: dict[int, bytes] = {}
        index = 0
        while index + 4 <= len(raw):
            code, length = struct.unpack_from("<HH", raw, index)
            if code == 0:
                break
            found[code] = raw[index + 4 : index + 4 + length]
            index += 4 + length + (-length % 4)
        return found

    while position < len(data):
        block_type, total = struct.unpack_from("<II", data, position)
        assert struct.unpack_from("<I", data, position + total - 4)[0] == total
        body = data[position + 8 : position + total - 4]
        if block_type == 0x0A0D0D0A:
            assert struct.unpack_from("<I", body, 0)[0] == 0x1A2B3C4D
        elif block_type == 1:
            linktype = struct.unpack_from("<H", body, 0)[0]
            assert linktype == 1
            idb_options = options(body[8:])
        elif block_type == 6:
            _, ts_hi, ts_lo, caplen, origlen = struct.unpack_from("<IIIII", body, 0)
            packet = body[20 : 20 + caplen]
            packets.append(
                {
                    "timestamp": (ts_hi << 32) | ts_lo,
                    "data": packet,
                    "origlen": origlen,
                    "options": options(body[20 + caplen + (-caplen % 4) :]),
                }
            )
        position += total
    return idb_options, packets


def capture(tmp_path: Path, options: CaptureOptions | None = None) -> tuple[Path, list[bytes]]:
    line = GmiiLine(time_fs=3_000_000_000)
    line.idle(1)
    payloads = [ethernet_mac_octets(60, seed=1), ethernet_mac_octets(200, seed=2)]
    line.frame(reference_frame(payloads[0]))
    line.frame(reference_frame(payloads[1], bad_fcs=True))
    path = tmp_path / "capture.pcapng"
    monitor = EthernetMonitor(GmiiPhy(), name="gmii_monitor_0")
    writer = monitor.start_capture(path, options)
    monitor.feed(np.array(line.words, dtype=np.int64), np.array(line.times, dtype=np.int64))
    monitor.stop_captures()
    assert writer.frames_written == len(payloads) or options is not None
    return path, payloads


def test_capture_contains_the_frames_with_fcs_and_error_flags(tmp_path: Path) -> None:
    path, payloads = capture(tmp_path)
    idb, packets = parse_pcapng(path)
    assert idb[9] == bytes([9])
    assert idb[2] == b"gmii_monitor_0"
    assert [p["data"] for p in packets] == [reference_frame(payloads[0]), reference_frame(payloads[1], bad_fcs=True)]
    flags = [struct.unpack("<I", p["options"][2])[0] for p in packets]  # type: ignore[index]
    assert [(flag >> 5) & 0xF for flag in flags] == [4, 4]
    assert flags[0] & (1 << 24) == 0
    assert flags[1] & (1 << 24)
    assert b"bad FCS" in packets[1]["options"][1]  # type: ignore[index]
    # 3000 ns + 1 idle cycle + 8 preamble/SFD octets at 8 ns
    assert packets[0]["timestamp"] == 3000 + 8 + 8 * 8


def test_capture_options(tmp_path: Path) -> None:
    path, payloads = capture(
        tmp_path, CaptureOptions(include_fcs=False, include_errored=False, timestamp_resolution_exponent=15)
    )
    idb, packets = parse_pcapng(path)
    assert idb[9] == bytes([15])
    assert [p["data"] for p in packets] == [payloads[0]]
    assert packets[0]["timestamp"] == 3_000_000_000 + 9 * 8_000_000


def test_scapy_reads_the_capture(tmp_path: Path) -> None:
    pytest.importorskip("scapy")
    import scapy.layers.l2  # noqa: F401 - registers the Ethernet link type
    from scapy.utils import PcapNgReader

    path, payloads = capture(tmp_path)
    with PcapNgReader(str(path)) as reader:
        packets = list(reader)
    assert [bytes(packet)[:-4] for packet in packets] == payloads
    assert packets[0].dst == "02:00:00:00:00:01"
