-- ========== --
-- 4328 SoC   --
-- ========== --
--
-- Compact top-level entity for 32-pin FPGA boards.
-- Integrates CPU, memory, and peripherals internally.
--
-- External I/O (8 pins):
--   - clk, reset
--   - uart_tx, uart_rx
--   - gpio[3:0] (general purpose I/O, can be LEDs or buttons)
--
-- Memory map:
--   0x0000-0x0FFF  ROM (4K words, writable after boot)
--   0x4000-0x4FFF  Peripherals
--   0x8000-0x8FFF  RAM bank 0 (4K words)
--   0xC000-0xCFFF  RAM bank 1 (4K words)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity soc is
    port (
        -- System
        clk       : in  std_logic;
        reset     : in  std_logic;
        
        -- UART (for debugging / external communication)
        uart_tx   : out std_logic;
        uart_rx   : in  std_logic;
        
        -- General-purpose I/O (can be LEDs, buttons, etc.)
        gpio      : inout std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of soc is

    -- CPU signals
    signal cpu_iaddr   : std_logic_vector(15 downto 0);
    signal cpu_idata   : std_logic_vector(15 downto 0);
    signal cpu_daddr   : std_logic_vector(15 downto 0);
    signal cpu_ddata_w : std_logic_vector(15 downto 0);
    signal cpu_ddata_r : std_logic_vector(15 downto 0);
    signal cpu_dwe     : std_logic;
    signal cpu_dbe     : std_logic;
    signal cpu_dwmask  : std_logic_vector(1 downto 0);
    signal cpu_irq     : std_logic_vector(3 downto 0);

    -- Memory bank outputs
    signal rom_data_out    : std_logic_vector(15 downto 0);
    signal ram0_data_out   : std_logic_vector(15 downto 0);
    signal ram1_data_out   : std_logic_vector(15 downto 0);
    signal periph_data_out : std_logic_vector(15 downto 0);

    -- Memory write enables (decoded from address)
    signal rom_we    : std_logic;
    signal ram0_we   : std_logic;
    signal ram1_we   : std_logic;
    signal periph_we : std_logic;
    signal periph_en : std_logic;

    -- GPIO direction control (0=input, 1=output)
    signal gpio_dir    : std_logic_vector(3 downto 0) := "0000";
    signal gpio_out    : std_logic_vector(3 downto 0) := "0000";
    signal gpio_in     : std_logic_vector(3 downto 0);

    -- UART internal signals
    signal uart_tx_start : std_logic := '0';
    signal uart_tx_data  : std_logic_vector(7 downto 0) := x"00";
    signal uart_tx_busy  : std_logic;
    signal uart_rx_data  : std_logic_vector(7 downto 0);
    signal uart_rx_valid : std_logic;

    -- Internal interrupt sources (timer, UART, etc.)
    signal timer_irq : std_logic := '0';
    signal uart_irq  : std_logic := '0';

    -- Simple timer for IRQ0
    signal timer_count : unsigned(23 downto 0) := (others => '0');
    signal timer_match : unsigned(23 downto 0) := (others => '0');

begin

    -- =========================================================================
    -- CPU Core
    -- =========================================================================
    cpu_inst : entity work.cpu
        port map (
            clk     => clk,
            reset   => reset,
            iaddr   => cpu_iaddr,
            idata   => cpu_idata,
            daddr   => cpu_daddr,
            ddata_w => cpu_ddata_w,
            ddata_r => cpu_ddata_r,
            dwe     => cpu_dwe,
            dbe     => cpu_dbe,
            dwmask  => cpu_dwmask,
            irq     => cpu_irq
        );

    -- =========================================================================
    -- Address Decode
    -- =========================================================================
    -- bits [15:14] select the bank:
    --   00 = ROM (0x0000-0x3FFF)
    --   01 = Peripherals (0x4000-0x7FFF)
    --   10 = RAM0 (0x8000-0xBFFF)
    --   11 = RAM1 (0xC000-0xFFFF)

    rom_we    <= '1' when cpu_daddr(15 downto 14) = "00" and cpu_dwe = '1' else '0';
    periph_we <= '1' when cpu_daddr(15 downto 14) = "01" and cpu_dwe = '1' else '0';
    ram0_we   <= '1' when cpu_daddr(15 downto 14) = "10" and cpu_dwe = '1' else '0';
    ram1_we   <= '1' when cpu_daddr(15 downto 14) = "11" and cpu_dwe = '1' else '0';

    periph_en <= '1' when cpu_daddr(15 downto 14) = "01" and cpu_dbe = '1' else '0';

    -- Data read mux
    cpu_ddata_r <= rom_data_out    when cpu_daddr(15 downto 14) = "00" else
                   periph_data_out when cpu_daddr(15 downto 14) = "01" else
                   ram0_data_out   when cpu_daddr(15 downto 14) = "10" else
                   ram1_data_out;

    -- Instruction fetch (always from ROM for simplicity, or could decode)
    cpu_idata <= rom_data_out;

    -- =========================================================================
    -- ROM (4K × 16-bit, writable after boot for self-modification)
    -- =========================================================================
    rom_inst : entity work.memory
        port map (
            clk          => clk,
            address      => cpu_iaddr(11 downto 0),  -- Use iaddr for fetch
            data_in      => cpu_ddata_w,
            data_out     => rom_data_out,
            write_enable => rom_we,
            write_mask   => cpu_dwmask
        );

    -- =========================================================================
    -- RAM Bank 0 (4K × 16-bit)
    -- =========================================================================
    ram0_inst : entity work.ram
        port map (
            clk          => clk,
            address      => cpu_daddr(11 downto 0),
            data_in      => cpu_ddata_w,
            data_out     => ram0_data_out,
            write_enable => ram0_we,
            write_mask   => cpu_dwmask
        );

    -- =========================================================================
    -- RAM Bank 1 (4K × 16-bit)
    -- =========================================================================
    ram1_inst : entity work.ram
        port map (
            clk          => clk,
            address      => cpu_daddr(11 downto 0),
            data_in      => cpu_ddata_w,
            data_out     => ram1_data_out,
            write_enable => ram1_we,
            write_mask   => cpu_dwmask
        );

    -- =========================================================================
    -- Peripheral Register Map (0x4000-0x4FFF)
    -- =========================================================================
    -- Address | Register
    -- --------|--------------------------------------------
    -- 0x4000  | GPIO_DATA   [3:0] read/write
    -- 0x4001  | GPIO_DIR    [3:0] 0=input, 1=output
    -- 0x4002  | UART_TX     [7:0] write to transmit
    -- 0x4003  | UART_RX     [7:0] read received byte
    -- 0x4004  | UART_STATUS [0] tx_busy, [1] rx_valid
    -- 0x4005  | TIMER_LO    [15:0] timer match low word
    -- 0x4006  | TIMER_HI    [7:0]  timer match high byte
    -- 0x4007  | TIMER_CTL   [0] enable

    process(clk)
    begin
        if rising_edge(clk) then
            uart_tx_start <= '0';  -- pulse

            if reset = '1' then
                gpio_dir      <= "0000";
                gpio_out      <= "0000";
                timer_match   <= (others => '0');
                uart_tx_data  <= x"00";

            elsif periph_we = '1' then
                case cpu_daddr(7 downto 0) is
                    when x"00" =>  -- GPIO_DATA
                        gpio_out <= cpu_ddata_w(3 downto 0);
                    when x"01" =>  -- GPIO_DIR
                        gpio_dir <= cpu_ddata_w(3 downto 0);
                    when x"02" =>  -- UART_TX
                        uart_tx_data  <= cpu_ddata_w(7 downto 0);
                        uart_tx_start <= '1';
                    when x"05" =>  -- TIMER_LO
                        timer_match(15 downto 0) <= unsigned(cpu_ddata_w);
                    when x"06" =>  -- TIMER_HI
                        timer_match(23 downto 16) <= unsigned(cpu_ddata_w(7 downto 0));
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- Peripheral read mux
    process(periph_en, cpu_daddr, gpio_in, uart_rx_data, uart_rx_valid,
            uart_tx_busy, timer_count)
    begin
        periph_data_out <= (others => '0');
        if periph_en = '1' then
            case cpu_daddr(7 downto 0) is
                when x"00" =>  -- GPIO_DATA
                    periph_data_out(3 downto 0) <= gpio_in;
                when x"01" =>  -- GPIO_DIR
                    periph_data_out(3 downto 0) <= gpio_dir;
                when x"03" =>  -- UART_RX
                    periph_data_out(7 downto 0) <= uart_rx_data;
                when x"04" =>  -- UART_STATUS
                    periph_data_out(0) <= uart_tx_busy;
                    periph_data_out(1) <= uart_rx_valid;
                when x"05" =>  -- TIMER_LO
                    periph_data_out <= std_logic_vector(timer_count(15 downto 0));
                when x"06" =>  -- TIMER_HI
                    periph_data_out(7 downto 0) <= std_logic_vector(timer_count(23 downto 16));
                when others =>
                    periph_data_out <= (others => '0');
            end case;
        end if;
    end process;

    -- =========================================================================
    -- GPIO Bidirectional Logic
    -- =========================================================================
    gen_gpio: for i in 0 to 3 generate
        gpio(i) <= gpio_out(i) when gpio_dir(i) = '1' else 'Z';
        gpio_in(i) <= gpio(i);
    end generate;

    -- =========================================================================
    -- Simple Timer (24-bit, generates IRQ0 on match)
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                timer_count <= (others => '0');
                timer_irq   <= '0';
            else
                timer_count <= timer_count + 1;
                if timer_count = timer_match and timer_match /= 0 then
                    timer_irq <= '1';
                else
                    timer_irq <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- UART Transmitter (simple, 9600 baud @ assumed clk freq)
    -- =========================================================================
    -- NOTE: This is a placeholder. For real UART, instantiate a proper
    -- baud-rate generator and shift-register based TX/RX logic.
    -- For now, just tie off signals to avoid synthesis errors.
    
    uart_tx <= '1';  -- Idle high (mark state)
    uart_tx_busy <= '0';
    
    -- UART RX placeholder
    uart_rx_data  <= x"00";
    uart_rx_valid <= '0';
    uart_irq      <= '0';

    -- =========================================================================
    -- Interrupt Assignment
    -- =========================================================================
    cpu_irq(0) <= timer_irq;
    cpu_irq(1) <= uart_irq;
    cpu_irq(2) <= '0';  -- Reserved
    cpu_irq(3) <= '0';  -- Reserved

end architecture;
