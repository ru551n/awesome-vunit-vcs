import pytest
from helpers import ethernet_payload, reference_crc32, reference_frame

from awesome_vunit_vcs.ethernet.frame import EthernetConfig, MacFrame, append_fcs, fcs32


def test_fcs_matches_known_check_value() -> None:
    assert fcs32(b"123456789") == 0xCBF43926


@pytest.mark.parametrize("length", [0, 1, 59, 60, 1514, 9000])
def test_fcs_matches_bitwise_reference(length: int) -> None:
    data = ethernet_payload(length, seed=length)
    assert fcs32(data) == reference_crc32(data)


def test_frame_with_fcs_has_the_crc_residue() -> None:
    # The CRC over data followed by its FCS is the well-known residue
    assert fcs32(append_fcs(ethernet_payload(100))) == 0x2144DF1C


def test_mac_frame_fields() -> None:
    payload = ethernet_payload(60, seed=3)
    mac = MacFrame(reference_frame(payload))
    assert mac.payload == payload
    assert mac.fcs_ok is True
    assert mac.destination == b"\x02\x00\x00\x00\x00\x01"
    assert mac.source == b"\x02\x00\x00\x00\x00\x02"
    assert mac.ethertype == 0x0800
    assert mac.size_with_fcs == 64


def test_mac_frame_bad_fcs_values() -> None:
    payload = ethernet_payload(60)
    mac = MacFrame(reference_frame(payload, bad_fcs=True))
    assert mac.fcs_ok is False
    assert mac.fcs_expected == reference_crc32(payload)
    assert mac.fcs_received == reference_crc32(payload) ^ 0x10000000


def test_client_data_strips_padding_for_length_field() -> None:
    header = b"\x02\x00\x00\x00\x00\x01" + b"\x02\x00\x00\x00\x00\x02" + (5).to_bytes(2, "big")
    mac = MacFrame(reference_frame(header + b"hello"))
    assert mac.client_data == b"hello"


def test_frame_without_fcs() -> None:
    mac = MacFrame(b"\x01" * 60, has_fcs=False)
    assert mac.fcs_ok is None
    assert mac.payload == b"\x01" * 60
    assert mac.size_with_fcs == 64


def test_config_validation() -> None:
    with pytest.raises(ValueError):
        EthernetConfig(min_preamble_octets=8, max_preamble_octets=7)
    with pytest.raises(ValueError):
        EthernetConfig(min_frame_octets=100, max_frame_octets=64)
