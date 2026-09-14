"""Publish/subscribe fan-out: sample once, deliver to every consumer."""

from __future__ import annotations

from collections.abc import Callable
from typing import Generic, TypeVar

T = TypeVar("T")

Subscriber = Callable[[T], None]
ErrorHandler = Callable[[Callable[..., None], BaseException], None]


class Publisher(Generic[T]):
    """
    Deliver events to subscribers in subscription order.

    A subscriber raising an exception does not stop delivery to the others.
    The exception goes to ``on_error`` when one is given and is re-raised
    otherwise, after the remaining subscribers have been called.
    """

    __slots__ = ("_on_error", "_subscribers")

    def __init__(self, on_error: ErrorHandler | None = None) -> None:
        self._subscribers: list[Subscriber[T]] = []
        self._on_error = on_error

    def subscribe(self, subscriber: Subscriber[T]) -> Callable[[], None]:
        """Add a subscriber and return a function that removes it again."""
        self._subscribers.append(subscriber)

        def unsubscribe() -> None:
            if subscriber in self._subscribers:
                self._subscribers.remove(subscriber)

        return unsubscribe

    def publish(self, event: T) -> None:
        first_error: BaseException | None = None
        for subscriber in tuple(self._subscribers):
            try:
                subscriber(event)
            except Exception as exc:
                if self._on_error is not None:
                    self._on_error(subscriber, exc)
                elif first_error is None:
                    first_error = exc
        if first_error is not None:
            raise first_error

    def __len__(self) -> int:
        return len(self._subscribers)
