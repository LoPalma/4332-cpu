-- --------- --
-- RAM block --
-- --------- --
--
-- This module defines a block of RAM.
-- It's written to be inferred by the Basys 3 board.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram is
  port (
    clk          : in  std_logic;

    address      : in  std_logic_vector(11 downto 0);
    data_in      : in  std_logic_vector(15 downto 0);
    data_out     : out std_logic_vector(15 downto 0);

    write_mask   : in  std_logic_vector(1 downto 0);
    write_enable : in  std_logic
  );
end entity;

architecture rtl of ram is

  type ram_type is array (0 to 2047) of std_logic_vector(15 downto 0);
  signal mem : ram_type := (others => (others => '0'));

  signal addr : integer range 0 to 2047;
  signal dout : std_logic_vector(15 downto 0);

begin

  -- word aligned address (ignore byte address bit)
  addr <= to_integer(unsigned(address(11 downto 1)));

  process(clk)
  begin
    if rising_edge(clk) then

      -- WRITE (byte enable style)
      if write_enable = '1' then

        if write_mask(0) = '0' then
          mem(addr)(7 downto 0) <= data_in(7 downto 0);
        end if;

        if write_mask(1) = '0' then
          mem(addr)(15 downto 8) <= data_in(15 downto 8);
        end if;

      end if;

      -- SYNCHRONOUS READ (BRAM-friendly style)
      dout <= mem(addr);

    end if;
  end process;

  data_out <= dout;

end architecture;
