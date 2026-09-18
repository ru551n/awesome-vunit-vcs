-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the AXI4 monitor verification component
-- (axi4_monitor.vhd).
--
-- The monitor records what happens on the five channels of an AXI4 or
-- AXI4-Lite interface at every rising edge of ACLK and never drives them. Its
-- Python backend reconstructs the transactions per ID: a write is an AW
-- handshake, its write data beats (which may come before the address) and a
-- B handshake; a read an AR handshake and its read data beats. The monitor
-- publishes every transaction as an ``axi4_transaction_msg`` to its
-- subscribers, keeps the last 1024 for
-- :vhdl:`axi4_monitor_pkg.pop_axi4_transaction`, compares them with the
-- transactions :vhdl:`axi4_monitor_pkg.check_axi4_transaction` expects,
-- checks reads against a shadow memory when asked to, and measures the
-- performance of the interface.
--
-- With a protocol checker in its handle the monitor instantiates an
-- axi4_protocol_checker on the same pins.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.axi4_pkg.all;
  use work.axi4_protocol_checker_pkg.all;
  use work.vc_python_pkg.arg_text;

package axi4_monitor_pkg is

  -- The handle of a monitor, created with :vhdl:`axi4_monitor_pkg.new_axi4_monitor`
  type axi4_monitor_t is record
    -- Private. Use the constructor and the accessors below.
    p_bus                        : axi4_bus_t;
    p_protocol_checker           : axi4_protocol_checker_t;
    p_shadow_memory              : boolean;
    p_per_id_statistics          : boolean;
    p_id                         : id_t;
    p_logger                     : logger_t;
    p_actor                      : actor_t;
    p_checker                    : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- An AXI4 monitor of an interface with the widths of ``axi4_bus``.
  -- ``protocol_checker`` is instantiated on the pins of the monitor unless it
  -- is :vhdl:`axi4_protocol_checker_pkg.null_axi4_protocol_checker`; without
  -- one, the monitor reports metavalues on VALID, READY, ARESETn and the
  -- payload itself (``AXI4_METAVALUE``). ``shadow_memory`` checks every read
  -- against the data written before it (``AXI4_SCOREBOARD``).
  -- ``per_id_statistics`` also keeps the statistics of each ID, for the
  -- summary of :vhdl:`axi4_monitor_pkg.log_axi4_statistics`.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:axi4_monitor:<n>``. The logger
  -- defaults to the logger of the id, the actor to a new actor of the id and
  -- the checker to a checker on the logger.
  impure function new_axi4_monitor (
    axi4_bus : axi4_bus_t;
    protocol_checker : axi4_protocol_checker_t := null_axi4_protocol_checker;
    shadow_memory : boolean := false;
    per_id_statistics : boolean := false;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_monitor_t;

  -- The id, logger, actor and checker of the monitor, and its handle for
  -- ``wait_until_idle`` and ``wait_for_time`` of ``sync_pkg``.
  -- ``wait_until_idle`` returns when Python has processed everything sampled
  -- so far.
  impure function get_id (monitor : axi4_monitor_t) return id_t;
  impure function get_logger (monitor : axi4_monitor_t) return logger_t;
  impure function get_actor (monitor : axi4_monitor_t) return actor_t;
  impure function get_checker (monitor : axi4_monitor_t) return checker_t;
  impure function as_sync (monitor : axi4_monitor_t) return sync_handle_t;

  -- The widths of the interface, for the ports of the entity
  function get_bus (monitor : axi4_monitor_t) return axi4_bus_t;

  -- The protocol checker the monitor instantiates, with its final id, or
  -- :vhdl:`axi4_protocol_checker_pkg.null_axi4_protocol_checker`
  function protocol_checker (monitor : axi4_monitor_t) return axi4_protocol_checker_t;

  -- One transaction the monitor reconstructed
  type axi4_transaction_t is record
    -- A write, or a read
    is_write        : boolean;
    -- AxLOCK was 1
    exclusive       : boolean;
    -- AWID or ARID
    id              : natural;
    -- AWADDR or ARADDR
    address         : std_ulogic_vector(63 downto 0);
    -- AxLEN: the burst has len + 1 beats
    len             : natural;
    -- AxSIZE: a beat has 2 ** size bytes
    size            : natural;
    -- AxBURST, one of the ``axi_burst_type_*`` constants of VUnit's ``axi_pkg``
    burst           : std_ulogic_vector(1 downto 0);
    -- AxCACHE, AxPROT, AxQOS and AxREGION
    cache           : natural;
    prot            : natural;
    qos             : natural;
    region          : natural;
    -- BRESP of a write. For a read the first RRESP that is neither OKAY nor
    -- EXOKAY, or else the RRESP of the last beat.
    resp            : std_ulogic_vector(1 downto 0);
    -- The times of the address handshake, the first and the last data
    -- handshake, and the B handshake (the last data handshake of a read)
    address_time    : time;
    first_data_time : time;
    last_data_time  : time;
    response_time   : time;
    -- The bytes of the byte lanes of every beat, in beat order and lowest
    -- lane first. For a full width burst from an aligned address, these are
    -- the bytes from ``address`` on.
    data            : integer_array_t;
    -- For each byte of ``data``, 1 when WSTRB wrote it; always 1 for a read.
    -- The receiver owns ``data`` and ``strobe`` and deallocates them.
    strobe          : integer_array_t;
  end record;

  -- A pending request, redeemed with the matching await procedure
  alias axi4_monitor_reference_t is msg_t;

  -- Non-blocking: pop the oldest transaction the monitor keeps, or the next
  -- one to complete
  procedure pop_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable reference : inout axi4_monitor_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`axi4_monitor_pkg.pop_axi4_transaction`
  procedure await_pop_axi4_transaction_reply (
    signal net : inout network_t;
    variable reference : inout axi4_monitor_reference_t;
    variable transaction : out axi4_transaction_t
  );

  -- Blocking: pop the oldest transaction the monitor keeps, or wait for the
  -- next one to complete
  procedure pop_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable transaction : out axi4_transaction_t
  );

  -- Read the transaction of an ``axi4_transaction_msg`` the monitor
  -- published, or of a pop reply
  procedure pop_axi4_transaction (msg : msg_t; variable transaction : out axi4_transaction_t);

  -- Non-blocking: the next write (``is_write``) or read to complete must have
  -- this address and data, the bytes of ``data`` leftmost first in the order
  -- of ``axi4_transaction_t.data``. Bytes a write does not strobe are not
  -- compared. ``id`` -1 and ``resp`` "--" match any. A difference, or an
  -- expected transaction that never came when the test ends, is a check
  -- failure (``AXI4_SCOREBOARD``) on the checker of the monitor, prefixed
  -- with msg.
  procedure check_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    is_write : boolean;
    address : std_ulogic_vector;
    data : std_ulogic_vector;
    id : integer := -1;
    resp : std_ulogic_vector(1 downto 0) := "--";
    msg : string := ""
  );

  -- What the monitor observed since it started or its statistics were
  -- cleared. Latencies are in clock cycles: writes from the AW to the B
  -- handshake, reads from the AR handshake to the last read data beat.
  type axi4_statistics_t is record
    -- Transactions completed
    write_transactions     : natural;
    read_transactions      : natural;
    -- Bytes moved: strobed bytes of writes, byte lanes of reads
    write_bytes            : natural;
    read_bytes             : natural;
    -- Bytes * 8 / the time observed, in Mbit/s
    write_bandwidth_mbps   : natural;
    read_bandwidth_mbps    : natural;
    -- The most transactions outstanding at once
    max_outstanding_writes : natural;
    max_outstanding_reads  : natural;
    -- Latencies, the mean rounded
    min_write_latency      : natural;
    max_write_latency      : natural;
    mean_write_latency     : natural;
    min_read_latency       : natural;
    max_read_latency       : natural;
    mean_read_latency      : natural;
    -- Cycles with VALID 1 and READY 0, per channel
    aw_stall_cycles        : natural;
    w_stall_cycles         : natural;
    b_stall_cycles         : natural;
    ar_stall_cycles        : natural;
    r_stall_cycles         : natural;
    -- SLVERR and DECERR responses, writes and reads
    error_responses        : natural;
    -- Clock cycles observed
    cycles                 : natural;
  end record;

  -- Non-blocking: request the statistics
  procedure get_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable reference : inout axi4_monitor_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`axi4_monitor_pkg.get_axi4_statistics`
  procedure await_get_axi4_statistics_reply (
    signal net : inout network_t;
    variable reference : inout axi4_monitor_reference_t;
    variable statistics : out axi4_statistics_t
  );

  -- Blocking: get the statistics
  procedure get_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable statistics : out axi4_statistics_t
  );

  -- Log a human-readable summary of the statistics on the logger of the
  -- monitor: counts, bandwidth, latency distributions with percentiles and
  -- histograms, outstanding transactions, burst histograms and the
  -- backpressure of each channel, and each ID with ``per_id_statistics``
  procedure log_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    log_level : log_level_t := info
  );

  -- Blocking: recover a monitor, for example after a reset of the design.
  -- Forgets the outstanding transactions, the kept and the expected ones.
  -- Pending pops are cancelled and must not be awaited. Statistics and the
  -- shadow memory are kept, statistics unless ``clear_statistics``.
  procedure reset (signal net : inout network_t; monitor : axi4_monitor_t; clear_statistics : boolean := false);

  -- The message types the procedures above send to the component, and the
  -- ``axi4_transaction_msg`` it publishes
  constant pop_axi4_transaction_msg : msg_type_t := new_msg_type("pop axi4 transaction");
  constant pop_axi4_transaction_reply_msg : msg_type_t := new_msg_type("pop axi4 transaction reply");
  constant axi4_transaction_msg : msg_type_t := new_msg_type("axi4 transaction");
  constant check_axi4_transaction_msg : msg_type_t := new_msg_type("check axi4 transaction");
  constant get_axi4_statistics_msg : msg_type_t := new_msg_type("get axi4 statistics");
  constant get_axi4_statistics_reply_msg : msg_type_t := new_msg_type("get axi4 statistics reply");
  constant log_axi4_statistics_msg : msg_type_t := new_msg_type("log axi4 statistics");
  constant reset_axi4_monitor_msg : msg_type_t := new_msg_type("reset axi4 monitor");
  constant reset_axi4_monitor_reply_msg : msg_type_t := new_msg_type("reset axi4 monitor reply");

  -- Private. The constructor arguments of the backend.
  impure function backend_arguments (monitor : axi4_monitor_t) return arg_t;

  -- Private. A message type no handler took, see
  -- :vhdl:`axi4_pkg.axi4_unexpected_msg_type`
  procedure unexpected_msg_type (msg_type : msg_type_t; monitor : axi4_monitor_t);
end package;

package body axi4_monitor_pkg is

  impure function new_axi4_monitor (
    axi4_bus : axi4_bus_t;
    protocol_checker : axi4_protocol_checker_t := null_axi4_protocol_checker;
    shadow_memory : boolean := false;
    per_id_statistics : boolean := false;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axi4_monitor_t is

    variable result : axi4_monitor_t := (
      p_bus => axi4_bus,
      p_protocol_checker => null_axi4_protocol_checker,
      p_shadow_memory => shadow_memory,
      p_per_id_statistics => per_id_statistics,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin

    if id = null_id then
      result.p_id := enumerate(get_id("axi4_monitor", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_axi4_actor(result.p_id);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_protocol_checker := get_valid_protocol_checker(protocol_checker, result.p_id, axi4_bus);
    return result;
  end;

  impure function get_id (monitor : axi4_monitor_t) return id_t is
  begin

    return monitor.p_id;
  end;

  impure function get_logger (monitor : axi4_monitor_t) return logger_t is
  begin

    return monitor.p_logger;
  end;

  impure function get_actor (monitor : axi4_monitor_t) return actor_t is
  begin

    return monitor.p_actor;
  end;

  impure function get_checker (monitor : axi4_monitor_t) return checker_t is
  begin

    return monitor.p_checker;
  end;

  impure function as_sync (monitor : axi4_monitor_t) return sync_handle_t is
  begin

    return monitor.p_actor;
  end;

  function get_bus (monitor : axi4_monitor_t) return axi4_bus_t is
  begin

    return monitor.p_bus;
  end;

  function protocol_checker (monitor : axi4_monitor_t) return axi4_protocol_checker_t is
  begin

    return monitor.p_protocol_checker;
  end;

  impure function backend_arguments (monitor : axi4_monitor_t) return arg_t is
  begin

    return arg_text(full_name(monitor.p_id))
           & backend_bus_arguments(monitor.p_bus)
           & kwarg("shadow_memory", monitor.p_shadow_memory)
           & kwarg("per_id_statistics", monitor.p_per_id_statistics)
           & kwarg("report_metavalues", monitor.p_protocol_checker = null_axi4_protocol_checker);
  end;

  procedure unexpected_msg_type (msg_type : msg_type_t; monitor : axi4_monitor_t) is
  begin

    axi4_unexpected_msg_type(msg_type, monitor.p_unexpected_msg_type_policy, monitor.p_checker);
  end;

  procedure pop_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable reference : inout axi4_monitor_reference_t
  ) is
  begin

    reference := new_msg(pop_axi4_transaction_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure pop_axi4_transaction (msg : msg_t; variable transaction : out axi4_transaction_t) is

    variable flags : natural;
    variable num_bytes : natural;
    variable value : natural;
  begin

    flags := pop(msg);
    transaction.is_write := flags mod 2 = 1;
    transaction.exclusive := flags / 2 mod 2 = 1;
    transaction.id := pop(msg);
    transaction.address(63 downto 32) := std_ulogic_vector(to_signed(integer'(pop(msg)), 32));
    transaction.address(31 downto 0) := std_ulogic_vector(to_signed(integer'(pop(msg)), 32));
    transaction.len := pop(msg);
    transaction.size := pop(msg);
    transaction.burst := std_ulogic_vector(to_unsigned(natural'(pop(msg)), 2));
    transaction.cache := pop(msg);
    transaction.prot := pop(msg);
    transaction.qos := pop(msg);
    transaction.region := pop(msg);
    transaction.resp := std_ulogic_vector(to_unsigned(natural'(pop(msg)), 2));
    transaction.address_time := pop(msg);
    transaction.first_data_time := pop(msg);
    transaction.last_data_time := pop(msg);
    transaction.response_time := pop(msg);
    num_bytes := pop(msg);
    transaction.data := new_1d(num_bytes, bit_width => 8, is_signed => false);
    transaction.strobe := new_1d(num_bytes, bit_width => 1, is_signed => false);
    for idx in 0 to num_bytes - 1 loop

      value := pop(msg);
      set(transaction.data, idx, value mod 256);
      set(transaction.strobe, idx, value / 256);
    end loop;

  end;

  procedure await_pop_axi4_transaction_reply (
    signal net : inout network_t;
    variable reference : inout axi4_monitor_reference_t;
    variable transaction : out axi4_transaction_t
  ) is

    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    pop_axi4_transaction(reply_msg, transaction);
    delete(reference);
    delete(reply_msg);
  end;

  procedure pop_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable transaction : out axi4_transaction_t
  ) is

    variable reference : axi4_monitor_reference_t;
  begin

    pop_axi4_transaction(net, monitor, reference);
    await_pop_axi4_transaction_reply(net, reference, transaction);
  end;

  procedure check_axi4_transaction (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    is_write : boolean;
    address : std_ulogic_vector;
    data : std_ulogic_vector;
    id : integer := -1;
    resp : std_ulogic_vector(1 downto 0) := "--";
    msg : string := ""
  ) is

    alias normalized : std_ulogic_vector(0 to data'length - 1) is data;
    constant wide_address : unsigned(63 downto 0) := resize(unsigned(to_x01(address)), 64);
    variable request_msg : msg_t := new_msg(check_axi4_transaction_msg);
    variable byte : natural;
  begin

    assert data'length mod 8 = 0
      report "AXI4 data of " & integer'image(data'length) & " bits is not a whole number of bytes"
      severity failure;
    push(request_msg, is_write);
    push(request_msg, to_integer(signed(wide_address(63 downto 32))));
    push(request_msg, to_integer(signed(wide_address(31 downto 0))));
    push(request_msg, id);
    if resp = "--" then
      push(request_msg, -1);
    else
      push(request_msg, to_integer(unsigned(to_x01(resp))));
    end if;
    push(request_msg, data'length / 8);
    for idx in 0 to data'length / 8 - 1 loop

      byte := 0;
      for bit_idx in 0 to 7 loop

        byte := 2 * byte;
        if to_x01(normalized(8 * idx + bit_idx)) = '1' then
          byte := byte + 1;
        end if;
      end loop;

      push(request_msg, byte);
    end loop;

    push_string(request_msg, msg);
    send(net, monitor.p_actor, request_msg);
  end;

  procedure get_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable reference : inout axi4_monitor_reference_t
  ) is
  begin

    reference := new_msg(get_axi4_statistics_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure await_get_axi4_statistics_reply (
    signal net : inout network_t;
    variable reference : inout axi4_monitor_reference_t;
    variable statistics : out axi4_statistics_t
  ) is

    variable reply_msg : msg_t;
  begin

    receive_reply(net, reference, reply_msg);
    statistics.write_transactions := pop(reply_msg);
    statistics.read_transactions := pop(reply_msg);
    statistics.write_bytes := pop(reply_msg);
    statistics.read_bytes := pop(reply_msg);
    statistics.write_bandwidth_mbps := pop(reply_msg);
    statistics.read_bandwidth_mbps := pop(reply_msg);
    statistics.max_outstanding_writes := pop(reply_msg);
    statistics.max_outstanding_reads := pop(reply_msg);
    statistics.min_write_latency := pop(reply_msg);
    statistics.max_write_latency := pop(reply_msg);
    statistics.mean_write_latency := pop(reply_msg);
    statistics.min_read_latency := pop(reply_msg);
    statistics.max_read_latency := pop(reply_msg);
    statistics.mean_read_latency := pop(reply_msg);
    statistics.aw_stall_cycles := pop(reply_msg);
    statistics.w_stall_cycles := pop(reply_msg);
    statistics.b_stall_cycles := pop(reply_msg);
    statistics.ar_stall_cycles := pop(reply_msg);
    statistics.r_stall_cycles := pop(reply_msg);
    statistics.error_responses := pop(reply_msg);
    statistics.cycles := pop(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    variable statistics : out axi4_statistics_t
  ) is

    variable reference : axi4_monitor_reference_t;
  begin

    get_axi4_statistics(net, monitor, reference);
    await_get_axi4_statistics_reply(net, reference, statistics);
  end;

  procedure log_axi4_statistics (
    signal net : inout network_t;
    monitor : axi4_monitor_t;
    log_level : log_level_t := info
  ) is

    variable request_msg : msg_t := new_msg(log_axi4_statistics_msg);
  begin

    push(request_msg, log_level_t'pos(log_level));
    send(net, monitor.p_actor, request_msg);
  end;

  procedure reset (signal net : inout network_t; monitor : axi4_monitor_t; clear_statistics : boolean := false) is

    variable request_msg : msg_t := new_msg(reset_axi4_monitor_msg);
    variable reply_msg : msg_t;
  begin

    push(request_msg, clear_statistics);
    request(net, monitor.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

end package body;
