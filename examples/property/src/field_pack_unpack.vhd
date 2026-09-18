-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Packs {opcode, flag, address, value} into 16 bits and unpacks them again.

library ieee;
  use ieee.std_logic_1164.all;

entity field_packer is
  port (
    opcode : in  std_ulogic_vector(3 downto 0);
    flag : in  std_ulogic;
    address : in  std_ulogic_vector(5 downto 0);
    value : in  std_ulogic_vector(4 downto 0);
    packed : out std_ulogic_vector(15 downto 0)
  );
end entity;

architecture a of field_packer is

begin

  packed <= opcode & flag & address & value;
end architecture;

library ieee;
  use ieee.std_logic_1164.all;

entity field_unpacker is
  generic (
    -- A planted bug: the address MSB and the value LSB are swapped
    inject_bug : boolean := false);
  port (
    packed : in  std_ulogic_vector(15 downto 0);
    opcode : out std_ulogic_vector(3 downto 0);
    flag : out std_ulogic;
    address : out std_ulogic_vector(5 downto 0);
    value : out std_ulogic_vector(4 downto 0)
  );
end entity;

architecture a of field_unpacker is

begin

  opcode <= packed(15 downto 12);
  flag <= packed(11);
  address <= packed(0) & packed(9 downto 5) when inject_bug else
             packed(10 downto 5);
  value <= packed(4 downto 1) & packed(10) when inject_bug else
           packed(4 downto 0);
end architecture;
