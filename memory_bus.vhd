-- ---------- --
-- Memory Bus -- 
-- ---------- --
-- 
-- The purpose of this module is to route reads and writes to the 4
-- different memory banks.
--
-- 0x0000-0x0fff ROM (writable after startup)
-- 0x4000-0x0fff Peripherals
-- 0x8000-0x0fff RAM
-- 0xc000-0x0fff RAM

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity memory_bus is
    port (
        address       : in  std_logic_vector(15 downto 0);
        data_in       : in  std_logic_vector(15 downto 0);
        write_mask    : in  std_logic_vector(1 downto 0);
        data_out      : out std_logic_vector(15 downto 0);
        bus_enable    : in  std_logic;
        write_enable  : in  std_logic;
        clk           : in  std_logic;      -- CPU system clock
        raw_clk       : in  std_logic;      -- Basys 3 100MHz clock
        ioport_0, ioport_1, ioport_2, ioport_3 : out std_logic;
        button_0      : in  std_logic;
        reset         : in  std_logic;
        spi_clk       : out std_logic;
        spi_mosi      : out std_logic;
        spi_miso      : in  std_logic
    );
end entity;

architecture rtl of memory_bus is

    signal rom_data_out         : std_logic_vector(15 downto 0);
    signal peripherals_data_out : std_logic_vector(15 downto 0);
    signal ram_data_out_0       : std_logic_vector(15 downto 0);
    signal ram_data_out_1       : std_logic_vector(15 downto 0);

    signal rom_write_enable         : std_logic;
    signal ram_write_enable_0       : std_logic;
    signal peripherals_write_enable : std_logic;
    signal ram_write_enable_1       : std_logic;

    signal peripherals_enable       : std_logic;

begin
    rom_write_enable <= '1' when (address(15 downto 14) = "00" and write_enable = '1') else '0';

    peripherals_write_enable <= '1'
        when (address(15 downto 14) = "01" and write_enable = '1')
        else '0';

    ram_write_enable_0 <= '1'
        when (address(15 downto 14) = "10" and write_enable = '1')
        else '0';

    ram_write_enable_1 <= '1'
        when (address(15 downto 14) = "11" and write_enable = '1')
        else '0';

    peripherals_enable <= '1'
        when (address(15 downto 14) = "01" and bus_enable = '1')
        else '0';

    data_out <= rom_data_out when address(15 downto 14) = "00" else
                peripherals_data_out when address(15 downto 14) = "01" else
                ram_data_out_1 when address(15) = '1' and address(14) = '1' else
                ram_data_out_0;

    rom_0 : entity work.memory
        port map (
            address      => address(11 downto 0),
            data_in      => data_in,
            data_out     => rom_data_out,
            write_mask   => write_mask,
            write_enable => rom_write_enable,
            clk          => clk  -- Changed to clk for CPU sync
        );

    peripherals_0 : entity work.peripherals
        port map (
            clk          => clk,
            raw_clk      => raw_clk, -- Used for high-speed SPI
            reset        => reset,
            enable       => peripherals_enable,
            write_enable => peripherals_write_enable,
            address      => address(7 downto 0),
            data_in      => data_in,
            data_out     => peripherals_data_out,
            ioport_0     => ioport_0,
            ioport_1     => ioport_1,
            ioport_2     => ioport_2,
            ioport_3     => ioport_3,
            button_0     => button_0,
            spi_clk      => spi_clk,
            spi_mosi     => spi_mosi,
            spi_miso     => spi_miso,
            -- Basys 3 hardware (not used by memory_bus top, but in peripheral entity)
            btn          => (others => '0'),
            sw           => (others => '0'),
            led          => open,
            seg          => open,
            an           => open
        );

    ram_0 : entity work.ram
        port map (
            address      => address(11 downto 0),
            data_in      => data_in,
            data_out     => ram_data_out_1,
            write_mask   => write_mask,
            write_enable => ram_write_enable_1,
            clk          => clk -- Changed to clk
        );

    ram_1 : entity work.ram
        port map (
            address      => address(11 downto 0),
            data_in      => data_in,
            data_out     => ram_data_out_0,
            write_mask   => write_mask,
            write_enable => ram_write_enable_0,
            clk          => clk -- Changed to clk
        );
end architecture;
