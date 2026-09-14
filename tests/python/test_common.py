import numpy as np
import pytest

from awesome_vunit_vcs.common.events import Publisher
from awesome_vunit_vcs.common.reports import Report, Severity, decode_reports, encode_reports
from awesome_vunit_vcs.common.vunit_bridge import (
    bytes_from_unsigned,
    decode_samples,
    encode_samples,
    join_time,
    split_time,
)


def test_publisher_delivers_in_order_and_unsubscribes() -> None:
    seen: list[tuple[str, int]] = []
    publisher: Publisher[int] = Publisher()
    publisher.subscribe(lambda event: seen.append(("a", event)))
    remove_b = publisher.subscribe(lambda event: seen.append(("b", event)))
    publisher.publish(1)
    remove_b()
    publisher.publish(2)
    assert seen == [("a", 1), ("b", 1), ("a", 2)]


def test_publisher_error_does_not_starve_other_subscribers() -> None:
    errors: list[str] = []
    seen: list[int] = []

    def broken(_: int) -> None:
        raise RuntimeError("boom")

    publisher: Publisher[int] = Publisher(on_error=lambda _, exc: errors.append(str(exc)))
    publisher.subscribe(broken)
    publisher.subscribe(seen.append)
    publisher.publish(7)
    assert errors == ["boom"]
    assert seen == [7]


def test_publisher_without_handler_reraises_after_delivery() -> None:
    seen: list[int] = []

    def broken(_: int) -> None:
        raise RuntimeError("boom")

    publisher: Publisher[int] = Publisher()
    publisher.subscribe(broken)
    publisher.subscribe(seen.append)
    with pytest.raises(RuntimeError):
        publisher.publish(3)
    assert seen == [3]


def test_reports_round_trip_and_separators_are_removed() -> None:
    reports = [
        Report(Severity.ERROR, "ETH_FCS: bad FCS on frame 1\nexpected=0x1"),
        Report(Severity.DEBUG, "weird\x1erecord\x1ffield"),
    ]
    decoded = decode_reports(encode_reports(reports))
    assert decoded[0] == reports[0]
    assert decoded[1] == Report(Severity.DEBUG, "weird record field")
    assert decode_reports("") == []


@pytest.mark.parametrize("time_fs", [0, 1, (1 << 30) - 1, 1 << 30, 123_456_789_012_345_678])
def test_time_split_round_trip(time_fs: int) -> None:
    hi, lo = split_time(time_fs)
    assert 0 <= lo < 1 << 30
    assert join_time(hi, lo) == time_fs


def test_samples_round_trip() -> None:
    base = 5 * (1 << 30) + 17
    times = [base + 8_000_000 * index for index in range(10)]
    words = [index | 0x100 for index in range(10)]
    encoded = encode_samples(words, times, base)
    assert encoded.dtype == np.int32
    decoded_words, decoded_times = decode_samples(encoded, base)
    assert decoded_words.tolist() == words
    assert decoded_times.tolist() == times


def test_samples_are_copied() -> None:
    encoded = encode_samples([1, 2], [10, 20], 0)
    words, _ = decode_samples(encoded, 0)
    encoded[0] = 99
    assert words[0] == 1


def test_invalid_sample_batches() -> None:
    with pytest.raises(ValueError, match="even"):
        decode_samples(np.array([1, 2, 3], dtype=np.int32), 0)
    with pytest.raises(ValueError, match="negative"):
        decode_samples(np.array([1, -5], dtype=np.int32), 0)


def test_bytes_from_unsigned_keeps_leading_zero_octets() -> None:
    assert bytes_from_unsigned(0x0102, 4) == b"\x00\x00\x01\x02"
    assert bytes_from_unsigned(0, 0) == b""
