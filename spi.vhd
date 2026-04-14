
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi is
  port (
    raw_clk   : in  std_logic;
    start     : in  std_logic;
    data_tx   : in  std_logic_vector(7 downto 0);
    data_rx   : out std_logic_vector(7 downto 0);
    busy      : out std_logic;
    sclk      : out std_logic;
    mosi      : out std_logic;
    miso      : in  std_logic
  );
end entity;

architecture rtl of spi is

  type state_type is (IDLE, CLOCK_0, CLOCK_1, LAST);
  signal state : state_type := IDLE;

  signal rx_buffer : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_buffer : std_logic_vector(7 downto 0) := (others => '0');

  signal count : unsigned(4 downto 0) := (others => '0');

begin

  data_rx <= rx_buffer;
  busy <= '1' when state /= IDLE else '0';

  process(raw_clk)
  begin
    if rising_edge(raw_clk) then

      case state is

        when IDLE =>
          sclk <= '0';
          mosi <= '0';

          if start = '1' then
            tx_buffer <= data_tx;
            rx_buffer <= (others => '0');
            count <= (others => '0');
            state <= CLOCK_0;
          end if;

        when CLOCK_0 =>
          sclk <= '0';

          if count /= 0 then
            rx_buffer <= rx_buffer(6 downto 0) & miso;
          end if;

          tx_buffer <= tx_buffer(6 downto 0) & '0';
          mosi <= tx_buffer(7);

          state <= CLOCK_1;

        when CLOCK_1 =>
          sclk <= '1';

          count <= count + 1;

          if count = 7 then
            state <= LAST;
          else
            state <= CLOCK_0;
          end if;

        when LAST =>
          sclk <= '0';
          rx_buffer <= rx_buffer(6 downto 0) & miso;
          state <= IDLE;

      end case;

    end if;
  end process;

end architecture;
