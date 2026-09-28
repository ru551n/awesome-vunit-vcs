# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The exceptions of the I2C API.

::

    AwesomeVunitVcsError
    +-- I2cError
        +-- I2cValueError (also a ValueError)
"""

from __future__ import annotations

from ..errors import AwesomeVunitVcsError


class I2cError(AwesomeVunitVcsError):
    """The base of every exception the I2C package raises on purpose."""


class I2cValueError(I2cError, ValueError):
    """An invalid argument or configuration, such as an address out of range or an unknown check name."""
