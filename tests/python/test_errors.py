# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""One base exception catches the errors of every family."""

from __future__ import annotations

import pytest

import awesome_vunit_vcs
from awesome_vunit_vcs import AwesomeVunitVcsError
from awesome_vunit_vcs import ethernet as eth
from awesome_vunit_vcs.ethernet.errors import EthernetValueError
from awesome_vunit_vcs.flash.config import FlashConfig
from awesome_vunit_vcs.flash.errors import ContentMismatch, FlashError, FlashValueError


def test_ethernet_validation_errors_are_package_errors() -> None:
    with pytest.raises(AwesomeVunitVcsError):
        eth.fs("eight nanoseconds")
    assert issubclass(EthernetValueError, AwesomeVunitVcsError)
    assert issubclass(EthernetValueError, ValueError)


def test_flash_errors_are_package_errors() -> None:
    with pytest.raises(AwesomeVunitVcsError):
        FlashConfig(size_bytes=3)
    assert issubclass(FlashError, AwesomeVunitVcsError)
    assert issubclass(FlashValueError, FlashError)
    assert issubclass(FlashValueError, ValueError)
    assert issubclass(ContentMismatch, FlashError)


def test_the_base_exception_is_exported_from_the_package() -> None:
    assert awesome_vunit_vcs.AwesomeVunitVcsError is AwesomeVunitVcsError
    assert "AwesomeVunitVcsError" in awesome_vunit_vcs.__all__
