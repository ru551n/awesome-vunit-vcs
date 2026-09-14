# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The base of every exception the package raises for its own errors."""

from __future__ import annotations

__all__ = ["AwesomeVunitVcsError"]


class AwesomeVunitVcsError(Exception):
    """
    An error of awesome-vunit-vcs, whichever family raised it.

    Catch it to handle every error of the package in one place, for example
    ``except AwesomeVunitVcsError``. Each family raises a subclass, such as
    :class:`~awesome_vunit_vcs.ethernet.errors.EthernetValueError`, which is also a
    :class:`ValueError`.
    """
