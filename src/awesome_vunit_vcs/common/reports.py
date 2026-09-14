"""
Diagnostics produced in Python and logged through VUnit by VHDL.

Python has no access to VUnit's loggers and checkers. A backend queues
:class:`Report` objects and VHDL fetches them in one bridge call, logging
errors through the checker of the verification component so that they are
ordinary VUnit check failures (maskable, mockable, counted).
"""

from __future__ import annotations

import enum
from collections.abc import Iterable
from dataclasses import dataclass

#: Separates reports in the encoded string (ASCII record separator)
RECORD_SEPARATOR = "\x1e"
#: Separates the fields of a report (ASCII unit separator)
FIELD_SEPARATOR = "\x1f"


class Severity(enum.Enum):
    """How VHDL logs a report. The value is its one-character wire code."""

    DEBUG = "D"
    INFO = "I"
    WARNING = "W"
    #: A failed check, logged with ``check_failed`` on the VC checker
    ERROR = "E"
    #: An internal error, logged with ``failure`` on the VC logger
    FAILURE = "F"


@dataclass(slots=True, frozen=True)
class Report:
    severity: Severity
    message: str


class ReportQueue:
    """Reports waiting to be fetched by VHDL."""

    __slots__ = ("_reports",)

    def __init__(self) -> None:
        self._reports: list[Report] = []

    def add(self, severity: Severity, message: str) -> None:
        self._reports.append(Report(severity, message))

    def take(self) -> list[Report]:
        reports, self._reports = self._reports, []
        return reports

    def __len__(self) -> int:
        return len(self._reports)


def _clean(text: str) -> str:
    return text.replace(RECORD_SEPARATOR, " ").replace(FIELD_SEPARATOR, " ")


def encode_reports(reports: Iterable[Report]) -> str:
    """Encode reports as ``<code><US><message>`` records joined by RS."""
    return RECORD_SEPARATOR.join(f"{r.severity.value}{FIELD_SEPARATOR}{_clean(r.message)}" for r in reports)


def decode_reports(text: str) -> list[Report]:
    """Inverse of :func:`encode_reports`, used by tests."""
    if not text:
        return []
    reports = []
    for record in text.split(RECORD_SEPARATOR):
        code, _, message = record.partition(FIELD_SEPARATOR)
        reports.append(Report(Severity(code), message))
    return reports
