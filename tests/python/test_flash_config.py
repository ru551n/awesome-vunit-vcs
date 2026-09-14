# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""FlashConfig: the defaults the VHDL handle mirrors, and validation that rejects
a configuration no device could have instead of building a broken model."""

from __future__ import annotations

import pytest

from awesome_vunit_vcs.flash.config import BUSY_KEYS, DEFAULT_BUSY_FS, KIB, MIB, AddrModes, FlashConfig
from awesome_vunit_vcs.flash.device import FlashDevice

US = 10**9
MS = 10**12
SEC = 10**15


def test_defaults_are_the_generic_16mib_part() -> None:
    config = FlashConfig()
    assert config.size_bytes == 16 * MIB
    assert config.page_bytes == 256
    assert config.sector_bytes == 4 * KIB
    assert config.block32_bytes == 32 * KIB
    assert config.block_bytes == 64 * KIB
    assert config.addr_bytes == 3
    assert config.addr_modes is AddrModes.BOTH
    assert config.jedec_id == 0xEF4018
    assert config.electronic_id is None
    assert (config.sr1_default, config.sr2_default, config.sr3_default) == (0x00, 0x02, 0x00)
    assert config.timing_enabled is True


def test_default_busy_times_in_femtoseconds() -> None:
    assert dict(DEFAULT_BUSY_FS) == {
        "tPP": 700 * US,
        "tSE": 45 * MS,
        "tBE32": 120 * MS,
        "tBE64": 150 * MS,
        "tCE": 20 * SEC,
        "tW": 10 * MS,
        "tRST": 30 * US,
        "tRES1": 3 * US,
        "tRES2": 1800 * 10**6,
    }
    assert DEFAULT_BUSY_FS["tRES2"] == 1_800_000_000
    assert DEFAULT_BUSY_FS["tPP"] == 700_000_000_000
    assert set(FlashConfig().busy_fs) == set(BUSY_KEYS)
    assert all(isinstance(value, int) for value in DEFAULT_BUSY_FS.values())


def test_addr_modes_values_are_what_vhdl_sends() -> None:
    assert (AddrModes.BOTH, AddrModes.THREE_ONLY, AddrModes.FOUR_ONLY) == (0, 3, 4)
    assert FlashConfig(addr_modes=3).addr_modes is AddrModes.THREE_ONLY


@pytest.mark.parametrize(
    "config",
    [
        {},
        {"size_bytes": 4 * MIB, "jedec_id": 0xEF4016},
        {"size_bytes": 32 * MIB, "jedec_id": 0x20BA19},
        {"size_bytes": 32 * MIB, "jedec_id": 0xEF4019, "addr_bytes": 4},
    ],
    ids=["generic_16mib", "w25q32jv", "mt25ql256", "generic_32mib_4b"],
)
def test_the_former_named_parts_build_working_devices(config: dict[str, int]) -> None:
    device = FlashDevice(FlashConfig(**config))
    assert device.size_bytes == config.get("size_bytes", 16 * MIB)
    assert device.read_back(device.size_bytes - 1, 1) == b"\xff"
    assert len(device.jedec_bytes) == 3
    assert device.sfdp_image[:4] == b"SFDP"
    assert device.get_stat("addr_bytes") == config.get("addr_bytes", 3)


def test_busy_fs_is_copied_so_instances_cannot_poison_each_other() -> None:
    busy = dict(DEFAULT_BUSY_FS)
    config = FlashConfig(busy_fs=busy)
    busy["tPP"] = 1
    assert config.busy_fs["tPP"] == 700 * US
    assert FlashConfig().busy_fs is not FlashConfig().busy_fs
    assert DEFAULT_BUSY_FS["tPP"] == 700 * US


@pytest.mark.parametrize(
    ("overrides", "match"),
    [
        ({"size_bytes": 3 * MIB}, "size_bytes"),
        ({"size_bytes": 1_000_000}, "power of two"),
        ({"size_bytes": 0}, "size_bytes"),
        ({"page_bytes": 300}, "page_bytes"),
        ({"page_bytes": 0}, "page_bytes"),
        (
            {"size_bytes": 128, "page_bytes": 256, "sector_bytes": 64, "block32_bytes": 0, "block_bytes": 128},
            "multiple",
        ),
        ({"addr_bytes": 5}, "addr_bytes"),
        ({"addr_bytes": 2}, "addr_bytes"),
        ({"sector_bytes": 3000}, "sector_bytes"),
        ({"block32_bytes": 1000}, "block32_bytes"),
        ({"block_bytes": 32 * MIB}, "block_bytes"),
        ({"sector_bytes": 128}, "sector_bytes"),
        ({"sector_bytes": 32 * KIB}, "sector_bytes"),
        ({"block32_bytes": 64 * KIB}, "block32_bytes"),
        ({"sector_bytes": 64 * KIB, "block32_bytes": 0}, "sector_bytes"),
        ({"size_bytes": 32 * KIB, "block32_bytes": 0, "block_bytes": 64 * KIB}, "block_bytes"),
        ({"addr_bytes": 3, "addr_modes": AddrModes.FOUR_ONLY}, "addr_modes"),
        ({"addr_bytes": 4, "addr_modes": AddrModes.THREE_ONLY}, "addr_modes"),
        ({"addr_modes": 2}, "addr_modes"),
        ({"sr1_default": 256}, "sr1_default"),
        ({"sr2_default": -1}, "sr2_default"),
        ({"sr3_default": 0x100}, "sr3_default"),
        ({"jedec_id": 1 << 24}, "jedec_id"),
        ({"jedec_id": -1}, "jedec_id"),
        ({"electronic_id": 0x100}, "electronic_id"),
        ({"busy_fs": {"tPP": 1}}, "busy"),
        ({"busy_fs": {**DEFAULT_BUSY_FS, "tXX": 1}}, "tXX"),
        ({"busy_fs": {**DEFAULT_BUSY_FS, "tSE": -1}}, "tSE"),
        ({"busy_fs": {**DEFAULT_BUSY_FS, "tSE": 45e-3}}, "tSE"),
    ],
)
def test_invalid_configurations_raise_value_error(overrides: dict[str, object], match: str) -> None:
    with pytest.raises(ValueError, match=match):
        FlashConfig(**overrides)


def test_missing_busy_keys_are_named() -> None:
    with pytest.raises(ValueError, match="tRES2"):
        FlashConfig(busy_fs={key: 1 for key in BUSY_KEYS if key != "tRES2"})


def test_valid_non_default_configurations_are_accepted() -> None:
    assert FlashConfig(block32_bytes=0).block32_bytes == 0
    assert FlashConfig(sector_bytes=8 * KIB, block32_bytes=16 * KIB, block_bytes=128 * KIB).block_bytes == 128 * KIB
    assert FlashConfig(sector_bytes=256, block32_bytes=0, block_bytes=16 * MIB).sector_bytes == 256
    assert FlashConfig(size_bytes=1 << 20, page_bytes=128).page_bytes == 128
    assert FlashConfig(addr_bytes=4, addr_modes=AddrModes.FOUR_ONLY).addr_bytes == 4
    assert FlashConfig(addr_bytes=4).addr_modes is AddrModes.BOTH
    assert FlashConfig(busy_fs=dict.fromkeys(BUSY_KEYS, 0)).busy_fs["tCE"] == 0
    assert FlashConfig(timing_enabled=False).timing_enabled is False


def test_device_id_follows_the_capacity_code() -> None:
    assert FlashConfig().device_id() == 0x17  # 0x18 - 1
    assert FlashConfig(jedec_id=0xEF4016).device_id() == 0x15
    assert FlashConfig(electronic_id=0x42).device_id() == 0x42


def test_jedec_id_bytes_are_most_significant_first() -> None:
    assert FlashConfig().jedec_id_bytes() == b"\xef\x40\x18"
    assert FlashConfig(jedec_id=0x20BA19).jedec_id_bytes() == b"\x20\xba\x19"


def test_a_config_is_immutable() -> None:
    config = FlashConfig()
    with pytest.raises(AttributeError):
        config.size_bytes = 1
