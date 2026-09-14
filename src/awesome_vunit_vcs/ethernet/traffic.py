"""
Traffic from Python: packet functions called by name, and seeded generators.

Python decides *what* a source sends, VHDL *when*. A testbench names a Python
function (``"my_packets:udp_to_dut"``) and passes its keyword arguments as a
string (``"port=1234, size=128"``); the source backend calls it through
:func:`call_packet_function` or :func:`sequence`. The arguments are parsed as
Python literals, never evaluated.

A function that takes a ``seed`` parameter receives the seed of the call
(VUnit's ``get_seed(runner_cfg)`` string from a testbench); :func:`rng_from`
turns it into a :class:`random.Random`. The same convention holds for the
functions the VHDL source and monitor backends call.

The generators (:func:`random_frame`, :func:`random_wire_options`,
:func:`random_traffic`) take an explicit seed or :class:`random.Random` and
draw from the bounds of :class:`~.limits.Limits`, the same parameter space a
property-based test builds its strategies from. They give a simulation
reproducible traffic from VUnit's seed.

Reproducible generation outside a test is deliberately not built on
Hypothesis: its public API draws examples only inside ``@given`` tests, and
``strategy.example()`` is documented as unsuitable for anything but
interactive exploration. Plain seeded generators over the same
:class:`~.limits.Limits` keep one definition of the space with two front
ends: Hypothesis strategies in tests, :mod:`random` in simulations.
"""

from __future__ import annotations

import ast
import importlib
import inspect
import random
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass, field
from typing import SupportsBytes

from .api import Frame, WireOptions, supported_malformations
from .errors import EthernetValueError
from .interfaces import GMII, MII, XGMII, Interface
from .limits import LIMITS, Limits, Malformation
from .phy.common import WireFrame


class TrafficError(EthernetValueError):
    """A packet function cannot be resolved or called, or returned something that is not a frame."""


#: What a packet function may return: a frame, octets without FCS, or a
#: Scapy packet (anything ``bytes()`` accepts)
Packet = Frame | bytes | SupportsBytes

#: A seed: an integer, a string such as VUnit's ``get_seed(runner_cfg)``, or a generator
Seed = int | str | random.Random


@dataclass(slots=True, frozen=True)
class TrafficItem:
    """A frame and how to put it on the wire."""

    frame: Frame
    options: WireOptions = field(default_factory=WireOptions)

    def to_wire(self) -> WireFrame:
        """What a source puts on the wire."""
        return self.frame.to_wire(self.options)

    def __bytes__(self) -> bytes:
        """The frame without FCS, as a function result converted with ``bytes()``."""
        return self.frame.data


def rng_from(seed: Seed) -> random.Random:
    """
    A random generator from a seed.

    Args:
        seed: An integer, a string (hashed deterministically, so VUnit's string
            seed works as it is) or a generator, returned unchanged.
    """
    if isinstance(seed, random.Random):
        return seed
    if isinstance(seed, bool) or not isinstance(seed, int | str):
        raise TrafficError(f"A seed is an int, a str or a random.Random, got {seed!r}")
    return random.Random(seed)


def resolve(spec: str) -> Callable[..., object]:
    """
    The callable a ``"package.module:function"`` spec names.

    Args:
        spec: A module path and a callable in it, separated by a colon, for
            example ``"my_packets:udp_to_dut"`` or ``"my_packets:Traffic.mixed"``.

    Raises:
        TrafficError: The spec is malformed, the module cannot be imported, or
            the name is missing or not callable.
    """
    module_name, colon, attribute = spec.partition(":")
    names = attribute.split(".")
    if not colon or not all(part.isidentifier() for part in [*module_name.split("."), *names]):
        raise TrafficError(f"{spec!r} is not a 'package.module:function' spec")
    try:
        target: object = importlib.import_module(module_name)
    except ImportError as exc:
        raise TrafficError(f"Cannot import module {module_name!r} of {spec!r}: {exc}") from exc
    for name in names:
        try:
            target = getattr(target, name)
        except AttributeError:
            raise TrafficError(f"{spec!r}: {module_name!r} has no attribute {attribute!r}") from None
    if not callable(target):
        raise TrafficError(f"{spec!r} is not callable")
    return target


def parse_arguments(text: str) -> dict[str, object]:
    """
    Keyword arguments from a string such as ``"port=1234, name='a', sizes=(64, 1518)"``.

    Only Python literals are accepted (numbers, strings, bytes, booleans,
    None, tuples, lists, dicts and sets of them); nothing is evaluated.

    Raises:
        TrafficError: The string is not a list of keyword arguments with literal values.
    """
    if not text.strip():
        return {}
    try:
        tree = ast.parse(f"_({text})", mode="eval")
    except SyntaxError as exc:
        raise TrafficError(f"{text!r} is not a list of keyword arguments: {exc.msg}") from None
    call = tree.body
    if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name) or call.func.id != "_":
        raise TrafficError(f"{text!r} is not a list of keyword arguments")
    if call.args:
        raise TrafficError(f"{text!r} has positional arguments; name every argument, as in 'size=128'")
    arguments: dict[str, object] = {}
    for keyword in call.keywords:
        if keyword.arg is None:
            raise TrafficError(f"{text!r} unpacks a mapping; name every argument")
        try:
            arguments[keyword.arg] = ast.literal_eval(keyword.value)
        except (ValueError, TypeError, SyntaxError, MemoryError, RecursionError):
            raise TrafficError(f"The value of {keyword.arg!r} in {text!r} is not a Python literal") from None
    return arguments


def to_frame(packet: object) -> Frame:
    """
    The frame of a packet function result.

    Args:
        packet: A :class:`~.api.Frame` (returned unchanged), frame octets without
            FCS, or anything ``bytes()`` accepts, such as a Scapy packet.

    Raises:
        TrafficError: The value is none of these.
    """
    if isinstance(packet, Frame):
        return packet
    if isinstance(packet, bytes | bytearray | memoryview):
        return Frame.from_bytes(bytes(packet), has_fcs=False)
    if isinstance(packet, SupportsBytes):
        return Frame.from_packet(packet)
    raise TrafficError(f"A packet function returned {type(packet).__name__}; expected a Frame, bytes or a packet")


def to_item(value: object) -> TrafficItem:
    """
    A traffic item from a packet function or generator result.

    Args:
        value: A :class:`TrafficItem`, a ``(packet, WireOptions)`` pair, or a packet (see :func:`to_frame`).
    """
    if isinstance(value, TrafficItem):
        return value
    if isinstance(value, tuple) and len(value) == 2 and isinstance(value[1], WireOptions):
        return TrafficItem(to_frame(value[0]), value[1])
    return TrafficItem(to_frame(value))


def _call(spec: str, arguments: str, seed: Seed | None) -> object:
    function = resolve(spec)
    kwargs = parse_arguments(arguments)
    if seed is not None:
        try:
            accepts_seed = "seed" in inspect.signature(function).parameters
        except (TypeError, ValueError):
            accepts_seed = False
        if not accepts_seed:
            raise TrafficError(f"{spec!r} takes no seed parameter, so it cannot use a seed")
        kwargs["seed"] = seed
    try:
        inspect.signature(function).bind(**kwargs)
    except TypeError as exc:
        raise TrafficError(f"Cannot call {spec!r} with {arguments!r}: {exc}") from exc
    except ValueError:
        pass  # a callable without an inspectable signature is called as it is
    return function(**kwargs)


def call_packet_function(spec: str, arguments: str = "", *, seed: Seed | None = None) -> TrafficItem:
    """
    Call a packet function by name and return the frame it built.

    Args:
        spec: The function, see :func:`resolve`.
        arguments: Its keyword arguments, see :func:`parse_arguments`.
        seed: Passed to the function as its ``seed`` argument, which it turns
            into a generator with :func:`rng_from`; the function must take a
            ``seed`` parameter.

    Returns:
        The frame and its wire options; the frame octets are ``item.frame.data`` plus the FCS.

    Raises:
        TrafficError: See :func:`resolve`, :func:`parse_arguments` and :func:`to_item`.
    """
    return to_item(_call(spec, arguments, seed))


def sequence(spec: str, arguments: str = "", *, seed: Seed | None = None) -> Iterator[TrafficItem]:
    """
    Call a generator function by name and iterate over the traffic it yields.

    Args:
        spec: A function returning an iterable of packets, ``(packet, WireOptions)`` pairs or items.
        arguments: Its keyword arguments, see :func:`parse_arguments`.
        seed: Passed as ``seed``, see :func:`call_packet_function`.

    Raises:
        TrafficError: The function does not return an iterable, or yields something that is not a frame.
    """
    result = _call(spec, arguments, seed)
    if not isinstance(result, Iterable):
        raise TrafficError(f"{spec!r} returned {type(result).__name__}, not an iterable of frames")
    return (to_item(value) for value in result)


def batches(items: Iterable[TrafficItem], max_frames: int) -> Iterator[list[TrafficItem]]:
    """
    Group traffic into lists of at most ``max_frames`` items, for one bridge call each.

    Raises:
        TrafficError: ``max_frames`` is not positive.
    """
    if max_frames <= 0:
        raise TrafficError(f"max_frames must be positive, got {max_frames}")
    batch: list[TrafficItem] = []
    for item in items:
        batch.append(item)
        if len(batch) == max_frames:
            yield batch
            batch = []
    if batch:
        yield batch


# Seeded generators, over the same bounds as a property-based test


def random_mac_address(rng: random.Random) -> bytes:
    """A locally administered unicast MAC address."""
    octets = bytearray(rng.randbytes(LIMITS.mac_address_octets))
    octets[0] = (octets[0] & 0xFC) | 0x02
    return bytes(octets)


def random_frame(
    rng: random.Random,
    *,
    min_payload_octets: int = LIMITS.min_payload_octets,
    max_payload_octets: int = LIMITS.max_payload_octets,
    limits: Limits = LIMITS,
) -> Frame:
    """
    A frame with random addresses, EtherType and payload.

    Args:
        rng: The generator.
        min_payload_octets: The shortest payload.
        max_payload_octets: The longest payload.
        limits: The bounds of the EtherType.
    """
    if not 0 <= min_payload_octets <= max_payload_octets:
        raise TrafficError("Require 0 <= min_payload_octets <= max_payload_octets")
    payload = rng.randbytes(rng.randint(min_payload_octets, max_payload_octets))
    return Frame.from_payload(
        payload,
        dst=random_mac_address(rng),
        src=random_mac_address(rng),
        ethertype=rng.randint(limits.min_ethertype, limits.max_ethertype),
    )


def random_wire_options(
    rng: random.Random, *, malformations: Iterable[Malformation | str] = (), limits: Limits = LIMITS
) -> WireOptions:
    """
    Wire options with random parameters for the given malformations, valid otherwise.

    The inter-frame gap is drawn from ``limits.min_ifg_octets`` to
    ``limits.max_ifg_octets`` unless SHORT_IFG is given. GIANT is ignored: it is
    a property of the frame (see :func:`random_traffic`).

    Args:
        rng: The generator.
        malformations: The malformations, as :class:`~.limits.Malformation` or their values.
        limits: The bounds the parameters are drawn from and violate.
    """
    kinds = {Malformation(kind) for kind in malformations}
    preamble = limits.preamble_octets
    if Malformation.SHORT_PREAMBLE in kinds:
        preamble = rng.randint(1, limits.preamble_octets - 1)
    elif Malformation.LONG_PREAMBLE in kinds:
        preamble = rng.randint(limits.preamble_octets + 1, limits.max_preamble_octets)
    sfd = limits.sfd
    if Malformation.BAD_SFD in kinds:
        sfd = rng.choice([value for value in range(256) if value not in (0x55, limits.sfd)])
    errors: tuple[int, ...] = ()
    if Malformation.PHY_ERROR in kinds:
        errors = tuple(sorted(rng.sample(range(limits.header_octets), rng.randint(1, 4))))
    if Malformation.SHORT_IFG in kinds:
        ifg = rng.randint(1, limits.min_ifg_octets - 1)
    else:
        ifg = rng.randint(limits.min_ifg_octets, limits.max_ifg_octets)
    return WireOptions(
        fcs="bad" if Malformation.BAD_FCS in kinds else "auto",
        pad=Malformation.RUNT not in kinds,
        preamble_octets=preamble,
        sfd=sfd,
        ifg_octets=ifg,
        errors=errors,
        min_frame_octets=limits.min_frame_octets,
    )


def random_traffic(
    count: int,
    *,
    seed: Seed,
    interface: Interface | str = GMII,
    malformations: Iterable[Malformation | str] = (),
    malformed_fraction: float = 0.0,
    limits: Limits = LIMITS,
) -> list[TrafficItem]:
    """
    Reproducible random traffic: the generator a VHDL source can name directly.

    Every frame is valid, except that with probability ``malformed_fraction``
    it gets one malformation drawn from ``malformations`` (restricted to those
    :func:`~.api.supported_malformations` predicts on the interface), so
    :func:`~.api.expected_violations` computes what a monitor must report.

    From VHDL: ``"awesome_vunit_vcs.ethernet.traffic:random_traffic"`` with
    arguments such as ``"count=100, malformations=('bad_fcs', 'runt'), malformed_fraction=0.1"``
    and the seed of the test.

    Args:
        count: The number of frames.
        seed: A seed or a generator, see :func:`rng_from`.
        interface: The interface, or its name, the malformations must be predictable on.
        malformations: The malformations to draw from.
        malformed_fraction: The probability of a malformed frame, 0 to 1.
        limits: The bounds of the traffic.

    Raises:
        TrafficError: A negative count or a fraction outside 0 to 1.
    """
    if count < 0:
        raise TrafficError(f"count must not be negative, got {count}")
    if not 0.0 <= malformed_fraction <= 1.0:
        raise TrafficError(f"malformed_fraction must be 0..1, got {malformed_fraction}")
    generator = rng_from(seed)
    if isinstance(interface, str):
        interface = interface_named(interface)
    kinds = sorted({Malformation(kind) for kind in malformations} & supported_malformations(interface))
    items = []
    for _ in range(count):
        kind = generator.choice(kinds) if kinds and generator.random() < malformed_fraction else None
        if kind is Malformation.RUNT:
            frame = random_frame(generator, max_payload_octets=limits.min_padded_payload_octets - 1, limits=limits)
        elif kind is Malformation.GIANT:
            frame = random_frame(
                generator,
                min_payload_octets=limits.max_payload_octets + 1,
                max_payload_octets=limits.max_payload_octets + 64,
                limits=limits,
            )
        else:
            frame = random_frame(generator, limits=limits)
        extra = () if kind is None or kind is Malformation.GIANT else (kind,)
        items.append(TrafficItem(frame, random_wire_options(generator, malformations=extra, limits=limits)))
    return items


def interface_named(name: str) -> Interface:
    """
    The default interface of a name: GMII at 1G, MII at 100M or XGMII with 4 lanes at 10G.

    Raises:
        TrafficError: An unknown name.
    """
    interfaces = {"gmii": GMII, "mii": MII, "xgmii": XGMII()}
    try:
        return interfaces[name.lower()]
    except KeyError:
        raise TrafficError(f"Unknown interface {name!r}, known: {', '.join(interfaces)}") from None
