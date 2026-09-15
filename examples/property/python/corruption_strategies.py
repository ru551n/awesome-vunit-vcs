# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Hypothesis strategies for the fault-injection and packet-mutation examples."""

# docs-start: fault_injection
from typing import Literal, TypedDict

from hypothesis import strategies as st

BYTE = st.integers(0, 255)
MAGIC = 0xA5


class Fault(TypedDict):
    kind: Literal["flip_data", "flip_parity"]
    position: int


class FaultExample(TypedDict):
    data: int
    fault: Fault | None


def fault_injection() -> st.SearchStrategy[FaultExample]:
    kind = st.sampled_from(["flip_data", "flip_parity"])
    fault = st.fixed_dictionaries({"kind": kind, "position": st.integers(0, 7)})
    return st.fixed_dictionaries({"data": BYTE, "fault": st.none() | fault})


# docs-end: fault_injection


# docs-start: packet_mutation
class MutatedPacket(TypedDict):
    packet: list[int]
    mutation: str
    valid: bool


MUTATIONS = ["none", "bad_magic", "wrong_length", "bad_checksum", "truncation", "invalid_reserved_bit"]


@st.composite
def valid_packet(draw: st.DrawFn) -> list[int]:
    """magic, length, flags (reserved bits clear), payload, checksum: a well-formed packet."""
    payload = draw(st.lists(BYTE, max_size=4))
    flags = draw(st.integers(0, 1))  # bit 0 only; bits 7..1 are reserved and must stay 0
    header = [MAGIC, len(payload), flags]
    return [*header, *payload, sum(header + payload) % 256]


@st.composite
def mutated_packet(draw: st.DrawFn) -> MutatedPacket:
    """A valid packet, then optionally one meaningful mutation of a single semantic rule."""
    packet = draw(valid_packet())
    mutation = draw(st.sampled_from(MUTATIONS))
    if mutation == "bad_magic":
        packet[0] = draw(BYTE.filter(lambda v: v != MAGIC))
    elif mutation == "wrong_length":
        packet[1] = draw(BYTE.filter(lambda v: v != packet[1]))
    elif mutation == "bad_checksum":
        packet[-1] = (packet[-1] + draw(st.integers(1, 255))) % 256
    elif mutation == "truncation":
        packet = packet[:-1]
    elif mutation == "invalid_reserved_bit":
        packet[2] |= 1 << draw(st.integers(1, 7))
        packet[-1] = sum(packet[:-1]) % 256  # keep the checksum honest: only the reserved bit is wrong
    return {"packet": packet, "mutation": mutation, "valid": mutation == "none"}


# docs-end: packet_mutation
