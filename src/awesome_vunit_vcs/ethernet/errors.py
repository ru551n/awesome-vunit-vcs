"""The exception every invalid argument of the Ethernet API raises."""

from __future__ import annotations

from ..errors import AwesomeVunitVcsError


class EthernetValueError(AwesomeVunitVcsError, ValueError):
    """
    An invalid argument: a value out of range, an unknown name or a malformed string.

    Every validation in ``awesome_vunit_vcs.ethernet`` raises this exception,
    so a property-based test can reject generated arguments with one
    ``except EthernetValueError`` (or Hypothesis ``assume``). It is a
    :class:`ValueError`, so existing ``except ValueError`` code keeps working, and an
    :class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`, like every error of the package.
    """
