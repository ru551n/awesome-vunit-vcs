-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The shortest realistic flash test: a DUT boots from an image loaded into a
-- flash with default settings. The test checks that the DUT read the image
-- and that the boot wrote nothing to the flash. flash_boot_image.hex is 64
-- bytes, a length header followed by a payload; boot_reader.vhd is the DUT.

-- docs-start: boot-example
library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_flash_boot_example is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_flash_boot_example is
  constant boot_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker);
  constant image_bytes : positive := 64;
  signal m2s : qspi_m2s_t := qspi_m2s_init;
  signal s2m : qspi_s2m_t := qspi_s2m_init;
  signal rst_n, boot_done : std_ulogic := '0';
  signal ram : std_ulogic_vector(0 to 8 * 256 - 1);
begin
  main : process
    variable regions : integer_array_t;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_dut_boots_from_the_flash_image") then
        flash_load_image(net, boot_flash, tb_path(runner_cfg) & "flash_boot_image.hex");
        rst_n <= '1';
        wait until boot_done = '1';
        -- What the DUT read is the image, and it wrote nothing
        flash_check_content(net, boot_flash, 0, ram(0 to 8 * image_bytes - 1));
        flash_get_written_regions(net, boot_flash, regions);
        check_equal(length(regions), 0, "the written regions, [address, length] pairs");
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;
  test_runner_watchdog(runner, 10 ms);

  flash_inst : entity awesome_vunit_vcs.flash
    generic map (flash => boot_flash)
    port map (m2s => m2s, s2m => s2m);

  boot_reader_inst : entity work.boot_reader
    port map (rst_n => rst_n, m2s => m2s, s2m => s2m, ram => ram, boot_done => boot_done);
end architecture;
-- docs-end: boot-example
