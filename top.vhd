library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    port (
        clk   : in  std_logic;
        reset : in  std_logic;
        led   : out std_logic_vector(15 downto 0);
        seg   : out std_logic_vector(6 downto 0);
        an    : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of top is

    -- CPU signals
    signal iaddr   : std_logic_vector(15 downto 0);
    signal idata   : std_logic_vector(15 downto 0);
    signal daddr   : std_logic_vector(15 downto 0);
    signal ddata_w : std_logic_vector(15 downto 0);
    signal ddata_r : std_logic_vector(15 downto 0) := (others => '0');
    signal dwe     : std_logic;
    signal dbe     : std_logic;
    signal dwmask  : std_logic_vector(1 downto 0);
    signal cpu_irq : std_logic_vector(3 downto 0) := "0000";

    -- ROM definition (Filled with NOPs, except a simple jump loop)
    type rom_t is array(0 to 2047) of std_logic_vector(15 downto 0);
    constant FIRMWARE : rom_t := (
        0      => x"0000",   -- NOP
        1      => x"6000",   -- JMP 0 (Assuming 0x6000 is your JMP opcode)
        others => x"0000"
    );

    -- 7-Segment Multiplexing signals
    signal clk_div : unsigned(17 downto 0) := (others => '0');
    signal hex_val : std_logic_vector(3 downto 0);

begin

    -- Tie the Program Counter directly to the LEDs
    led <= iaddr;

    -- Synchronous ROM logic
    process(clk)
    begin
        if rising_edge(clk) then
            idata <= FIRMWARE(to_integer(unsigned(iaddr(11 downto 1))));
        end if;
    end process;

    -- CPU Instantiation
    cpu_0 : entity work.cpu
        port map (
            clk      => clk,
            reset    => reset,
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

    -- 7-Segment Display Multiplexer (Shows current instruction)
    process(clk)
    begin
        if rising_edge(clk) then
            clk_div <= clk_div + 1;
        end if;
    end process;

    process(clk_div(17 downto 16), idata)
    begin
        case clk_div(17 downto 16) is
            when "00" => an <= "1110"; hex_val <= idata(3 downto 0);
            when "01" => an <= "1101"; hex_val <= idata(7 downto 4);
            when "10" => an <= "1011"; hex_val <= idata(11 downto 8);
            when "11" => an <= "0111"; hex_val <= idata(15 downto 12);
            when others => an <= "1111"; hex_val <= "0000";
        end case;
    end process;

    -- Hex to 7-Segment Decoder
    process(hex_val)
    begin
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
    end process;

end architecture;