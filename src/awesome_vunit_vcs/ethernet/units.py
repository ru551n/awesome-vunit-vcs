"""
Readable units: simulation times in femtoseconds and link rates in bits per second.

The Ethernet API counts time in integer femtoseconds, the resolution VUnit
and the Python bridge exchange, and rates in bits per second. These helpers
convert the strings people write::

    fs("8 ns") == 8_000_000
    bps("2.5G") == 2_500_000_000
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from decimal import Decimal

from .errors import EthernetValueError

#: Femtoseconds per second
FS_PER_SECOND = 10**15

#: Femtoseconds per time unit accepted by :func:`fs`
TIME_UNITS: Mapping[str, int] = {
    "fs": 1,
    "ps": 10**3,
    "ns": 10**6,
    "us": 10**9,
    "µs": 10**9,
    "ms": 10**12,
    "s": 10**15,
}

#: Multipliers of the rate prefixes accepted by :func:`bps`, case insensitive
RATE_PREFIXES: Mapping[str, int] = {"": 1, "k": 10**3, "m": 10**6, "g": 10**9, "t": 10**12}

_TIME = re.compile(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([a-zµ]+)\s*")
_RATE = re.compile(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtT]?)(?:bps|bit/s|b/s)?\s*")


def _whole(number: Decimal, text: str, unit: str) -> int:
    if number != number.to_integral_value():
        raise EthernetValueError(f"{text!r} is not a whole number of {unit}")
    return int(number)


def fs(value: int | str) -> int:
    """
    A time in femtoseconds.

    Args:
        value: Femtoseconds as an integer, or a number and a unit of
            :data:`TIME_UNITS` such as ``"8 ns"`` or ``"1.5 ps"``.

    Returns:
        The time in femtoseconds.

    Raises:
        EthernetValueError: The value is negative, malformed, has an unknown
            unit or is not a whole number of femtoseconds.
    """
    if isinstance(value, bool) or not isinstance(value, int | str):
        raise EthernetValueError(f"A time is an int or a str, got {value!r}")
    if isinstance(value, int):
        if value < 0:
            raise EthernetValueError(f"A time must not be negative, got {value}")
        return value
    match = _TIME.fullmatch(value)
    if match is None or match.group(2) not in TIME_UNITS:
        units = ", ".join(TIME_UNITS)
        raise EthernetValueError(f"{value!r} is not a time such as '8 ns' (units: {units})")
    return _whole(Decimal(match.group(1)) * TIME_UNITS[match.group(2)], value, "femtoseconds")


def bps(value: int | str) -> int:
    """
    A link rate in bits per second.

    Args:
        value: Bits per second as an integer, or a number with an optional
            prefix and unit such as ``"1G"``, ``"2.5G"``, ``"100M"`` or ``"10 Gbps"``.

    Returns:
        The rate in bits per second.

    Raises:
        EthernetValueError: The rate is not positive, malformed or not a whole number of bits per second.
    """
    if isinstance(value, bool) or not isinstance(value, int | str):
        raise EthernetValueError(f"A rate is an int or a str, got {value!r}")
    if isinstance(value, int):
        rate = value
    else:
        match = _RATE.fullmatch(value)
        if match is None:
            raise EthernetValueError(f"{value!r} is not a rate such as '1G' or '100M'")
        rate = _whole(Decimal(match.group(1)) * RATE_PREFIXES[match.group(2).lower()], value, "bits per second")
    if rate <= 0:
        raise EthernetValueError(f"A rate must be positive, got {value!r}")
    return rate
