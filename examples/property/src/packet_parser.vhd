-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A byte-stream packet parser: magic, length, flags (reserved bits 7 downto 1
-- must be 0), "length" payload bytes and a checksum (the sum mod 256 of every
-- earlier byte). One valid byte is consumed per cycle; accepted or rejected
-- pulses for one cycle once the checksum byte is seen. inject_bug skips the
-- reserved-bits check.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity packet_parser is
  generic (
    inject_bug : boolean := false
  );
  port (
    clk, rst, valid : in std_ulogic;
    data : in std_ulogic_vector(7 downto 0);
    accepted, rejected : out std_ulogic
  );
end entity;

architecture a of packet_parser is
  constant magic : std_ulogic_vector(7 downto 0) := x"A5";
  type state_t is (magic_byte, length_byte, flags_byte, payload, checksum_byte);
  signal state : state_t := magic_byte;
  signal running_sum : unsigned(7 downto 0) := (others => '0');
  signal payload_left : natural range 0 to 255 := 0;
  signal magic_ok, reserved_ok : boolean := true;
begin
  main : process(clk)
  begin
    if rising_edge(clk) then
      accepted <= '0';
      rejected <= '0';
      if rst = '1' then
        state <= magic_byte;
        running_sum <= (others => '0');
      elsif valid = '1' then
        running_sum <= running_sum + unsigned(data);
        case state is
          when magic_byte =>
            magic_ok <= data = magic;
            state <= length_byte;
          when length_byte =>
            payload_left <= to_integer(unsigned(data));
            state <= flags_byte;
          when flags_byte =>
            reserved_ok <= inject_bug or data(7 downto 1) = "0000000";
            if payload_left = 0 then
              state <= checksum_byte;
            else
              state <= payload;
            end if;
          when payload =>
            if payload_left <= 1 then
              state <= checksum_byte;
            else
              payload_left <= payload_left - 1;
            end if;
          when checksum_byte =>
            if magic_ok and reserved_ok and unsigned(data) = running_sum then
              accepted <= '1';
            else
              rejected <= '1';
            end if;
            state <= magic_byte;
        end case;
      end if;
    end if;
  end process;
end architecture;
