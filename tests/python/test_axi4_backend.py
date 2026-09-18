# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""The backends of the AXI4 VHDL components, called the way VHDL calls them."""

from __future__ import annotations

import numpy as np
from axi4_helpers import PERIOD_FS, Recorder

from awesome_vunit_vcs.axi4.vunit_backend import Axi4MemoryBackend, Axi4MonitorBackend, Axi4ProtocolCheckerBackend
from awesome_vunit_vcs.common.reports import Severity, decode_reports
from awesome_vunit_vcs.common.vunit_bridge import encode_samples, split_time

TEXT = [ord(c) for c in "tb:monitor"]


def _push(backend: Axi4MonitorBackend | Axi4ProtocolCheckerBackend, bus: Recorder) -> int:
    words, times = bus.take()
    return backend.push(encode_samples(words, times, 0, 1000), split_time(0), split_time(1000))


def _monitor(**kwargs: bool) -> Axi4MonitorBackend:
    return Axi4MonitorBackend(TEXT, data_width=32, address_width=40, id_width=4, **kwargs)


def _write_burst(bus: Recorder) -> Recorder:
    bus.period().aw(id=6, addr=0xFF_8000_0002, len=1, size=1, lock=0).step()
    bus.w(0xAABB0000, strb=0b1100, last=False).step().w(0x0000CCDD, strb=0b0001).step().b(id=6, resp=2).step()
    return bus


def test_a_popped_transaction_is_flat_for_vhdl() -> None:
    backend = _monitor()
    assert _push(backend, _write_burst(Recorder(address_width=40))) == 0
    flat = backend.pop_transaction().tolist()
    # flags: write; ID 6; address 0xFF_8000_0002 as hi 0xFF, lo 0x80000002 signed; len 1; size 1; INCR;
    # cache, prot, qos, region 0; SLVERR; times 0, 10, 20, 30 ns as [hi, lo]; 4 bytes: lanes 2-3 of the
    # first beat, both written, then lanes 0-1 of the second, only lane 0 written
    header = [1, 6, 0xFF, 0x80000002 - (1 << 32), 1, 1, 1, 0, 0, 0, 0, 2]
    times = [*split_time(0), *split_time(PERIOD_FS), *split_time(2 * PERIOD_FS), *split_time(3 * PERIOD_FS)]
    assert flat == [*header, *times, 4, 0xBB | 256, 0xAA | 256, 0xDD | 256, 0xCC]
    assert backend.pop_transaction().tolist() == []


def test_published_transactions_are_collected_only_while_publishing() -> None:
    backend = _monitor()
    _push(backend, _write_burst(Recorder(address_width=40)))
    assert backend.take_published().tolist() == []
    backend.set_publish(True)
    _push(backend, _write_burst(Recorder(address_width=40)))
    assert len(backend.take_published()) == 21 + 4


def test_check_transaction_reports_differences_and_missing_transactions() -> None:
    backend = _monitor()
    backend.check_transaction(True, 0xFF, 0x80000002 - (1 << 32), [0xBB, 0xAA, 0xDD, 0x00], 6, 2, "burst")
    backend.check_transaction(True, 0, 0x100, [1, 2, 3, 4], -1, -1, [ord("x")])
    backend.check_transaction(False, 0, 0x200, [], -1, -1, "")
    _push(backend, _write_burst(Recorder(address_width=40)))  # matches, the unwritten byte is not compared
    assert backend.num_reports() == 0
    bus = Recorder(address_width=40)
    bus.aw(id=1, addr=0x104).w(0x04030201).step().b(id=1, resp=1)
    assert _push(backend, bus) == 1  # the address differs; EXOKAY to a normal write is the checker's matter
    assert backend.finish() == 2
    reports = decode_reports(backend.take_reports())
    assert [report.severity for report in reports] == [Severity.ERROR] * 2
    assert "AXI4_SCOREBOARD: x: the write ID 1 at 0x104" in reports[0].message
    assert "address 0x104, expected 0x100" in reports[0].message
    assert "the expected read at 0x200 never came" in reports[1].message


def test_metavalues_are_reported_by_a_monitor_without_a_checker() -> None:
    bus = Recorder(address_width=40)
    bus.period().ar(valid=False, valid_x=True)
    reporting, quiet = _monitor(), _monitor(report_metavalues=False)
    assert _push(reporting, bus) == 1
    assert _push(quiet, Recorder(address_width=40).period().ar(valid=False, valid_x=True)) == 0
    (report,) = decode_reports(reporting.take_reports())
    assert report.message == "tb:monitor: AXI4_METAVALUE: metavalue on ARVALID, ARREADY or the AR payload at 0 fs"


def test_statistics_values_follow_the_vhdl_record() -> None:
    backend = _monitor()
    bus = Recorder(address_width=40)
    bus.period().aw(addr=0).w(1).step(3).b().step().ar(addr=0, ready=False).step().ar(addr=0).step(4).r(data=1)
    _push(backend, bus)
    values = backend.statistics_values(split_time(10 * PERIOD_FS)).tolist()
    # writes, reads; bytes; bandwidth in Mbit/s over 100 ns; outstanding; write latency 3 cycles; read
    # latency 4; stalls AW, W, B, AR, R; error responses; 11 cycles
    assert values == [1, 1, 4, 4, 320, 320, 1, 1, 3, 3, 3, 4, 4, 4, 0, 0, 0, 1, 0, 0, 11]
    summary = backend.statistics_summary(split_time(10 * PERIOD_FS))
    assert summary.startswith("tb:monitor: 11 cycles of 10000000 fs")


def test_reset_forgets_kept_and_expected_transactions() -> None:
    backend = _monitor(shadow_memory=True)
    _push(backend, _write_burst(Recorder(address_width=40)))
    backend.check_transaction(False, 0, 0, [], -1, -1, "")
    assert backend.reset(clear_statistics=True) == 0
    assert backend.pop_transaction().tolist() == []
    assert backend.finish() == 0
    assert backend.statistics_values(split_time(0)).tolist()[0] == 0


def test_a_subscriber_that_raises_is_a_failure() -> None:
    backend = _monitor()

    def broken(_: object) -> None:
        raise RuntimeError("boom")

    backend.monitor.transactions.subscribe(broken)
    assert _push(backend, _write_burst(Recorder(address_width=40))) == 1
    (report,) = decode_reports(backend.take_reports())
    assert report.severity == Severity.FAILURE and "RuntimeError: boom" in report.message


def test_invalid_widths_are_a_failure_not_an_exception() -> None:
    backend = Axi4MonitorBackend(TEXT, data_width=24)
    (report,) = decode_reports(backend.take_reports())
    assert report.severity == Severity.FAILURE and "data_width=24" in report.message


def test_protocol_checker_backend() -> None:
    backend = Axi4ProtocolCheckerBackend(TEXT, data_width=32, address_width=40, id_width=4, timeout_cycles=2)
    assert backend.set_check_enabled([ord(c) for c in "axi4_rlast"], False) == 0
    bus = Recorder(address_width=40)
    bus.period().ar(id=1, len=1).step().r(id=1, last=True).step().r(id=1, last=True).step().b(id=2)
    assert _push(backend, bus) == 1  # RLAST is off; the RLAST beat count ends the read, then BID 2
    assert backend.check_count([ord(c) for c in "AXI4_RLAST"]) == 0
    assert backend.check_count("AXI4_UNEXPECTED_RESP") == 1
    reports = decode_reports(backend.take_reports())
    assert reports[0].message.startswith("tb:monitor: AXI4_UNEXPECTED_RESP: write response BID 2")
    bus.ar(id=3).step()
    _push(backend, bus)
    assert backend.finish(split_time(20 * PERIOD_FS)) == 1
    assert backend.set_check_enabled("AXI4_NOPE", True) == 2
    reports = decode_reports(backend.take_reports())
    assert "AXI4_TIMEOUT" in reports[0].message and reports[1].severity == Severity.FAILURE
    assert backend.reset() == 0 and backend.check_count("AXI4_TIMEOUT") == 0


# -- the memory of the slaves ----------------------------------------------------


def test_memory_backend_backdoor_and_reports() -> None:
    backend = Axi4MemoryBackend([ord(c) for c in "tb:memory"], default_permission=0)
    assert backend.allocate(4, [ord(c) for c in "buf"], 1, 3) == 0
    assert backend.allocate(4, "far", 1, 3, address=2**40, wide=True) == 0
    assert backend.allocate(4, "far", 1, 3, address=2**40) == -1  # the address does not fit a VHDL integer
    assert decode_reports(backend.take_reports())[0].severity == Severity.FAILURE
    assert backend.write_word(2**40, [0x11, 0x22], 1) == 0
    # 0x2211 written big endian, read little endian: 0x1122, least significant byte first
    assert list(backend.read_word(2**40, 2, 0)) == [0x22, 0x11]
    assert backend.read_bytes(2**40, 2).dtype.name == "uint8"
    assert backend.set_expected_integer(0, -2, 2, 2) == 0
    assert not backend.expected_was_written(0, 2)
    assert backend.check_expected_was_written() == 2
    assert [r.message for r in decode_reports(backend.take_reports())] == [
        "The address 0 at offset 0 within buffer 'buf' at range (0 to 3) was never written with expected byte 254",
        "The address 1 at offset 1 within buffer 'buf' at range (0 to 3) was never written with expected byte 255",
    ]
    assert backend.write_integer_array(8, np.array([[1, 2], [3, 4]]), 1, 3, 2) == 0
    assert list(backend.read_bytes(8, 6)) == [1, 2, 0, 3, 4, 0]


def test_memory_backend_slaves_share_the_memory() -> None:
    backend = Axi4MemoryBackend("tb:memory")
    writer = backend.attach("tb:write_slave", 32, True, True)
    reader = backend.attach("tb:read_slave", 32, False, True)
    assert list(backend.accept_write(writer, 3, 2**33, 1, 2, 1)) == [0, 0]
    lanes = [0x100 | value for value in range(8)]
    assert list(backend.write_burst(writer, np.array(lanes))) == [0, 0]
    flat = backend.read_burst(reader, 1, 2**33 + 2, 0, 1, 1).tolist()
    # no reports, burst #0, OKAY, lanes 0-1 unused, lanes 2-3 the bytes written
    assert flat == [0, 0, 0, -1, -1, 2, 3]
    assert list(backend.statistics(writer, True))[2] == 1
    assert list(backend.statistics(writer, False))[2] == 0
    # A metavalue in a strobed byte, and a second port's reports kept apart
    backend.accept_write(writer, 0, 0, 0, 2, 1)
    assert backend.write_burst(writer, np.array([0x100, 0x300, 0, 0])).tolist() == [1, 0]
    assert backend.take_reports(reader) == ""
    assert "Metavalue in WDATA lane 1" in backend.take_reports(writer)
    assert backend.reset_slave(writer) == 0
