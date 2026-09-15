# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The Hypothesis strategy of the handle-table resources example."""

from hypothesis import strategies as st
from hypothesis.stateful import Bundle, RuleBasedStateMachine, consumes, multiple, rule

from awesome_vunit_vcs.common.property import step

BYTE = st.integers(0, 255)


# docs-start: resources
class HandleTable(RuleBasedStateMachine):
    """A reference model of the 4-slot handle table: a read returns the last write.

    ``handles`` is a Bundle tracking the object identity of every live handle, so a
    rule can only write, read or release a handle actually allocated and not yet
    released. ``model`` is the last written value of each live handle.
    """

    handles = Bundle("handles")

    def __init__(self):
        super().__init__()
        self.model: dict[int, int] = {}

    @rule(target=handles)
    def allocate(self):
        handle = step("allocate")
        if handle == -1:
            return multiple()  # the table was full: no handle added to the bundle
        assert handle not in self.model, f"allocate returned {handle}, which is already live"
        self.model[handle] = 0
        return handle

    @rule(handle=handles, value=BYTE)
    def write(self, handle, value):
        step("write", handle=handle, value=value)
        self.model[handle] = value

    @rule(handle=handles)
    def read(self, handle):
        assert step("read", handle=handle) == self.model[handle]

    @rule(handle=consumes(handles))
    def release(self, handle):
        step("release", handle=handle)
        del self.model[handle]


# docs-end: resources


def resources():
    return HandleTable
