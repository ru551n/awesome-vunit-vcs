-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library ieee;
use ieee.std_logic_1164.all;

-- The example DUT: a GMII register pipeline, the kind of stage that sits
-- between a MAC and a PHY to ease timing. Every signal is delayed by the same
-- number of clock cycles, so a frame leaves the pipeline exactly as it
-- entered it.
entity gmii_pipeline is
  generic (
    -- Number of register stages
    stages : positive := 2
  );
  port (
    clk : in std_ulogic;
    --# {{}}
    in_data : in std_ulogic_vector(7 downto 0);
    in_dv : in std_ulogic;
    in_er : in std_ulogic;
    --# {{}}
    out_data : out std_ulogic_vector(7 downto 0) := (others => '0');
    out_dv : out std_ulogic := '0';
    out_er : out std_ulogic := '0'
  );
end entity;

architecture a of gmii_pipeline is
  type data_vec_t is array (natural range <>) of std_ulogic_vector(7 downto 0);

  signal data_q : data_vec_t(1 to stages) := (others => (others => '0'));
  signal dv_q, er_q : std_ulogic_vector(1 to stages) := (others => '0');
begin
  out_data <= data_q(stages);
  out_dv <= dv_q(stages);
  out_er <= er_q(stages);

  main : process(clk)
  begin
    if rising_edge(clk) then
      data_q <= in_data & data_q(1 to stages - 1);
      dv_q <= in_dv & dv_q(1 to stages - 1);
      er_q <= in_er & er_q(1 to stages - 1);
    end if;
  end process;
end architecture;
