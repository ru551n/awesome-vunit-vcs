# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The exceptions of the flash API.

:class:`FlashError` is the base of both, so ``except FlashError`` catches
everything the flash package raises on purpose. It derives from
:class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`, the base of the errors
of every family::

    AwesomeVunitVcsError
    +-- FlashError
        +-- FlashValueError (also a ValueError)
        +-- ContentMismatch
"""

from __future__ import annotations

from ..errors import AwesomeVunitVcsError


class FlashError(AwesomeVunitVcsError):
    """
    The base of every exception the flash package raises on purpose.

    It is an :class:`~awesome_vunit_vcs.errors.AwesomeVunitVcsError`, so
    ``except AwesomeVunitVcsError`` also catches the flash errors.
    """


class FlashValueError(FlashError, ValueError):
    """
    An invalid argument or configuration: a value out of range, an unknown name or a misused call.

    Every validation in ``awesome_vunit_vcs.flash`` raises this exception,
    including an unknown busy-time or statistic name and a call to
    :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.xfer` without
    :meth:`~awesome_vunit_vcs.flash.device.FlashDevice.cs_assert`, so a test
    catches one type. It is a :class:`ValueError`, so existing
    ``except ValueError`` code keeps working.
    """


class ContentMismatch(FlashError):
    """
    The array does not hold the expected content.

    Raised by the content checks only. It is a check failure, not an invalid
    argument, so it is not a :class:`ValueError`, and the backend reports it
    as an error on the checker of the flash rather than as a failure.
    """
