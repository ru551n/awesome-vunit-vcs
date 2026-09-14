"""
Cross-checks against independent Python Ethernet implementations.

cocotbext-eth is only a test reference: its frame helpers import the cocotb
runtime, so it is never a dependency of the package. These tests are skipped
when it (or Scapy) is not installed.
"""

import numpy as np
import pytest
from helpers import GmiiLine, ethernet_payload

from awesome_vunit_vcs.ethernet import EthernetMonitor, build_wire_frame
from awesome_vunit_vcs.ethernet.phy import GmiiPhy


@pytest.mark.parametrize("length", [14, 46, 60, 61, 500, 1514])
def test_wire_frame_matches_cocotbext_eth(length: int) -> None:
    eth = pytest.importorskip("cocotbext.eth")
    payload = ethernet_payload(length, seed=length)
    reference = eth.GmiiFrame.from_payload(payload)
    assert build_wire_frame(payload).octets == bytes(reference.data)


@pytest.mark.parametrize("length", [60, 333, 1514])
def test_monitor_payload_and_fcs_agree_with_cocotbext_eth(length: int) -> None:
    eth = pytest.importorskip("cocotbext.eth")
    payload = ethernet_payload(length, seed=7)
    reference = eth.GmiiFrame.from_payload(payload)
    line = GmiiLine()
    line.idle(1)
    for octet in bytes(reference.data):
        line.cycle(octet | 0x100)
    line.idle(1)
    monitor = EthernetMonitor(GmiiPhy())
    monitor.feed(np.array(line.words, dtype=np.int64), np.array(line.times, dtype=np.int64))
    frame = monitor.history[0]
    assert frame.payload == bytes(reference.get_payload())
    assert frame.fcs_ok is reference.check_fcs()


def test_scapy_decode_of_monitored_frame() -> None:
    pytest.importorskip("scapy")
    from scapy.layers.inet import IP, UDP
    from scapy.layers.l2 import Ether
    from scapy.packet import Raw

    from awesome_vunit_vcs.ethernet.scapy_adapter import to_scapy

    packet = (
        Ether(dst="02:00:00:00:00:01", src="02:00:00:00:00:02")
        / IP(dst="192.168.1.10")
        / UDP(dport=1234)
        / Raw(b"hello")
    )
    wire = build_wire_frame(bytes(packet))
    symbols = GmiiPhy().encode(wire)
    words = np.concatenate([[0], symbols]).astype(np.int64)
    monitor = EthernetMonitor(GmiiPhy())
    monitor.feed(words, np.arange(len(words), dtype=np.int64))
    decoded = to_scapy(monitor.history[0])
    assert decoded.dst == "02:00:00:00:00:01"
    assert IP in decoded
    assert UDP in decoded
    assert decoded[UDP].dport == 1234
    assert bytes(decoded[Raw].load).startswith(b"hello")
