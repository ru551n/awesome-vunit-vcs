# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The strategy for tb_property_interleaving: a concurrent event schedule for the two-client arbiter."""

from collections.abc import Sequence
from typing import TypedDict

from hypothesis import strategies as st


class Event(TypedDict):
    """Client ``actor`` does ``action`` on ``cycle``; several events may share a cycle."""

    cycle: int
    actor: str
    action: str


# docs-start: event-schedule
def event_schedule(
    actors: Sequence[str], actions: Sequence[str], max_cycle: int, max_events: int
) -> st.SearchStrategy[list[Event]]:
    """
    A schedule of events on cycles 0..max_cycle, several per cycle allowed.

    Events are unique by (cycle, actor, action): a repeated one is a no-op for
    the design under test, and letting Hypothesis draw it anyway leaves
    redundant copies its shrinker cannot reliably prune. VHDL replays the
    schedule cycle by cycle, scanning the whole list each cycle, so its order
    does not matter and it is left unsorted for Hypothesis to shrink freely.
    """
    event: st.SearchStrategy[Event] = st.fixed_dictionaries(
        {"cycle": st.integers(0, max_cycle), "actor": st.sampled_from(actors), "action": st.sampled_from(actions)}
    )
    return st.lists(event, max_size=max_events, unique_by=lambda item: (item["cycle"], item["actor"], item["action"]))


# docs-end: event-schedule


# docs-start: interleaving
def interleaving() -> st.SearchStrategy[dict[str, list[Event]]]:
    """The two clients' request/cancel/release schedule, replayed clock-accurately in VHDL."""
    schedule = event_schedule(actors=["A", "B"], actions=["request", "cancel", "release"], max_cycle=7, max_events=8)
    return st.fixed_dictionaries({"events": schedule})


# docs-end: interleaving
