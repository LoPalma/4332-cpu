-- ----------- --
-- peripherals --
-- ----------- --
--
-- This module consists of an API to interface with
-- the FPGA board's buttons, LEDs and switches.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity peripherals is
  port (
    clk, raw_clk, reset : in std_logic;
    enable, write_enable : in std_logic;
    address : in std_logic_vector(7 downto 0);
    data_in : in std_logic_vector(15 downto 0);
    data_out : out std_logic_vector(15 downto 0);
    -- Basys 3 Physical I/O
    btn : in std_logic_vector(4 downto 0);
    sw  : in std_logic_vector(15 downto 0);
    led : out std_logic_vector(15 downto 0);
    seg : out std_logic_vector(6 downto 0);
    an  : out std_logic_vector(3 downto 0);
    -- Logical I/O
    ioport_0, ioport_1, ioport_2, ioport_3 : out std_logic;
    button_0 : in std_logic;
    spi_clk, spi_mosi : out std_logic;
    spi_miso : in std_logic
  );
end entity;

architecture rtl of peripherals is
  signal ioport_reg : std_logic_vector(3 downto 0) := (others => '0');
  signal spi_start : std_logic := '0';
  signal spi_data_tx, spi_data_rx : std_logic_vector(7 downto 0);
  signal spi_busy : std_logic;
begin
  -- SPI instantiation
  spi_inst : entity work.spi
    port map (
      raw_clk => raw_clk, start => spi_start,
      data_tx => spi_data_tx, data_rx => spi_data_rx,
      busy => spi_busy, sclk => spi_clk, mosi => spi_mosi, miso => spi_miso
    );

  ioport_0 <= ioport_reg(0); ioport_1 <= ioport_reg(1);
  ioport_2 <= ioport_reg(2); ioport_3 <= ioport_reg(3);

  process(clk)
  begin
    if rising_edge(clk) then
      spi_start <= '0'; -- Pulse logic
      if reset = '1' then
        ioport_reg <= (others => '0');
      elsif write_enable = '1' then
        case address is
          when x"00" => ioport_reg <= data_in(3 downto 0);
          when x"02" => led <= data_in;
          when x"03" => seg <= data_in(6 downto 0);
          when x"04" => an <= data_in(3 downto 0);
          when x"05" => spi_data_tx <= data_in(7 downto 0); spi_start <= '1';
          when others => null;
        end case;
      end if;
    end if;
  end process;

  process(enable, address, btn, sw, button_0, spi_data_rx, spi_busy)
  begin
    data_out <= (others => '0');
    if enable = '1' then
      case address is
        when x"00" => data_out <= "0000000000" & button_0 & btn;
        when x"01" => data_out <= sw;
        when x"05" => data_out <= x"00" & spi_data_rx;
        when x"06" => data_out <= x"000" & "000" & spi_busy;
        when others => data_out <= (others => '0');
      end case;
    end if;
  end process;
end architecture;
