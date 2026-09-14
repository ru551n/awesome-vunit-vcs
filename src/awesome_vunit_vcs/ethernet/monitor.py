"""
The passive monitor pipeline: sample once, fan out in Python.

::

    sample words -> PHY decoder -> FrameAssembler -> FrameDecoder -> frames
                                                                    |-> ProtocolChecker
                                                                    |-> PerformanceMonitor
                                                                    |-> PcapNgWriter
                                                                    '-> user subscribers
"""

from __future__ import annotations

import os
from collections import deque
from collections.abc import Callable

from ..common.events import ErrorHandler, Publisher
from .checker import ProtocolChecker
from .frame import EthernetConfig, EthernetFrame, FrameDecoder
from .metrics import PerformanceMonitor
from .pcap import CaptureOptions, PcapNgWriter
from .phy.common import FrameAssembler, IdleEvent, Int64Array, PhyEvent, PhyFrame, PhyInterface


class EthernetMonitor:
    """
    Reconstruct frames from sample words and publish them to every consumer.

    The pipeline behind a VHDL monitor, usable from plain Python. The checker,
    the statistics and :attr:`history` are subscribed when the monitor is
    created; captures and user subscribers are added later.

    Args:
        phy: The PHY decoder of the interface, see :func:`~.phy.create_phy`.
        config: What a well-formed frame is. The default is IEEE 802.3.
        name: Used in messages and as the capture interface name.
        keep_frames: How many of the most recent frames :attr:`history` keeps.
        on_subscriber_error: Called with the subscriber and the exception when
            a subscriber raises. Without it the exception is re-raised by
            :meth:`feed` after the other subscribers were called.

    Attributes:
        frames: Publishes every :class:`~.frame.EthernetFrame`.
        idle_events: Publishes every :class:`~.phy.common.IdleEvent`.
        checker: The :class:`~.checker.ProtocolChecker`.
        statistics: The :class:`~.metrics.PerformanceMonitor`.
        frame_count: Frames received so far.
    """

    def __init__(
        self,
        phy: PhyInterface,
        config: EthernetConfig | None = None,
        *,
        name: str = "ethernet_monitor",
        keep_frames: int = 256,
        on_subscriber_error: ErrorHandler | None = None,
    ) -> None:
        self.name = name
        self.phy = phy
        self.config = config or EthernetConfig()
        self.frames: Publisher[EthernetFrame] = Publisher(on_subscriber_error)
        self.idle_events: Publisher[IdleEvent] = Publisher(on_subscriber_error)
        #: Events of PHY decoders that signal with control characters (XGMII)
        self.phy_events: Publisher[PhyEvent] = Publisher(on_subscriber_error)
        self.checker = ProtocolChecker(self.config)
        self.statistics = PerformanceMonitor(phy.link_rate_bps)
        #: The most recent frames, oldest first
        self.history: deque[EthernetFrame] = deque(maxlen=keep_frames)
        self.frame_count = 0
        self._assembler = FrameAssembler()
        self._decoder = FrameDecoder(self.config)
        self._captures: list[tuple[PcapNgWriter, Callable[[], None]]] = []

        self.frames.subscribe(self.history.append)
        self.frames.subscribe(self.checker.on_frame)
        self.frames.subscribe(self.statistics.on_frame)
        self.idle_events.subscribe(self.checker.on_idle_event)
        self.idle_events.subscribe(self.statistics.on_idle_event)
        self.phy_events.subscribe(self.checker.on_phy_event)

    def feed(self, words: Int64Array, times: Int64Array) -> None:
        """
        Process sample words.

        Frames and events are published as soon as they are complete; a frame
        still in progress at the end of the batch continues in the next one.

        Args:
            words: Interface specific sample words, see :mod:`.phy.common`.
            times: The time of each sample in fs, not decreasing.
        """
        batch = self.phy.decode(words, times)
        # A batch is at most a few frames, so publishing its PHY events first
        # keeps them close enough to the frames they occurred around
        for event in batch.events:
            self.phy_events.publish(event)
        for item in self._assembler.feed(batch):
            if isinstance(item, PhyFrame):
                self.frame_count += 1
                self.frames.publish(self._decoder.decode(item))
            else:
                self.idle_events.publish(item)

    def finish(self, end_fs: int) -> None:
        """Report a frame still in progress at the end of monitoring."""
        phy = self._assembler.finish(end_fs)
        if phy is not None:
            self.checker.on_unfinished_frame(self._decoder.decode(phy))

    @property
    def in_frame(self) -> bool:
        """Whether a frame is being received."""
        return self._assembler.in_frame

    def start_capture(self, path: str | os.PathLike[str], options: CaptureOptions | None = None) -> PcapNgWriter:
        """
        Write the frames received from now on to a PCAPNG file.

        Args:
            path: The file to create; an existing file is overwritten.
            options: What the capture contains, see :class:`~.pcap.CaptureOptions`.

        Returns:
            The writer, subscribed to :attr:`frames` until :meth:`stop_captures`.
        """
        writer = PcapNgWriter(path, options, interface_name=self.name, link_rate_bps=self.phy.link_rate_bps)
        self._captures.append((writer, self.frames.subscribe(writer.on_frame)))
        return writer

    def stop_captures(self) -> None:
        """Unsubscribe and close every capture."""
        for writer, unsubscribe in self._captures:
            unsubscribe()
            writer.close()
        self._captures.clear()
