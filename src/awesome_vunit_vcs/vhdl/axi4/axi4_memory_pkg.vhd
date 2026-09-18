-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The memory of the AXI4 read and write slaves: what VUnit's memory_pkg
-- offers, on a sparse store in Python (awesome_vunit_vcs.axi4.memory_model).
-- A 64-bit address space costs nothing until it is touched, and a permission
-- or a fill over any range is one operation.
--
-- A memory has a Python session of its own. The testbench reads and writes it
-- directly with the subprograms below (backdoor access, which ignores the
-- permissions), and any number of axi4_read_slave and axi4_write_slave
-- instances share it. The types permissions_t and endianness_arg_t are those
-- of VUnit's memory_pkg. Every subprogram taking an address as a natural also
-- takes it as a u_unsigned of up to 64 bits.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.memory_pkg.permissions_t;
  use vunit_lib.memory_pkg.endianness_t;
  use vunit_lib.memory_pkg.endianness_arg_t;
  use vunit_lib.string_ptr_pkg.all;
  use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.vc_python_pkg.all;

package axi4_memory_pkg is

  -- A memory, created with :vhdl:`axi4_memory_pkg.new_axi4_memory`
  type axi4_memory_t is record
    -- Private. Use the constructor and the accessors below.
    p_size_bytes         : natural;
    p_default_value      : natural;
    p_default_permission : permissions_t;
    p_endian             : endianness_t;
    p_id                 : id_t;
    p_logger             : logger_t;
    p_checker            : checker_t;
    p_session            : python_session_t;
    -- 1 once the Python backend exists
    p_state              : integer_vector_ptr_t;
  end record;

  -- A memory of ``size_bytes`` addresses (0 for the whole 64-bit space).
  -- A byte never written reads as ``default_value``. A byte never allocated
  -- or given a permission has ``default_permissions``: the default
  -- ``read_and_write`` makes a plain RAM, ``no_access`` makes the slaves fail
  -- on anything not allocated, like VUnit's memory. ``endian`` is the byte
  -- order of words when a call gives ``default_endian``.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:axi4_memory:<n>``, the logger to
  -- the logger of the id and the checker to a checker on the logger.
  -- Failures of the testbench's accesses, such as an address out of range or
  -- a byte written with another value than it expects, are check failures on
  -- the checker; failures of a slave's accesses go to the checker of the
  -- slave.
  impure function new_axi4_memory (
    size_bytes : natural := 0;
    default_value : natural range 0 to 255 := 0;
    default_permissions : permissions_t := vunit_lib.memory_pkg.read_and_write;
    endian : endianness_t := vunit_lib.memory_pkg.little_endian;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    checker : checker_t := null_checker
  ) return axi4_memory_t;

  -- The id, logger and checker of the memory
  impure function get_id (memory : axi4_memory_t) return id_t;
  impure function get_logger (memory : axi4_memory_t) return logger_t;
  impure function get_checker (memory : axi4_memory_t) return checker_t;

  -- Forget the content, the permissions, the expected data and the buffers
  procedure clear (memory : axi4_memory_t);

  -- Where the next buffer :vhdl:`axi4_memory_pkg.allocate` places starts:
  -- the end of the last one
  impure function num_bytes (memory : axi4_memory_t) return natural;

  -- An allocated region of a memory
  type axi4_buffer_t is record
    -- Private. Use the accessors below.
    p_memory    : axi4_memory_t;
    p_name      : string_ptr_t;
    p_address   : u_unsigned(63 downto 0);
    p_num_bytes : natural;
  end record;

  -- Allocate a buffer after the last one, aligned, and give its bytes
  -- ``permissions``, like VUnit's allocate
  impure function allocate (
    memory : axi4_memory_t;
    num_bytes : natural;
    name : string := "";
    alignment : positive := 1;
    permissions : permissions_t := vunit_lib.memory_pkg.read_and_write
  ) return axi4_buffer_t;

  -- Allocate a buffer at ``address``; it does not move where the next buffer
  -- of the function above starts
  impure function allocate (
    memory : axi4_memory_t;
    address : u_unsigned;
    num_bytes : natural;
    name : string := "";
    permissions : permissions_t := vunit_lib.memory_pkg.read_and_write
  ) return axi4_buffer_t;

  -- The name, size, first and last address of a buffer. ``base_address`` and
  -- ``last_address`` fail for a buffer beyond the range of natural;
  -- ``wide_base_address`` is the first address of any buffer.
  impure function name (buf : axi4_buffer_t) return string;
  impure function num_bytes (buf : axi4_buffer_t) return natural;
  impure function base_address (buf : axi4_buffer_t) return natural;
  impure function last_address (buf : axi4_buffer_t) return natural;
  impure function wide_base_address (buf : axi4_buffer_t) return u_unsigned;

  -- The address and its buffer, as VUnit words it: ``address 5 at offset 3
  -- within buffer 'name' at range (2 to 11)``
  impure function describe_address (memory : axi4_memory_t; address : natural) return string;
  impure function describe_address (memory : axi4_memory_t; address : u_unsigned) return string;

  -- Backdoor access: the testbench reads and writes without permission
  -- checks. A byte with an expected value written with another one is a
  -- check failure and is not written, as in VUnit.
  procedure write_byte (memory : axi4_memory_t; address : natural; byte : natural range 0 to 255);
  procedure write_byte (memory : axi4_memory_t; address : u_unsigned; byte : natural range 0 to 255);
  impure function read_byte (memory : axi4_memory_t; address : natural) return natural;
  impure function read_byte (memory : axi4_memory_t; address : u_unsigned) return natural;

  -- A word of whole bytes, in the byte order ``endian``
  procedure write_word (
    memory : axi4_memory_t;
    address : natural;
    word : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  procedure write_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    word : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  impure function read_word (
    memory : axi4_memory_t;
    address : natural;
    bytes_per_word : positive;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) return std_ulogic_vector;
  impure function read_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    bytes_per_word : positive;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) return std_ulogic_vector;

  -- An integer of 1 to 4 bytes, two's complement
  procedure write_integer (
    memory : axi4_memory_t;
    address : natural;
    word : integer;
    bytes_per_word : natural range 1 to 4 := 4;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );

  -- Bulk content: the values of ``data`` as bytes from ``address`` on,
  -- ``num_bytes`` bytes as a new array of 8-bit values, and ``num_bytes`` bytes
  -- of ``value``, which costs the same for any size
  procedure write_bytes (memory : axi4_memory_t; address : natural; data : integer_array_t);
  procedure write_bytes (memory : axi4_memory_t; address : u_unsigned; data : integer_array_t);
  impure function read_bytes (memory : axi4_memory_t; address : natural; num_bytes : natural) return integer_array_t;
  impure function read_bytes (memory : axi4_memory_t; address : u_unsigned; num_bytes : natural) return integer_array_t;
  procedure fill (memory : axi4_memory_t; address : natural; num_bytes : natural; value : natural range 0 to 255);
  procedure fill (memory : axi4_memory_t; address : u_unsigned; num_bytes : natural; value : natural range 0 to 255);

  -- Load an image file of the flash family's formats (Intel HEX, S-record,
  -- raw binary, JSON; ``image_format`` "" infers it from the extension).
  -- Sparse formats stay sparse. ``base`` is the load address of a raw binary
  -- and an offset for the others.
  procedure load_image (memory : axi4_memory_t; file_name : string; image_format : string := ""; base : natural := 0);
  procedure load_image (memory : axi4_memory_t; file_name : string; image_format : string; base : u_unsigned);

  -- The permissions of a byte, and of ``num_bytes`` bytes from ``address``
  impure function get_permissions (memory : axi4_memory_t; address : natural) return permissions_t;
  procedure set_permissions (memory : axi4_memory_t; address : natural; permissions : permissions_t);
  procedure set_permissions (
    memory : axi4_memory_t;
    address : natural;
    num_bytes : natural;
    permissions : permissions_t
  );
  procedure set_permissions (
    memory : axi4_memory_t;
    address : u_unsigned;
    num_bytes : natural;
    permissions : permissions_t
  );

  -- Expected data: what a slave must write. A write of another value is a
  -- check failure on the checker of the slave; the check procedures below
  -- report each byte whose expected value was never written.
  impure function has_expected_byte (memory : axi4_memory_t; address : natural) return boolean;
  procedure clear_expected_byte (memory : axi4_memory_t; address : natural);
  procedure set_expected_byte (memory : axi4_memory_t; address : natural; expected : natural range 0 to 255);
  procedure set_expected_word (
    memory : axi4_memory_t;
    address : natural;
    expected : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  procedure set_expected_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    expected : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  procedure set_expected_integer (
    memory : axi4_memory_t;
    address : natural;
    expected : integer;
    bytes_per_word : natural range 1 to 4 := 4;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  impure function get_expected_byte (memory : axi4_memory_t; address : natural) return natural;

  -- Check, or tell, that every byte with an expected value holds it: in a
  -- range, a buffer, or the whole memory
  procedure check_expected_was_written (memory : axi4_memory_t; address : natural; num_bytes : natural);
  procedure check_expected_was_written (memory : axi4_memory_t; address : u_unsigned; num_bytes : natural);
  procedure check_expected_was_written (buf : axi4_buffer_t);
  procedure check_expected_was_written (memory : axi4_memory_t);
  impure function expected_was_written (memory : axi4_memory_t; address : natural; num_bytes : natural) return boolean;
  impure function expected_was_written (buf : axi4_buffer_t) return boolean;
  impure function expected_was_written (memory : axi4_memory_t) return boolean;

  -- VUnit's memory_utils_pkg for integer arrays: write an integer_array_t,
  -- or set it as expected data, each row ``stride_in_bytes`` bytes from the
  -- previous one (0: the row size). The functions allocate a buffer for it
  -- first.
  impure function allocate_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    permissions : permissions_t := vunit_lib.memory_pkg.read_only
  ) return axi4_buffer_t;
  procedure write_integer_array (
    memory : axi4_memory_t;
    base_address : natural;
    integer_array : integer_array_t;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  impure function write_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian;
    permissions : permissions_t := vunit_lib.memory_pkg.read_only
  ) return axi4_buffer_t;
  procedure set_expected_integer_array (
    memory : axi4_memory_t;
    base_address : natural;
    integer_array : integer_array_t;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  );
  impure function set_expected_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian;
    permissions : permissions_t := vunit_lib.memory_pkg.write_only
  ) return axi4_buffer_t;

  -- Private. The Python session of the memory, its backend created
  impure function memory_session (memory : axi4_memory_t) return python_session_t;

  -- Private. Log the reports of the memory when ``num_reports`` is not 0
  procedure log_memory_reports (memory : axi4_memory_t; num_reports : natural);
end package;

package body axi4_memory_pkg is

  impure function new_axi4_memory (
    size_bytes : natural := 0;
    default_value : natural range 0 to 255 := 0;
    default_permissions : permissions_t := vunit_lib.memory_pkg.read_and_write;
    endian : endianness_t := vunit_lib.memory_pkg.little_endian;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    checker : checker_t := null_checker
  ) return axi4_memory_t is

    variable result : axi4_memory_t;
  begin

    result.p_size_bytes := size_bytes;
    result.p_default_value := default_value;
    result.p_default_permission := default_permissions;
    result.p_endian := endian;
    result.p_id := id;
    if id = null_id then
      result.p_id := enumerate(get_id("axi4_memory", parent => get_id("awesome_vunit_vcs")));
    end if;
    result.p_logger := logger;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    result.p_checker := checker;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_session := new_vc_session(result.p_id, result.p_logger);
    result.p_state := new_integer_vector_ptr(1, value => 0);
    return result;
  end;

  impure function get_id (memory : axi4_memory_t) return id_t is
  begin

    return memory.p_id;
  end;

  impure function get_logger (memory : axi4_memory_t) return logger_t is
  begin

    return memory.p_logger;
  end;

  impure function get_checker (memory : axi4_memory_t) return checker_t is
  begin

    return memory.p_checker;
  end;

  impure function memory_session (memory : axi4_memory_t) return python_session_t is
  begin

    -- The backend is created on first use, since Python must not run while
    -- the design elaborates
    if get(memory.p_state, 0) = 0 then
      set(memory.p_state, 0, 1);
      create_backend(
        memory.p_session,
        "awesome_vunit_vcs.axi4.vunit_backend",
        "Axi4MemoryBackend",
        arg_text(full_name(memory.p_id))
        & kwarg("size_bytes", memory.p_size_bytes)
        & kwarg("default_value", memory.p_default_value)
        & kwarg("default_permission", permissions_t'pos(memory.p_default_permission))
        & kwarg("endian", endianness_t'pos(memory.p_endian))
      );
      log_memory_reports(memory, backend_call_integer(memory.p_session, "num_reports"));
    end if;
    return memory.p_session;
  end;

  procedure log_memory_reports (memory : axi4_memory_t; num_reports : natural) is
  begin

    if num_reports > 0 then
      log_reports(memory.p_session, memory.p_logger, memory.p_checker);
    end if;
  end;

  -- Call a backdoor method that returns the number of reports, and log them
  procedure memory_call (memory : axi4_memory_t; method : string; args : arg_t) is
  begin

    log_memory_reports(memory, backend_call_integer(memory_session(memory), method, args));
  end;

  -- Log the reports of a call that returned something else
  procedure log_waiting (memory : axi4_memory_t) is
  begin

    log_memory_reports(memory, backend_call_integer(memory_session(memory), "num_reports"));
  end;

  function wide (address : natural) return u_unsigned is
  begin

    return to_unsigned(address, 64);
  end;

  impure function endian_arg (endian : endianness_arg_t) return arg_t is
  begin

    return arg(endianness_arg_t'pos(endian));
  end;

  -- The bytes of a word, least significant first
  function word_bytes (word : std_ulogic_vector) return integer_vector is

    alias normalized : std_ulogic_vector(word'length - 1 downto 0) is word;
    variable result : integer_vector(0 to word'length / 8 - 1);
  begin

    assert word'length mod 8 = 0
      report "A word of " & integer'image(word'length) & " bits is not a whole number of bytes"
      severity failure;
    for idx in result'range loop

      result(idx) := to_integer(to_01(unsigned(normalized(8 * idx + 7 downto 8 * idx))));
    end loop;

    return result;
  end;

  procedure clear (memory : axi4_memory_t) is
  begin

    memory_call(memory, "clear", null_arg);
  end;

  impure function num_bytes (memory : axi4_memory_t) return natural is
  begin

    return backend_call_integer(memory_session(memory), "num_bytes");
  end;

  impure function new_buffer (
    memory : axi4_memory_t;
    address : integer;
    wide_address : u_unsigned;
    num_bytes : natural;
    name : string
  ) return axi4_buffer_t is
  begin

    log_waiting(memory);
    if address < 0 then
      return (p_memory => memory, p_name => new_string_ptr(name), p_address => (others => '0'), p_num_bytes => 0);
    end if;
    return (
      p_memory => memory,
      p_name => new_string_ptr(name),
      p_address => resize(wide_address, 64),
      p_num_bytes => num_bytes
    );
  end;

  impure function allocate (
    memory : axi4_memory_t;
    num_bytes : natural;
    name : string := "";
    alignment : positive := 1;
    permissions : permissions_t := vunit_lib.memory_pkg.read_and_write
  ) return axi4_buffer_t is

    constant address : integer := backend_call_integer(
      memory_session(memory),
      "allocate",
      arg(num_bytes) & arg_text(name) & arg(alignment) & arg(permissions_t'pos(permissions))
    );
  begin

    return new_buffer(memory, address, wide(maximum(address, 0)), num_bytes, name);
  end;

  impure function allocate (
    memory : axi4_memory_t;
    address : u_unsigned;
    num_bytes : natural;
    name : string := "";
    permissions : permissions_t := vunit_lib.memory_pkg.read_and_write
  ) return axi4_buffer_t is

    constant result : integer := backend_call_integer(
      memory_session(memory),
      "allocate",
      arg(num_bytes)
      & arg_text(name)
      & arg(1)
      & arg(permissions_t'pos(permissions))
      & kwarg_unsigned("address", address)
      & kwarg("wide", true)
    );
  begin

    return new_buffer(memory, result, address, num_bytes, name);
  end;

  impure function name (buf : axi4_buffer_t) return string is
  begin

    return to_string(buf.p_name);
  end;

  impure function num_bytes (buf : axi4_buffer_t) return natural is
  begin

    return buf.p_num_bytes;
  end;

  impure function base_address (buf : axi4_buffer_t) return natural is
  begin

    return to_integer(buf.p_address);
  end;

  impure function last_address (buf : axi4_buffer_t) return natural is
  begin

    return base_address(buf) + buf.p_num_bytes - 1;
  end;

  impure function wide_base_address (buf : axi4_buffer_t) return u_unsigned is
  begin

    return buf.p_address;
  end;

  impure function describe_address (memory : axi4_memory_t; address : u_unsigned) return string is
  begin

    return backend_call_string(memory_session(memory), "describe_address", arg_unsigned(address));
  end;

  impure function describe_address (memory : axi4_memory_t; address : natural) return string is
  begin

    return describe_address(memory, wide(address));
  end;

  procedure write_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    word : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    memory_call(memory, "write_word", arg_unsigned(address) & arg(word_bytes(word)) & endian_arg(endian));
  end;

  procedure write_word (
    memory : axi4_memory_t;
    address : natural;
    word : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    write_word(memory, wide(address), word, endian);
  end;

  impure function read_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    bytes_per_word : positive;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) return std_ulogic_vector is

    variable values : integer_array_t := backend_call_integer_array(
      memory_session(memory),
      "read_word",
      arg_unsigned(address) & arg(bytes_per_word) & endian_arg(endian)
    );
    variable result : std_ulogic_vector(8 * bytes_per_word - 1 downto 0);
  begin

    log_waiting(memory);
    for idx in 0 to bytes_per_word - 1 loop

      result(8 * idx + 7 downto 8 * idx) := std_ulogic_vector(to_unsigned(get(values, idx), 8));
    end loop;

    deallocate(values);
    return result;
  end;

  impure function read_word (
    memory : axi4_memory_t;
    address : natural;
    bytes_per_word : positive;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) return std_ulogic_vector is
  begin

    return read_word(memory, wide(address), bytes_per_word, endian);
  end;

  procedure write_byte (memory : axi4_memory_t; address : u_unsigned; byte : natural range 0 to 255) is
  begin

    write_word(memory, address, std_ulogic_vector(to_unsigned(byte, 8)));
  end;

  procedure write_byte (memory : axi4_memory_t; address : natural; byte : natural range 0 to 255) is
  begin

    write_byte(memory, wide(address), byte);
  end;

  impure function read_byte (memory : axi4_memory_t; address : u_unsigned) return natural is
  begin

    return to_integer(unsigned(read_word(memory, address, 1)));
  end;

  impure function read_byte (memory : axi4_memory_t; address : natural) return natural is
  begin

    return read_byte(memory, wide(address));
  end;

  procedure write_integer (
    memory : axi4_memory_t;
    address : natural;
    word : integer;
    bytes_per_word : natural range 1 to 4 := 4;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    memory_call(memory, "write_integer", arg(address) & arg(word) & arg(bytes_per_word) & endian_arg(endian));
  end;

  procedure write_bytes (memory : axi4_memory_t; address : u_unsigned; data : integer_array_t) is
  begin

    memory_call(memory, "write_bytes", arg_unsigned(address) & arg(data));
  end;

  procedure write_bytes (memory : axi4_memory_t; address : natural; data : integer_array_t) is
  begin

    write_bytes(memory, wide(address), data);
  end;

  impure function read_bytes (
    memory : axi4_memory_t;
    address : u_unsigned;
    num_bytes : natural
  ) return integer_array_t is

    constant result : integer_array_t :=
      backend_call_integer_array(memory_session(memory), "read_bytes", arg_unsigned(address) & arg(num_bytes));
  begin

    log_waiting(memory);
    return result;
  end;

  impure function read_bytes (memory : axi4_memory_t; address : natural; num_bytes : natural) return integer_array_t is
  begin

    return read_bytes(memory, wide(address), num_bytes);
  end;

  procedure fill (memory : axi4_memory_t; address : u_unsigned; num_bytes : natural; value : natural range 0 to 255) is
  begin

    memory_call(memory, "fill", arg_unsigned(address) & arg(num_bytes) & arg(value));
  end;

  procedure fill (memory : axi4_memory_t; address : natural; num_bytes : natural; value : natural range 0 to 255) is
  begin

    fill(memory, wide(address), num_bytes, value);
  end;

  procedure load_image (memory : axi4_memory_t; file_name : string; image_format : string; base : u_unsigned) is
  begin

    memory_call(memory, "load_image", arg_text(file_name) & arg_text(image_format) & arg_unsigned(base));
  end;

  procedure load_image (memory : axi4_memory_t; file_name : string; image_format : string := ""; base : natural := 0) is
  begin

    load_image(memory, file_name, image_format, wide(base));
  end;

  impure function get_permissions (memory : axi4_memory_t; address : natural) return permissions_t is
  begin

    return permissions_t'val(backend_call_integer(memory_session(memory), "get_permissions", arg(address)));
  end;

  procedure set_permissions (
    memory : axi4_memory_t;
    address : u_unsigned;
    num_bytes : natural;
    permissions : permissions_t
  ) is
  begin

    memory_call(
      memory,
      "set_permissions",
      arg_unsigned(address) & arg(num_bytes) & arg(permissions_t'pos(permissions))
    );
  end;

  procedure set_permissions (
    memory : axi4_memory_t;
    address : natural;
    num_bytes : natural;
    permissions : permissions_t
  ) is
  begin

    set_permissions(memory, wide(address), num_bytes, permissions);
  end;

  procedure set_permissions (memory : axi4_memory_t; address : natural; permissions : permissions_t) is
  begin

    set_permissions(memory, address, 1, permissions);
  end;

  impure function has_expected_byte (memory : axi4_memory_t; address : natural) return boolean is
  begin

    return backend_call_boolean(memory_session(memory), "has_expected", arg(address));
  end;

  procedure clear_expected_byte (memory : axi4_memory_t; address : natural) is
  begin

    memory_call(memory, "clear_expected", arg(address) & arg(1));
  end;

  procedure set_expected_word (
    memory : axi4_memory_t;
    address : u_unsigned;
    expected : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    memory_call(memory, "set_expected_word", arg_unsigned(address) & arg(word_bytes(expected)) & endian_arg(endian));
  end;

  procedure set_expected_word (
    memory : axi4_memory_t;
    address : natural;
    expected : std_ulogic_vector;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    set_expected_word(memory, wide(address), expected, endian);
  end;

  procedure set_expected_byte (memory : axi4_memory_t; address : natural; expected : natural range 0 to 255) is
  begin

    set_expected_word(memory, address, std_ulogic_vector(to_unsigned(expected, 8)));
  end;

  procedure set_expected_integer (
    memory : axi4_memory_t;
    address : natural;
    expected : integer;
    bytes_per_word : natural range 1 to 4 := 4;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    memory_call(
      memory,
      "set_expected_integer",
      arg(address) & arg(expected) & arg(bytes_per_word) & endian_arg(endian)
    );
  end;

  impure function get_expected_byte (memory : axi4_memory_t; address : natural) return natural is
  begin

    return backend_call_integer(memory_session(memory), "get_expected", arg(address));
  end;

  procedure check_expected_was_written (memory : axi4_memory_t; address : u_unsigned; num_bytes : natural) is
  begin

    memory_call(memory, "check_expected_was_written", arg_unsigned(address) & arg(num_bytes));
  end;

  procedure check_expected_was_written (memory : axi4_memory_t; address : natural; num_bytes : natural) is
  begin

    check_expected_was_written(memory, wide(address), num_bytes);
  end;

  procedure check_expected_was_written (buf : axi4_buffer_t) is
  begin

    check_expected_was_written(buf.p_memory, buf.p_address, buf.p_num_bytes);
  end;

  procedure check_expected_was_written (memory : axi4_memory_t) is
  begin

    memory_call(memory, "check_expected_was_written", null_arg);
  end;

  impure function expected_was_written (
    memory : axi4_memory_t;
    address : natural;
    num_bytes : natural
  ) return boolean is
  begin

    return backend_call_boolean(memory_session(memory), "expected_was_written", arg(address) & arg(num_bytes));
  end;

  impure function expected_was_written (buf : axi4_buffer_t) return boolean is
  begin

    return backend_call_boolean(
      memory_session(buf.p_memory),
      "expected_was_written",
      arg_unsigned(buf.p_address) & arg(buf.p_num_bytes)
    );
  end;

  impure function expected_was_written (memory : axi4_memory_t) return boolean is
  begin

    return backend_call_boolean(memory_session(memory), "expected_was_written");
  end;

  impure function stride (integer_array : integer_array_t; stride_in_bytes : natural) return natural is
  begin

    if stride_in_bytes = 0 then
      return integer_array.width * bytes_per_word(integer_array);
    end if;
    return stride_in_bytes;
  end;

  impure function allocate_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    permissions : permissions_t := vunit_lib.memory_pkg.read_only
  ) return axi4_buffer_t is
  begin

    return allocate(
      memory,
      integer_array.depth * integer_array.height * stride(integer_array, stride_in_bytes),
      name,
      alignment,
      permissions
    );
  end;

  procedure write_array (
    memory : axi4_memory_t;
    base_address : natural;
    integer_array : integer_array_t;
    stride_in_bytes : natural;
    endian : endianness_arg_t;
    expected : boolean
  ) is
  begin

    memory_call(
      memory,
      "write_integer_array",
      arg(base_address)
      & arg(integer_array)
      & arg(bytes_per_word(integer_array))
      & arg(stride_in_bytes)
      & endian_arg(endian)
      & arg(expected)
    );
  end;

  procedure write_integer_array (
    memory : axi4_memory_t;
    base_address : natural;
    integer_array : integer_array_t;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    write_array(memory, base_address, integer_array, stride_in_bytes, endian, false);
  end;

  impure function write_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian;
    permissions : permissions_t := vunit_lib.memory_pkg.read_only
  ) return axi4_buffer_t is

    constant buf : axi4_buffer_t :=
      allocate_integer_array(memory, integer_array, name, alignment, stride_in_bytes, permissions);
  begin

    write_array(memory, base_address(buf), integer_array, stride_in_bytes, endian, false);
    return buf;
  end;

  procedure set_expected_integer_array (
    memory : axi4_memory_t;
    base_address : natural;
    integer_array : integer_array_t;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian
  ) is
  begin

    write_array(memory, base_address, integer_array, stride_in_bytes, endian, true);
  end;

  impure function set_expected_integer_array (
    memory : axi4_memory_t;
    integer_array : integer_array_t;
    name : string := "";
    alignment : positive := 1;
    stride_in_bytes : natural := 0;
    endian : endianness_arg_t := vunit_lib.memory_pkg.default_endian;
    permissions : permissions_t := vunit_lib.memory_pkg.write_only
  ) return axi4_buffer_t is

    constant buf : axi4_buffer_t :=
      allocate_integer_array(memory, integer_array, name, alignment, stride_in_bytes, permissions);
  begin

    write_array(memory, base_address(buf), integer_array, stride_in_bytes, endian, true);
    return buf;
  end;

end package body;
