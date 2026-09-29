# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The backend of the MDIO PHY verification component.

The VHDL PHY creates one backend in its own Python session, as the object ``vc``,
and calls it twice per frame: at the end of the header and at the end of the frame.
A ``time`` is what ``arg_time`` sends and a ``text`` what ``arg_text`` sends; Python
callers pass fs and ``str`` instead. No method raises into the bridge: a failed
check is an :attr:`~awesome_vunit_vcs.common.reports.Severity.ERROR` report and any
other exception a :attr:`~awesome_vunit_vcs.common.reports.Severity.FAILURE` report.

::

    MdioPhyBackend(name: text, phy_address, preamble_bits)
    set_arguments(*args, **kwargs); create_device(model: text)        -> num_reports
    header(preamble_ones, header, metavalues, now: time)             -> [action, data, num_reports]
    write_end(ta, data, metavalues, now: time)                        -> num_reports
    read_end(ta_driven, contention_bits, data, now: time)             -> num_reports
    set_register(register_address, value)                             -> num_reports
    get_register(register_address)                                    -> value
    check_register(register_address, expected, message: text, now: time) -> num_reports
    check_count(check: text)                                          -> count
    access_count(operation, register_address)                         -> count
"""

from __future__ import annotations

import importlib
from collections.abc import Sequence
from typing import Any

import numpy as np
import numpy.typing as npt

from ..common.backend import VcBackend, int32_array
from ..common.vunit_bridge import decode_text, decode_time_fs
from .devices import MdioDevice
from .errors import MdioValueError
from .phy import Action, MdioOperation, MdioPhy, MdioViolation, Response

__all__ = ["MdioPhyBackend"]

#: The device models a PHY names without a module
DEVICE_MODELS: dict[str, type[MdioDevice]] = {"registers": MdioDevice}


class MdioPhyBackend(VcBackend):
    """
    The Python object behind a VHDL MDIO PHY: an :class:`~awesome_vunit_vcs.mdio.phy.MdioPhy` with a
    device model.

    Args:
        name: The name of the PHY, used in messages.
        phy_address: The address the PHY answers.
        preamble_bits: The preamble ones the PHY needs, 0 to accept a suppressed preamble.

    Attributes:
        phy: The protocol engine; ``phy.device`` is the device model and ``phy.accesses`` the frames
            it answered.
    """

    def __init__(self, name: str | Sequence[int], phy_address: int, preamble_bits: int = 32) -> None:
        super().__init__(name)
        self._phy_address = phy_address
        self._preamble_bits = preamble_bits
        self._arguments: tuple[tuple[Any, ...], dict[str, Any]] = ((), {})
        self.phy = self.guard("configure", lambda: self._make_phy(MdioDevice()), MdioPhy(MdioDevice(), 0))

    def _make_phy(self, device: MdioDevice) -> MdioPhy:
        return MdioPhy(device, self._phy_address, self._preamble_bits, on_violation=self._violation)

    def _violation(self, violation: MdioViolation) -> None:
        self.error(violation.message)

    @property
    def device(self) -> MdioDevice:
        """The device model."""
        return self.phy.device

    def set_arguments(self, *args: Any, **kwargs: Any) -> None:
        """The arguments of the device model :meth:`create_device` creates next."""
        self._arguments = (args, kwargs)

    def create_device(self, model: str | Sequence[int]) -> int:
        """
        Create the device model and use it from now on.

        Args:
            model: ``"registers"`` or ``"package.module:Class"`` of a subclass of
                :class:`~awesome_vunit_vcs.mdio.devices.MdioDevice`, called with the arguments of
                :meth:`set_arguments`.

        Returns:
            The number of reports waiting.
        """
        args, kwargs = self._arguments
        self._arguments = ((), {})

        def create() -> None:
            name = decode_text(model).strip()
            if name in DEVICE_MODELS:
                cls: Any = DEVICE_MODELS[name]
            elif ":" in name:
                module, _, attribute = name.partition(":")
                cls = getattr(importlib.import_module(module), attribute)
            else:
                known = ", ".join(sorted(DEVICE_MODELS))
                raise MdioValueError(f"Unknown device model {name!r}: use {known} or 'package.module:Class'")
            device = cls(*args, **kwargs)
            if not isinstance(device, MdioDevice):
                raise MdioValueError(f"{name} is not an MdioDevice")
            self.phy = self._make_phy(device)

        self.guard("create_device", create, None)
        return len(self.reports)

    def header(
        self, preamble_ones: int, header: int, metavalues: int, now: int | Sequence[int]
    ) -> npt.NDArray[np.int32]:
        """The bits from ST to REGAD were sampled. Returns ``[action, data, num_reports]``."""
        response = self.guard(
            "header",
            lambda: self.phy.header(preamble_ones, header, metavalues, decode_time_fs(now)),
            Response(Action.IGNORE),
        )
        return int32_array([int(response.action), response.data, len(self.reports)])

    def write_end(self, ta: int, data: int, metavalues: int, now: int | Sequence[int]) -> int:
        """The TA and data bits of a write were sampled. Returns the number of reports waiting."""
        self.guard("write_end", lambda: self.phy.write_end(ta, data, metavalues, decode_time_fs(now)), None)
        return len(self.reports)

    def read_end(self, ta_driven: bool, contention_bits: int, data: int, now: int | Sequence[int]) -> int:
        """The PHY sent the data of a read. Returns the number of reports waiting."""
        self.guard(
            "read_end", lambda: self.phy.read_end(bool(ta_driven), contention_bits, data, decode_time_fs(now)), None
        )
        return len(self.reports)

    def set_register(self, register_address: int, value: int) -> int:
        """Set a register without the bus. Returns the number of reports waiting."""
        self.guard("set_register", lambda: self.device.set_register(register_address, value), None)
        return len(self.reports)

    def get_register(self, register_address: int) -> int:
        """A register value, read without the bus; 0 with a failure report for a bad address."""
        return self.guard("get_register", lambda: self.device.get_register(register_address), 0)

    def check_register(
        self, register_address: int, expected: int, message: str | Sequence[int] = "", now: int | Sequence[int] = 0
    ) -> int:
        """Compare a register with ``expected``; a difference is a check failure (``MDIO_REGISTER``)."""
        self.guard(
            "check_register",
            lambda: self.phy.check_register(register_address, expected, decode_time_fs(now), decode_text(message)),
            None,
        )
        return len(self.reports)

    def check_count(self, check: str | Sequence[int]) -> int:
        """The number of violations of a check, named as :class:`~awesome_vunit_vcs.mdio.phy.MdioCheckId` parses."""
        return self.guard("check_count", lambda: self.phy.check_count(decode_text(check)), 0)

    def access_count(self, operation: int = 0, register_address: int = -1) -> int:
        """
        The number of frames the PHY answered.

        Args:
            operation: 0 for reads and writes, else the OP field of one of them.
            register_address: -1 for every register.
        """
        return self.guard(
            "access_count",
            lambda: self.phy.access_count(
                MdioOperation(operation) if operation else None, None if register_address < 0 else register_address
            ),
            0,
        )

    def reset(self) -> int:
        """Nothing to forget in Python; the device keeps its registers. Returns the number of reports waiting."""
        return len(self.reports)
