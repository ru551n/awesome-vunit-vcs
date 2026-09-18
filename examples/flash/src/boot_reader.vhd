-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The design under test of tb_flash_examples: a boot loader that copies a
-- flash image into its RAM.
--
-- When rst_n is released it reads the 4-byte length header at address 0 of a
-- QSPI flash with fast read (0x0B), most significant byte first, and then
-- that many bytes from address 0, header included, into ram. Its QSPI
-- controller is a qspi_master VC, so the example is about the testbench.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity boot_reader is
  generic (
    -- The largest image ram holds, in bytes
    ram_bytes : positive := 256);
  port (
    -- The boot starts when the reset is released
    rst_n : in  std_ulogic;
    -- The QSPI bus to the flash
    m2s : out qspi_m2s_t := qspi_m2s_init;
    s2m : in  qspi_s2m_t;
    -- The image, the byte of address 0 leftmost
    ram : out std_ulogic_vector(0 to 8 * ram_bytes - 1) := (others => '0');
    -- High when the image is in ram
    boot_done : out std_ulogic := '0'
  );
end entity;

architecture a of boot_reader is

  constant controller : qspi_master_t := new_qspi_master;

begin

  boot : process

    variable data : integer_array_t := null_integer_array;
    variable image_bytes : natural := 0;

  begin

    wait until rst_n = '1';

    qspi_flash_fast_read(net, controller, 0, 4, data);
    for idx in 0 to 3 loop

      image_bytes := 256 * image_bytes + get(data, idx);
    end loop;

    qspi_flash_fast_read(net, controller, 0, image_bytes, data);
    for idx in 0 to image_bytes - 1 loop

      ram(8 * idx to 8 * idx + 7) <= qspi_to_byte(get(data, idx));
    end loop;

    deallocate(data);

    boot_done <= '1';
    wait;
  end process;

  controller_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => controller
    )
    port map (
      m2s => m2s,
      s2m => s2m
    );

end architecture;
