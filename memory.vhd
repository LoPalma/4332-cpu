library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity memory is
  port (
    clk          : in  std_logic;
    address      : in  std_logic_vector(11 downto 0);
    data_in      : in  std_logic_vector(15 downto 0);
    data_out     : out std_logic_vector(15 downto 0);
    write_mask   : in  std_logic_vector(1 downto 0);
    write_enable : in  std_logic
  );
end entity;

architecture rtl of memory is

  type mem_array is array (0 to 2047) of std_logic_vector(15 downto 0);
  signal mem : mem_array := (others => (others => '0'));

  signal addr_word : integer range 0 to 2047;

begin

  addr_word <= to_integer(unsigned(address(11 downto 1)));

  process(clk)
  begin
    if rising_edge(clk) then

      -- write path
      if write_enable = '1' then

        if write_mask(0) = '0' then
          mem(addr_word)(7 downto 0) <= data_in(7 downto 0);
        end if;

        if write_mask(1) = '0' then
          mem(addr_word)(15 downto 8) <= data_in(15 downto 8);
        end if;

      end if;

      -- read path (synchronous like your Verilog)
      data_out <= mem(addr_word);

    end if;
  end process;

end architecture;
