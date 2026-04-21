library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        uart_tx  : out std_logic;    -- or repurpose as debug
        uart_rx  : in  std_logic;
        spi_clk  : out std_logic;
        spi_mosi : out std_logic;
        spi_miso : in  std_logic;
        gpio     : inout std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of top is
    -- internal wires for CPU <-> memory_bus
    signal iaddr   : std_logic_vector(15 downto 0);
    signal idata   : std_logic_vector(15 downto 0);
    signal daddr   : std_logic_vector(15 downto 0);
    signal ddata_w : std_logic_vector(15 downto 0);
    signal ddata_r : std_logic_vector(15 downto 0);
    signal dwe, dbe : std_logic;
    signal dwmask  : std_logic_vector(1 downto 0);

    -- tie-offs
    signal led_nc  : std_logic_vector(15 downto 0);
    signal seg_nc  : std_logic_vector(6 downto 0);
    signal an_nc   : std_logic_vector(3 downto 0);
begin
    cpu_0 : entity work.cpu
        port map (
            clk => clk, reset => reset,
            iaddr => iaddr, idata => idata,
            daddr => daddr, ddata_w => ddata_w,
            ddata_r => ddata_r,
            dwe => dwe, dbe => dbe, dwmask => dwmask,
            irq => (others => '0')
        );

    bus_0 : entity work.memory_bus
        port map (
            clk => clk, raw_clk => clk,  -- or a PLL clock
            reset => reset,
            address => daddr, data_in => ddata_w,
            write_mask => dwmask, data_out => ddata_r,
            bus_enable => dbe, write_enable => dwe,
            -- -- Tie off Basys3-specific I/O internally:
            -- btn      => (others => '0'),
            -- sw       => (others => '0'),
            -- led      => led_nc,    -- open equivalent
            -- seg      => seg_nc,
            -- an       => an_nc,
            -- Expose only what you want:
            ioport_0 => gpio(0), ioport_1 => gpio(1),
            ioport_2 => gpio(2), ioport_3 => gpio(3),
            button_0 => '0',
            spi_clk  => spi_clk,
            spi_mosi => spi_mosi,
            spi_miso => spi_miso
        );

    -- Instruction bus: memory_bus also serves ROM but its port
    -- doesn't expose iaddr/idata directly. You need to handle this
    -- (see note below).
end architecture;
