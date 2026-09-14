"""The exception every invalid argument of the Ethernet API raises."""

from __future__ import annotations


class EthernetValueError(ValueError):
    """
    An invalid argument: a value out of range, an unknown name or a malformed string.

    Every validation in :mod:`awesome_vunit_vcs.ethernet` raises this exception,
    so a property-based test can reject generated arguments with one
    ``except EthernetValueError`` (or Hypothesis ``assume``). It is a
    :class:`ValueError`, so existing ``except ValueError`` code keeps working.
    """
