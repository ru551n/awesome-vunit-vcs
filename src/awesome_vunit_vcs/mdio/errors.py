# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The exceptions of the MDIO API.

::

    AwesomeVunitVcsError
    +-- MdioError
        +-- MdioValueError (also a ValueError)
"""

from __future__ import annotations

from ..errors import AwesomeVunitVcsError

__all__ = ["MdioError", "MdioValueError"]


class MdioError(AwesomeVunitVcsError):
    """The base of every exception the MDIO package raises on purpose."""


class MdioValueError(MdioError, ValueError):
    """An invalid argument, such as a register address out of range or an unknown check name."""
