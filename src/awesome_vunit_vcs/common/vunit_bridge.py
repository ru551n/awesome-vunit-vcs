"""
Encoding of bulk observations exchanged with VHDL over the VUnit Python bridge.

This module and ``vhdl/common/vcs_python_pkg.vhd`` are the only places that
depend on the conventions of the bridge (VUnit PR #1220). If the bridge API
changes, these two files change and the component families do not.

Sample batches
--------------
A monitor sends the samples it recorded as one ``integer_array_t`` of 32-bit
signed words laid out as ``[word_0, dt_0, word_1, dt_1, ...]``:

* ``word_i`` is the interface specific sample word (see the PHY modules)
* ``dt_i`` is the time of sample ``i`` minus the time of sample ``i - 1`` in
  femtoseconds, with sample ``-1`` being the batch base time. VHDL starts a new
  batch before a delta would exceed 32 bits.

The base time is given as two integers since VHDL integers are 32 bits in
several simulators: ``base = hi * 2**30 + lo``.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import numpy.typing as npt

TIME_SPLIT_BITS = 30

Int64Array = npt.NDArray[np.int64]


def join_time(hi: int, lo: int) -> int:
    """Join the two halves of a time in femtoseconds."""
    if hi < 0 or not 0 <= lo < (1 << TIME_SPLIT_BITS):
        raise ValueError(f"Invalid time halves hi={hi}, lo={lo}")
    return (hi << TIME_SPLIT_BITS) | lo


def split_time(time_fs: int) -> tuple[int, int]:
    """Split a time in femtoseconds into the halves VHDL sends."""
    if time_fs < 0:
        raise ValueError(f"Negative time {time_fs} fs")
    return time_fs >> TIME_SPLIT_BITS, time_fs & ((1 << TIME_SPLIT_BITS) - 1)


def decode_samples(samples: Any, base_fs: int) -> tuple[Int64Array, Int64Array]:
    """
    Decode a sample batch into (words, absolute times in fs).

    The arrays are copies: the bridge only guarantees the lifetime of the
    array it passes for the duration of the call.
    """
    flat = np.array(samples, dtype=np.int64, copy=True).reshape(-1)
    if flat.size % 2 != 0:
        raise ValueError(f"A sample batch has an even number of elements, got {flat.size}")
    words = flat[0::2].copy()
    deltas = flat[1::2]
    if deltas.size and int(deltas.min()) < 0:
        raise ValueError("A sample batch has a negative time delta")
    times = base_fs + np.cumsum(deltas, dtype=np.int64)
    return words, times


def encode_samples(words: npt.ArrayLike, times: npt.ArrayLike, base_fs: int) -> npt.NDArray[np.int32]:
    """Inverse of :func:`decode_samples`, used by tests and benchmarks."""
    word_array = np.asarray(words, dtype=np.int64)
    time_array = np.asarray(times, dtype=np.int64)
    deltas = np.diff(time_array, prepend=np.int64(base_fs))
    out = np.empty(2 * word_array.size, dtype=np.int32)
    out[0::2] = word_array
    out[1::2] = deltas
    return out


def bytes_from_unsigned(value: int, length: int) -> bytes:
    """Octets of a VHDL ``std_ulogic_vector`` sent as an unsigned integer, leftmost octet first."""
    if length < 0:
        raise ValueError(f"Negative length {length}")
    return value.to_bytes(length, "big") if length else b""
