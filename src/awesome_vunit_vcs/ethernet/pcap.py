"""
PCAPNG capture of monitored frames, readable by Wireshark.

PCAPNG rather than classic PCAP because it carries what a verification
capture needs: a per-interface timestamp resolution (down to femtoseconds)
and per-packet link-layer error flags (CRC, preamble, SFD, IFG, size,
symbol errors) and comments, so errored frames stay recognizable.

What a capture contains
-----------------------
* Link type ``LINKTYPE_ETHERNET``: frames start at the destination address.
  Preamble and SFD are never written (this link type has no room for them).
* The FCS is written by default (``include_fcs``); every packet then says so
  with the FCS length field of ``epb_flags``.
* Errored frames are written by default (``include_errored``) with their error
  flags and a comment. Frames without SFD have no MAC frame and are skipped.
* The timestamp is the time of the first octet after the SFD.
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from typing import BinaryIO

from .errors import EthernetValueError
from .frame import FCS_OCTETS, EthernetFrame

LINKTYPE_ETHERNET = 1

_BLOCK_SHB = 0x0A0D0D0A
_BLOCK_IDB = 0x00000001
_BLOCK_EPB = 0x00000006
_BYTE_ORDER_MAGIC = 0x1A2B3C4D

_OPT_ENDOFOPT = 0
_OPT_COMMENT = 1
_OPT_SHB_USERAPPL = 4
_OPT_IF_NAME = 2
_OPT_IF_SPEED = 8
_OPT_IF_TSRESOL = 9
_OPT_EPB_FLAGS = 2

_FLAG_FCS_LENGTH_SHIFT = 5
FLAG_SYMBOL_ERROR = 1 << 31
FLAG_PREAMBLE_ERROR = 1 << 30
FLAG_SFD_ERROR = 1 << 29
FLAG_UNALIGNED_ERROR = 1 << 28
FLAG_IFG_ERROR = 1 << 27
FLAG_TOO_SHORT = 1 << 26
FLAG_TOO_LONG = 1 << 25
FLAG_CRC_ERROR = 1 << 24


@dataclass(slots=True, frozen=True)
class CaptureOptions:
    """What a capture contains, see the module documentation."""

    #: Write the FCS at the end of every packet
    include_fcs: bool = True
    #: Write frames that failed a check, flagged with their errors
    include_errored: bool = True
    #: The timestamp resolution as 10**-exponent seconds, 9 for ns and 15 for fs
    timestamp_resolution_exponent: int = 9
    #: Flag packets preceded by a shorter gap; None never flags the gap
    min_ifg_octets: int | None = 12

    def __post_init__(self) -> None:
        if not 0 <= self.timestamp_resolution_exponent <= 15:
            raise EthernetValueError("timestamp_resolution_exponent must be 0..15 (femtoseconds at most)")


def _pad(data: bytes) -> bytes:
    return data + bytes(-len(data) % 4)


def _option(code: int, value: bytes) -> bytes:
    return struct.pack("<HH", code, len(value)) + _pad(value)


def _block(block_type: int, body: bytes) -> bytes:
    total = 12 + len(body)
    return struct.pack("<II", block_type, total) + body + struct.pack("<I", total)


class PcapNgWriter:
    """Write frames (:class:`~awesome_vunit_vcs.ethernet.frame.EthernetFrame`) as they arrive via :meth:`on_frame`."""

    def __init__(
        self,
        path: str | os.PathLike[str],
        options: CaptureOptions | None = None,
        *,
        interface_name: str = "ethernet",
        link_rate_bps: int | None = None,
    ) -> None:
        self.path = os.fspath(path)
        self.options = options or CaptureOptions()
        self.frames_written = 0
        self.frames_skipped = 0
        self._file: BinaryIO | None = open(self.path, "wb")  # noqa: SIM115 - closed by close()
        shb = struct.pack("<IHHq", _BYTE_ORDER_MAGIC, 1, 0, -1)
        shb += _option(_OPT_SHB_USERAPPL, b"awesome-vunit-vcs") + _option(_OPT_ENDOFOPT, b"")
        idb = struct.pack("<HHI", LINKTYPE_ETHERNET, 0, 0)
        idb += _option(_OPT_IF_NAME, interface_name.encode())
        idb += _option(_OPT_IF_TSRESOL, bytes([self.options.timestamp_resolution_exponent]))
        if link_rate_bps:
            idb += _option(_OPT_IF_SPEED, struct.pack("<Q", link_rate_bps))
        idb += _option(_OPT_ENDOFOPT, b"")
        self._write(_block(_BLOCK_SHB, shb) + _block(_BLOCK_IDB, idb))

    def _write(self, data: bytes) -> None:
        if self._file is None:
            raise ValueError(f"The capture {self.path} is closed")
        self._file.write(data)
        # Flushed per block so the capture is complete even if the simulation stops abruptly
        self._file.flush()

    def on_frame(self, frame: EthernetFrame) -> None:
        """Write a frame, or count it as skipped when the options exclude it or it has no SFD."""
        options = self.options
        if frame.mac is None or (not options.include_errored and not frame.is_good):
            self.frames_skipped += 1
            return

        data = frame.mac.data
        flags = 0
        if frame.mac.has_fcs:
            if options.include_fcs:
                flags |= FCS_OCTETS << _FLAG_FCS_LENGTH_SHIFT
            else:
                data = frame.mac.mac_octets
        problems = []
        if frame.fcs_ok is False:
            flags |= FLAG_CRC_ERROR
            problems.append("bad FCS")
        if frame.has_phy_error:
            flags |= FLAG_SYMBOL_ERROR
            problems.append("PHY error")
        if not frame.preamble_ok:
            flags |= FLAG_PREAMBLE_ERROR
            problems.append("malformed preamble")
        if frame.phy.alignment_error:
            flags |= FLAG_UNALIGNED_ERROR
            problems.append("incomplete final octet")
        if frame.is_runt:
            flags |= FLAG_TOO_SHORT
            problems.append("runt")
        if frame.is_giant:
            flags |= FLAG_TOO_LONG
            problems.append("oversized")
        min_ifg = options.min_ifg_octets
        if min_ifg is not None and frame.ifg_octets is not None and frame.ifg_octets < min_ifg:
            flags |= FLAG_IFG_ERROR
            problems.append(f"IFG {frame.ifg_octets} octets")

        timestamp = frame.timestamp_mac_fs // 10 ** (15 - options.timestamp_resolution_exponent)
        body = struct.pack("<IIIII", 0, timestamp >> 32, timestamp & 0xFFFFFFFF, len(data), len(data))
        body += _pad(data)
        body += _option(_OPT_EPB_FLAGS, struct.pack("<I", flags))
        comment = f"frame {frame.index}" + (": " + ", ".join(problems) if problems else "")
        body += _option(_OPT_COMMENT, comment.encode()) + _option(_OPT_ENDOFOPT, b"")
        self._write(_block(_BLOCK_EPB, body))
        self.frames_written += 1

    def close(self) -> None:
        """Close the file; closing twice is harmless."""
        if self._file is not None:
            self._file.close()
            self._file = None

    def __enter__(self) -> PcapNgWriter:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
