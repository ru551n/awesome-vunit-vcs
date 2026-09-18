# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Base classes of the Python objects behind VHDL verification components.

A VC creates one backend in its own Python session, as the object ``vc``. No
backend method raises into the bridge: :meth:`VcBackend.guard` turns an
exception into a :attr:`~awesome_vunit_vcs.common.reports.Severity.FAILURE`
report on the logger of the VC, and :meth:`VcBackend.error` queues a check
failure for its checker. A passive VC's backend derives from
:class:`SampleBackend`, which decodes the sample batches of ``flush_samples``.
"""

from __future__ import annotations

import traceback
from collections.abc import Callable, Sequence
from typing import Any, TypeVar

import numpy as np
import numpy.typing as npt

from .reports import ReportQueue, Severity, encode_reports
from .vunit_bridge import decode_samples, decode_text, decode_time_fs

__all__ = ["VHDL_INTEGER_MAX", "SampleBackend", "VcBackend", "exception_summary", "int32_array"]

#: The result of a guarded call
T = TypeVar("T")

#: Largest value a VHDL integer holds
VHDL_INTEGER_MAX = 2**31 - 1


def int32_array(values: Any) -> npt.NDArray[np.int32]:
    """``values`` as a flat array of 32-bit integers, which the bridge returns as an ``integer_array_t``."""
    return np.array(values, dtype=np.int32).reshape(-1)


def exception_summary(exc: BaseException) -> str:
    """One line for a log: the exception type, its message and where it was raised."""
    frames = traceback.extract_tb(exc.__traceback__)
    where = f" ({frames[-1].filename}:{frames[-1].lineno})" if frames else ""
    return f"{type(exc).__name__}: {exc}{where}"


class VcBackend:
    """
    Reports, and calls that never raise.

    Args:
        name: The name of the VC, used in messages; text as ``arg_text`` sends it, or a ``str``.

    Attributes:
        name: The name of the VC.
        reports: The reports waiting for VHDL.
    """

    def __init__(self, name: str | Sequence[int]) -> None:
        self.name = decode_text(name)
        self.reports = ReportQueue()

    def guard(self, method: str, fn: Callable[[], T], fallback: T) -> T:
        """Call ``fn``; if it raises, queue a failure report naming ``method`` and return ``fallback``."""
        try:
            return fn()
        except Exception as exc:
            self.reports.add(Severity.FAILURE, f"{self.name}: {method} failed: {exception_summary(exc)}")
            return fallback

    def error(self, message: str) -> None:
        """Report a check failure on the checker of the VC, for example from a subscriber."""
        self.reports.add(Severity.ERROR, f"{self.name}: {message}")

    def subscriber_error(self, subscriber: Callable[..., None], exc: BaseException) -> None:
        """Report a subscriber that raised, as a failure; the error handler of a publisher."""
        name = getattr(subscriber, "__qualname__", repr(subscriber))
        self.reports.add(Severity.FAILURE, f"{self.name}: subscriber {name} raised {exception_summary(exc)}")

    def num_reports(self) -> int:
        """The number of reports waiting."""
        return len(self.reports)

    def take_reports(self) -> str:
        """The waiting reports, encoded for VHDL."""
        return encode_reports(self.reports.take())


class SampleBackend(VcBackend):
    """A backend fed with sample batches; subclasses implement :meth:`feed`."""

    def push(self, samples: Any, base_time: int | Sequence[int], delta_unit: int | Sequence[int] = 1) -> int:
        """
        Process a sample batch. Returns the number of reports waiting.

        Args:
            samples: ``[word, delta]`` pairs, see :func:`~awesome_vunit_vcs.common.vunit_bridge.decode_samples`.
            base_time: The time of the first sample.
            delta_unit: The unit of the deltas.
        """

        def push_() -> None:
            words, times = decode_samples(samples, decode_time_fs(base_time), decode_time_fs(delta_unit))
            self.feed(words.tolist(), times.tolist())

        self.guard("push", push_, None)
        return len(self.reports)

    def feed(self, words: list[int], times: list[int]) -> None:
        """Process sample words with their times in fs."""
        raise NotImplementedError
