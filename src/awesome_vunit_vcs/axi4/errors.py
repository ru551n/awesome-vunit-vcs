# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The exceptions of the AXI4 API.

::

    AwesomeVunitVcsError
    +-- Axi4Error
        +-- Axi4ValueError (also a ValueError)
"""

from __future__ import annotations

from ..errors import AwesomeVunitVcsError

__all__ = ["Axi4Error", "Axi4ValueError"]


class Axi4Error(AwesomeVunitVcsError):
    """The base of every exception the AXI4 package raises on purpose."""


class Axi4ValueError(Axi4Error, ValueError):
    """An invalid argument or configuration, such as a data width that is not a power of 2 or an unknown check."""
