library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity top is
    port (
        clk   : in  std_logic;   -- 100 MHz board oscillator (W5)
        reset : in  std_logic;   -- BTNU top button (T18) — press to reset
        step  : in  std_logic;   -- BTNC centre button (U18) — each press = one CPU cycle
        led   : out std_logic_vector(15 downto 0);
        seg   : out std_logic_vector(6 downto 0);
        an    : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of top is

    -- -----------------------------------------------------------------------
    -- Debounce + single-pulse generator
    --
    -- Buttons bounce for ~1-10 ms. At 100 MHz, 1 ms = 100,000 cycles.
    -- We count how long the raw input has been different from the accepted
    -- stable level. Only when it has been stable for DEBOUNCE_CYCLES
    -- consecutive cycles do we accept the new level.
    --
    -- A rising-edge detector on the debounced level produces a single
    -- 100 MHz cycle wide pulse — this becomes clk_en for the CPU.
    -- -----------------------------------------------------------------------
    constant DEBOUNCE_CYCLES : integer := 500_000;  -- 5 ms at 100 MHz

    -- Step button (BTNC, U18)
    signal step_cnt    : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal step_stable : std_logic := '0';
    signal step_prev   : std_logic := '0';
    signal step_pulse  : std_logic := '0';

    -- Reset button (BTNU, T18)
    signal reset_cnt    : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal reset_stable : std_logic := '0';

    -- -----------------------------------------------------------------------
    -- CPU signals
    -- -----------------------------------------------------------------------
    signal iaddr   : std_logic_vector(15 downto 0);
    signal idata   : std_logic_vector(15 downto 0);
    signal daddr   : std_logic_vector(15 downto 0);
    signal ddata_w : std_logic_vector(15 downto 0);
    signal ddata_r : std_logic_vector(15 downto 0) := (others => '0');
    signal dwe     : std_logic;
    signal dbe     : std_logic;
    signal dwmask  : std_logic_vector(1 downto 0);
    signal cpu_irq : std_logic_vector(3 downto 0) := "0000";

    -- -----------------------------------------------------------------------
    -- Instruction ROM
    -- -----------------------------------------------------------------------
    type rom_t is array(0 to 2047) of std_logic_vector(15 downto 0);

    impure function load_rom(filename : string) return rom_t is
        file f       : text open read_mode is filename;
        variable l   : line;
        variable bv  : bit_vector(15 downto 0);
        variable rom : rom_t := (others => (others => '0'));
        variable i   : integer := 0;
    begin
        while not endfile(f) and i < 2048 loop
            readline(f, l);
            read(l, bv);
            rom(i) := to_stdlogicvector(bv);
            i := i + 1;
        end loop;
        return rom;
    end function;

    signal FIRMWARE : rom_t := load_rom("./tools/firmware.textio");

    -- -----------------------------------------------------------------------
    -- 7-Segment multiplexing — always at 100 MHz so display is always crisp
    -- -----------------------------------------------------------------------
    signal disp_clk_div : unsigned(17 downto 0) := (others => '0');
    signal hex_val      : std_logic_vector(3 downto 0) := (others => '0');

begin

    -- -----------------------------------------------------------------------
    -- Debounce: STEP button (BTNC, U18)
    --
    -- The counter increments every cycle the raw input differs from the
    -- current stable level. When it reaches DEBOUNCE_CYCLES the input has
    -- been stable long enough — we latch the new level and reset the counter.
    -- If the input flips back before the counter expires we reset and start
    -- again: a bounce never accumulates enough cycles to register.
    --
    -- The rising-edge detector on step_stable produces step_pulse: a single
    -- 100 MHz cycle wide '1' on the first cycle after a confirmed press.
    -- This is fed into cpu.clk_en so the CPU advances exactly one cycle.
    -- -----------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            -- Debounce counter
            if step = step_stable then
                step_cnt <= 0;                  -- already at stable level, no change pending
            elsif step_cnt = DEBOUNCE_CYCLES - 1 then
                step_stable <= step;            -- stable long enough: accept
                step_cnt    <= 0;
            else
                step_cnt <= step_cnt + 1;       -- keep counting
            end if;

            -- Single-cycle rising-edge pulse
            step_prev  <= step_stable;
            step_pulse <= step_stable and (not step_prev);
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- Debounce: RESET button (BTNU, T18) — level only, no pulse needed
    -- -----------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = reset_stable then
                reset_cnt <= 0;
            elsif reset_cnt = DEBOUNCE_CYCLES - 1 then
                reset_stable <= reset;
                reset_cnt    <= 0;
            else
                reset_cnt <= reset_cnt + 1;
            end if;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- CPU instantiation
    -- clk   → always the 100 MHz clock (Vivado is happy)
    -- clk_en → step_pulse: CPU state only advances on a confirmed button press
    -- reset → debounced BTNU level
    -- -----------------------------------------------------------------------
    cpu_0 : entity work.cpu
        port map (
            clk      => clk,
            clk_en   => step_pulse,
            reset    => reset_stable,
            iaddr    => iaddr,
            idata    => idata,
            daddr    => daddr,
            ddata_w  => ddata_w,
            ddata_r  => ddata_r,
            dwe      => dwe,
            dbe      => dbe,
            dwmask   => dwmask,
            irq      => cpu_irq
        );

    -- -----------------------------------------------------------------------
    -- Instruction ROM — combinational (async) read
    -- -----------------------------------------------------------------------
    idata <= FIRMWARE(to_integer(unsigned(iaddr(11 downto 1))));

    -- -----------------------------------------------------------------------
    -- LEDs show current instruction word (idata)
    -- -----------------------------------------------------------------------
    led <= idata;

    -- -----------------------------------------------------------------------
    -- 7-Segment display shows PC (iaddr) — always refreshed at 100 MHz
    -- -----------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            disp_clk_div <= disp_clk_div + 1;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            case disp_clk_div(17 downto 16) is
                when "00" => an <= "1110"; hex_val <= iaddr(3  downto 0);
                when "01" => an <= "1101"; hex_val <= iaddr(7  downto 4);
                when "10" => an <= "1011"; hex_val <= iaddr(11 downto 8);
                when "11" => an <= "0111"; hex_val <= iaddr(15 downto 12);
                when others => an <= "1111"; hex_val <= "0000";
            end case;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            case hex_val is
                when x"0" => seg <= "1000000";
                when x"1" => seg <= "1111001";
                when x"2" => seg <= "0100100";
                when x"3" => seg <= "0110000";
                when x"4" => seg <= "0011001";
                when x"5" => seg <= "0010010";
                when x"6" => seg <= "0000010";
                when x"7" => seg <= "1111000";
                when x"8" => seg <= "0000000";
                when x"9" => seg <= "0010000";
                when x"A" => seg <= "0001000";
                when x"B" => seg <= "0000011";
                when x"C" => seg <= "1000110";
                when x"D" => seg <= "0100001";
                when x"E" => seg <= "0000110";
                when x"F" => seg <= "0001110";
                when others => seg <= "1111111";
            end case;
        end if;
    end process;

end architecture;