-- ----------- --
-- 4328 CPU TB  --
-- ----------- --
--
-- Instruction encoding: [15:10] OPCODE | [9:7] RD | [6:4] RS | [3:2] AM/WIDTH | [1:0] COND
--
-- NO instruction ever uses any bit of the opcode word as an immediate value.
--
-- LOADIMM  (2 words):  enc_li(rd)  followed by  imm(value)
-- Jumps    (1 or 2 words depending on addressing mode):
--   AM=00 direct    (2 words): enc(OP_Jxx, 0, 0, AM_DIRECT,   cond) + imm(abs_target)
--   AM=01 indirect  (1 word):  enc(OP_Jxx, 0, rs, AM_INDIRECT, cond)
--   AM=10 indir+off (2 words): enc(OP_Jxx, 0, rs, AM_INDIR_OFF,cond) + imm(offset)
--   AM=11 illegal
--
-- Test suites:
--   1.  Reset
--   2.  NOP pipeline
--   3.  LOADIMM
--   4.  MOV
--   5.  ALU (ADD SUB AND OR XOR SHL SHR INC DEC)
--   6.  CMP + JZ.d taken / JNZ.d not-taken
--   7.  JMP.i (indirect, 1-word)
--   8.  CALL.i / RET
--   9.  LD / ST
--  10.  PUSH / POP
--  11.  Illegal opcode → vector 5
--  12.  IRQ0 + IRET
--  13.  Conditional execution (.z .c .n)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity cpu_tb is
end entity;

architecture sim of cpu_tb is

    constant CLK_PERIOD : time := 10 ns;
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal iaddr   : std_logic_vector(15 downto 0);
    signal idata   : std_logic_vector(15 downto 0) := x"0000";
    signal daddr   : std_logic_vector(15 downto 0);
    signal ddata_w : std_logic_vector(15 downto 0);
    signal ddata_r : std_logic_vector(15 downto 0) := x"0000";
    signal dwe     : std_logic;
    signal dbe     : std_logic;
    signal dwmask  : std_logic_vector(1 downto 0);
    signal irq     : std_logic_vector(3 downto 0) := "0000";

    type irom_t is array (0 to 255) of std_logic_vector(15 downto 0);
    signal irom : irom_t := (others => x"0000");

    type dram_t is protected
        procedure write_byte(addr : integer; lane : integer;
                             data : std_logic_vector(7 downto 0));
        procedure write_word(addr : integer;
                             data : std_logic_vector(15 downto 0));
        procedure clear;
        impure function read(addr : integer) return std_logic_vector;
    end protected dram_t;

    type dram_t is protected body
        type mem_t is array (0 to 255) of std_logic_vector(15 downto 0);
        variable mem : mem_t := (others => x"0000");
        procedure write_byte(addr : integer; lane : integer;
                             data : std_logic_vector(7 downto 0)) is
        begin
            if lane = 0 then mem(addr)(7  downto 0) := data;
            else              mem(addr)(15 downto 8) := data;
            end if;
        end procedure;
        procedure write_word(addr : integer;
                             data : std_logic_vector(15 downto 0)) is
        begin mem(addr) := data; end procedure;
        procedure clear is
        begin mem := (others => x"0000"); end procedure;
        impure function read(addr : integer) return std_logic_vector is
        begin return mem(addr); end function;
    end protected body dram_t;

    shared variable dram : dram_t;

    -- -----------------------------------------------------------------------
    -- Opcode constants
    -- -----------------------------------------------------------------------
    constant OP_ADD      : integer := 0;
    constant OP_SUB      : integer := 1;
    constant OP_AND      : integer := 2;
    constant OP_OR       : integer := 3;
    constant OP_XOR      : integer := 4;
    constant OP_NOT      : integer := 5;
    constant OP_SHL      : integer := 6;
    constant OP_SHR      : integer := 7;
    constant OP_INC      : integer := 8;
    constant OP_DEC      : integer := 9;
    constant OP_CMP      : integer := 10;
    constant OP_MOV      : integer := 11;
    constant OP_LOADIMM  : integer := 12;
    constant OP_NOP      : integer := 15;
    constant OP_LD       : integer := 16;
    constant OP_ST       : integer := 17;
    constant OP_PUSH     : integer := 20;
    constant OP_POP      : integer := 21;
    constant OP_JMP      : integer := 24;
    constant OP_JZ       : integer := 25;
    constant OP_JNZ      : integer := 26;
    constant OP_JC       : integer := 27;
    constant OP_CALL     : integer := 33;
    constant OP_RET      : integer := 34;
    constant OP_IRET     : integer := 35;
    constant OP_HLT      : integer := 37;
    constant OP_ENIRQ    : integer := 48;
    constant OP_WRITERIV : integer := 55;

    -- inst[3:2] — addressing mode (jumps) or width (ALU/mem)
    constant AM_DIRECT   : integer := 0;  -- jump: 2-word, absolute target in next word
    constant AM_INDIRECT : integer := 1;  -- jump: 1-word, target in regfile[RS]
    constant AM_INDIR_OFF: integer := 2;  -- jump: 2-word, regfile[RS] + next word
    constant W_W         : integer := 0;  -- ALU/mem: 16-bit
    constant W_L         : integer := 1;  -- ALU/mem: 8-bit low
    constant W_H         : integer := 2;  -- ALU/mem: 8-bit high
    constant W_D         : integer := 3;  -- ALU/mem: 32-bit pair

    -- inst[1:0] — condition
    constant C_AL : integer := 0;  -- always
    constant C_Z  : integer := 1;  -- if Z=1
    constant C_C  : integer := 2;  -- if C=1
    constant C_N  : integer := 3;  -- if N=1

    -- -----------------------------------------------------------------------
    -- Encoders
    -- -----------------------------------------------------------------------

    -- General: [OPCODE(6)][RD(3)][RS(3)][AM_or_WIDTH(2)][COND(2)]
    function enc(op    : integer;
                 rd    : integer := 0;
                 rs    : integer := 0;
                 width : integer := 0;
                 cond  : integer := 0) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(op,    6)) &
               std_logic_vector(to_unsigned(rd,    3)) &
               std_logic_vector(to_unsigned(rs,    3)) &
               std_logic_vector(to_unsigned(width, 2)) &
               std_logic_vector(to_unsigned(cond,  2));
    end function;

    -- LOADIMM opcode word: [LOADIMM][RD][000000]
    -- Must be immediately followed by imm(value) at the next address.
    function enc_li(rd : integer := 0) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(OP_LOADIMM, 6)) &
               std_logic_vector(to_unsigned(rd,         3)) &
               std_logic_vector(to_unsigned(0,          7));
    end function;

    -- 16-bit immediate word (for LOADIMM and direct/indir+off jumps)
    function imm(v : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(v, 16));
    end function;

    -- -----------------------------------------------------------------------
    -- DUT
    -- -----------------------------------------------------------------------
    component cpu is
        port (
            clk     : in  std_logic;
            reset   : in  std_logic;
            iaddr   : out std_logic_vector(15 downto 0);
            idata   : in  std_logic_vector(15 downto 0);
            daddr   : out std_logic_vector(15 downto 0);
            ddata_w : out std_logic_vector(15 downto 0);
            ddata_r : in  std_logic_vector(15 downto 0);
            dwe     : out std_logic;
            dbe     : out std_logic;
            dwmask  : out std_logic_vector(1 downto 0);
            irq     : in  std_logic_vector(3 downto 0)
        );
    end component;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : cpu port map (
        clk => clk, reset => reset,
        iaddr => iaddr, idata => idata,
        daddr => daddr, ddata_w => ddata_w, ddata_r => ddata_r,
        dwe => dwe, dbe => dbe, dwmask => dwmask, irq => irq
    );

    idata <= irom(to_integer(unsigned(iaddr(7 downto 0))));

    process(clk)
        variable aw : integer range 0 to 255;
    begin
        if rising_edge(clk) then
            aw := to_integer(unsigned(daddr(8 downto 1)));
            if dwe = '1' then
                if dwmask(0) = '0' then dram.write_byte(aw, 0, ddata_w(7  downto 0)); end if;
                if dwmask(1) = '0' then dram.write_byte(aw, 1, ddata_w(15 downto 8)); end if;
            end if;
            ddata_r <= dram.read(aw);
        end if;
    end process;

    process
    begin
        wait for 200 us;
        assert false report "TIMEOUT" severity failure;
    end process;

    -- =========================================================================
    process
        variable l          : line;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        procedure ok(msg : string) is
        begin
            write(l, string'("[PASS] ") & msg); writeline(output, l);
            pass_count := pass_count + 1;
        end procedure;

        procedure check(actual   : std_logic_vector;
                        expected : std_logic_vector;
                        msg      : string) is
        begin
            if actual = expected then
                write(l, string'("[PASS] ") & msg); writeline(output, l);
                pass_count := pass_count + 1;
            else
                write(l, string'("[FAIL] ") & msg &
                      "  got=" & to_hstring(actual) &
                      " want=" & to_hstring(expected));
                writeline(output, l); fail_count := fail_count + 1;
                assert false report "[FAIL] " & msg severity failure;
            end if;
        end procedure;

        procedure do_reset is
        begin
            reset <= '1';
            for i in 1 to 3 loop wait until rising_edge(clk); end loop;
            reset <= '0';
            for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure clk_n(n : integer) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        type prog_t is array (natural range <>) of std_logic_vector(15 downto 0);
        procedure load(prog : prog_t) is
        begin
            irom <= (others => enc(OP_HLT));
            for i in prog'range loop irom(i) <= prog(i); end loop;
            wait for 1 ns;
        end procedure;

    begin

        -- ===================================================================
        -- Suite 1: Reset
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 1: Reset ===")); writeline(output, l);

        load((0 => enc(OP_HLT)));
        reset <= '1'; clk_n(1);
        check(iaddr, x"0000", "iaddr=0 during reset");
        reset <= '0'; clk_n(1);
        check(iaddr, x"0000", "iaddr=0 first fetch after reset");
        clk_n(2);

        -- ===================================================================
        -- Suite 2: NOP pipeline advance
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 2: NOP ===")); writeline(output, l);

        load((0 => enc(OP_NOP), 1 => enc(OP_NOP),
              2 => enc(OP_NOP), 3 => enc(OP_HLT)));
        do_reset; clk_n(8);
        assert to_integer(unsigned(iaddr)) >= 3
            report "[FAIL] NOP: PC stalled" severity failure;
        ok("NOP: PC advanced through 3 NOPs");

        -- ===================================================================
        -- Suite 3: LOADIMM  (2-word instruction)
        --   addr 0: enc_li(0)        addr 1: imm(7)
        --   addr 2: ST mem[R0=7]←7   addr 3: HLT
        --   byte addr 7 → word addr 3 → dram(3)=0x0007
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 3: LOADIMM ===")); writeline(output, l);

        load((0 => enc_li(0), 1 => imm(7),
              2 => enc(OP_ST, 0, 0),
              3 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(16);
        check(dram.read(3), x"0007", "LOADIMM: R0=7 stored");

        -- ===================================================================
        -- Suite 4: MOV  R2 ← R0
        --   0-1: R0←9   2: MOV R2,R0   3: ST mem[R2=9]←9   4: HLT
        --   byte 9 → word 4 → dram(4)=0x0009
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 4: MOV ===")); writeline(output, l);

        load((0 => enc_li(0), 1 => imm(9),
              2 => enc(OP_MOV, 2, 0),
              3 => enc(OP_ST,  2, 2),
              4 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(18);
        check(dram.read(4), x"0009", "MOV: R2=9 stored");

        -- ===================================================================
        -- Suite 5: ALU
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 5: ALU ===")); writeline(output, l);

        -- 5a. ADD 4+3=7 → dram(3)
        load((0 => enc_li(0), 1 => imm(3),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),   4 => imm(4),
              5 => enc(OP_ADD, 0, 1),
              6 => enc(OP_ST,  0, 0),
              7 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(26);
        check(dram.read(3), x"0007", "ADD: 4+3=7");

        -- 5b. SUB 9-5=4 → dram(2)
        load((0 => enc_li(0), 1 => imm(5),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),   4 => imm(9),
              5 => enc(OP_SUB, 0, 1),
              6 => enc(OP_ST,  0, 0),
              7 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(26);
        check(dram.read(2), x"0004", "SUB: 9-5=4");

        -- 5c. AND 15&15=15 → dram(7)
        load((0 => enc_li(0), 1 => imm(15),
              2 => enc(OP_MOV, 1, 0),
              3 => enc(OP_AND, 0, 1),
              4 => enc(OP_ST,  0, 0),
              5 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(20);
        check(dram.read(7), x"000F", "AND: 15&15=15");

        -- 5d. OR 5|10=15 → dram(7)
        load((0 => enc_li(0), 1 => imm(5),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),   4 => imm(10),
              5 => enc(OP_OR,  0, 1),
              6 => enc(OP_ST,  0, 0),
              7 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(26);
        check(dram.read(7), x"000F", "OR: 5|10=15");

        -- 5e. XOR 5^3=6 → dram(3)
        load((0 => enc_li(0), 1 => imm(3),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),   4 => imm(5),
              5 => enc(OP_XOR, 0, 1),
              6 => enc(OP_ST,  0, 0),
              7 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(26);
        check(dram.read(3), x"0006", "XOR: 5^3=6");

        -- 5f. SHL 1<<2=4 → dram(2)
        load((0 => enc_li(0), 1 => imm(1),
              2 => enc(OP_SHL, 0, 0),
              3 => enc(OP_SHL, 0, 0),
              4 => enc(OP_ST,  0, 0),
              5 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(18);
        check(dram.read(2), x"0004", "SHL: 1<<2=4");

        -- 5g. SHR 8>>2=2 → dram(1)
        load((0 => enc_li(0), 1 => imm(8),
              2 => enc(OP_SHR, 0, 0),
              3 => enc(OP_SHR, 0, 0),
              4 => enc(OP_ST,  0, 0),
              5 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(18);
        check(dram.read(1), x"0002", "SHR: 8>>2=2");

        -- 5h. INC/DEC 5+1+1-1=6 → dram(3)
        load((0 => enc_li(0), 1 => imm(5),
              2 => enc(OP_INC, 0, 0),
              3 => enc(OP_INC, 0, 0),
              4 => enc(OP_DEC, 0, 0),
              5 => enc(OP_ST,  0, 0),
              6 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(20);
        check(dram.read(3), x"0006", "INC/DEC: 5+1+1-1=6");

        -- ===================================================================
        -- Suite 6: CMP + direct jumps (AM_DIRECT, 2-word)
        --
        -- 6a. JZ.d taken: R0=R1=7, CMP→Z=1, JZ.d target=8 (skips LOADIMM at 6-7)
        --   0-1: R0←7   2: MOV R1,R0   3: CMP
        --   4: JZ.d     5: imm(8)      6-7: LOADIMM R0←1 (skipped)
        --   8: ST mem[R0=7]←7 → dram(3)   9: HLT
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 6: CMP + branches ===")); writeline(output, l);

        load((0 => enc_li(0),                         1 => imm(7),
              2 => enc(OP_MOV, 1, 0),
              3 => enc(OP_CMP, 0, 1),
              4 => enc(OP_JZ,  0, 0, AM_DIRECT, C_AL), 5 => imm(8),
              6 => enc_li(0),                         7 => imm(1),
              8 => enc(OP_ST, 0, 0),
              9 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(30);
        check(dram.read(3), x"0007", "JZ.d taken: Z=1, skips LOADIMM, R0 stays 7");

        -- 6b. JNZ.d not-taken: Z=1, JNZ not taken, falls through LOADIMM R0←3
        --   Same layout with JNZ. Falls through to LOADIMM(6,7)=R0←3, ST→dram(1)
        load((0 => enc_li(0),                          1 => imm(7),
              2 => enc(OP_MOV, 1, 0),
              3 => enc(OP_CMP, 0, 1),
              4 => enc(OP_JNZ, 0, 0, AM_DIRECT, C_AL), 5 => imm(8),
              6 => enc_li(0),                          7 => imm(3),
              8 => enc(OP_ST, 0, 0),
              9 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(30);
        check(dram.read(1), x"0003", "JNZ.d not-taken: Z=1, falls through, R0=3");

        -- ===================================================================
        -- Suite 7: JMP.i (indirect, 1-word)
        --   0-1: R0←8   2: MOV R1,R0   3: JMP.i R1  (1 word — no immediate follows)
        --   4-5: LOADIMM R0←1 (skipped)
        --   6-7: LOADIMM R0←2 (skipped)
        --   8: ST mem[R0=8]←8 → dram(4)   9: HLT
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 7: JMP.i ===")); writeline(output, l);

        load((0 => enc_li(0),                           1 => imm(8),
              2 => enc(OP_MOV, 1, 0),
              3 => enc(OP_JMP, 0, 1, AM_INDIRECT, C_AL),
              4 => enc_li(0),                           5 => imm(1),
              6 => enc_li(0),                           7 => imm(2),
              8 => enc(OP_ST,  0, 0),
              9 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(24);
        check(dram.read(4), x"0008", "JMP.i: indirect to addr 8, skips 4-7");

        -- ===================================================================
        -- Suite 8: CALL.i / RET
        --   0-1: R0←8   2: MOV R1,R0
        --   3: CALL.i R1  (1-word, pushes ret=4, jumps to 8)
        --   4: ST mem[R0=9]←9 → dram(4)   5: HLT
        --   6,7: NOP padding
        --   8-9: R0←9 (callee)   10: RET → returns to 4
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 8: CALL.i/RET ===")); writeline(output, l);

        load((0  => enc_li(0),                            1  => imm(8),
              2  => enc(OP_MOV,  1, 0),
              3  => enc(OP_CALL, 0, 1, AM_INDIRECT, C_AL),
              4  => enc(OP_ST,   0, 0),
              5  => enc(OP_HLT),
              6  => enc(OP_NOP),
              7  => enc(OP_NOP),
              8  => enc_li(0),                            9  => imm(9),
              10 => enc(OP_RET)));
        dram.clear; do_reset; clk_n(40);
        check(dram.read(4), x"0009", "CALL.i/RET: callee R0=9, returns, ST writes 9");

        -- ===================================================================
        -- Suite 9: LD / ST
        --   dram(1)=4. R0←2, LD R0,(R0)→R0=4, ST mem[4]←4 → dram(2)
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 9: LD/ST ===")); writeline(output, l);

        dram.clear; dram.write_word(1, x"0004");
        load((0 => enc_li(0), 1 => imm(2),
              2 => enc(OP_LD,  0, 0),
              3 => enc(OP_ST,  0, 0),
              4 => enc(OP_HLT)));
        do_reset; clk_n(20);
        check(dram.read(2), x"0004", "LD/ST: loaded 4 from addr 2, stored to addr 4");

        -- ===================================================================
        -- Suite 10: PUSH / POP
        --   0-1: R0←7   2: PUSH R0   3-4: R0←3   5: POP R0→7
        --   6: ST mem[7]←7 → dram(3)   7: HLT
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 10: PUSH/POP ===")); writeline(output, l);

        load((0 => enc_li(0),          1 => imm(7),
              2 => enc(OP_PUSH, 0, 0),
              3 => enc_li(0),          4 => imm(3),
              5 => enc(OP_POP,  0, 0),
              6 => enc(OP_ST,   0, 0),
              7 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(28);
        check(dram.read(3), x"0007", "PUSH/POP: push 7, clobber, pop restores 7");

        -- ===================================================================
        -- Suite 11: Illegal opcode → vector 5
        --   0-1: R0←14   2: WRITERIV RIV[5]←R0
        --   3: opcode 63 (0xFC00, illegal)   4: HLT (must not run)
        --   5-13: NOPs   14-15: R0←1   16: ST→dram(0)   17: HLT
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 11: Illegal opcode ===")); writeline(output, l);

        load((0  => enc_li(0),             1  => imm(14),
              2  => enc(OP_WRITERIV, 0, 5),
              3  => x"FC00",
              4  => enc(OP_HLT),
              5  => enc(OP_NOP), 6  => enc(OP_NOP), 7  => enc(OP_NOP),
              8  => enc(OP_NOP), 9  => enc(OP_NOP), 10 => enc(OP_NOP),
              11 => enc(OP_NOP), 12 => enc(OP_NOP), 13 => enc(OP_NOP),
              14 => enc_li(0),             15 => imm(1),
              16 => enc(OP_ST, 0, 0),
              17 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(50);
        check(dram.read(0), x"0001", "ILL_OPCODE: vector 5, handler sentinel=1 at mem[1]");

        -- ===================================================================
        -- Suite 12: IRQ0 + IRET
        --   0-1: R0←15   2: WRITERIV RIV[0]←R0   3: ENIRQ
        --   4,5,6: NOPs (IRQ fires here)
        --   7-8: R0←2   9: ST→dram(1)   10: HLT
        --   11-14: NOPs
        --   15-16: R0←4 (handler)   17: ST→dram(2)   18: IRET
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 12: IRQ0 + IRET ===")); writeline(output, l);

        load((0  => enc_li(0),             1  => imm(15),
              2  => enc(OP_WRITERIV, 0, 0),
              3  => enc(OP_ENIRQ),
              4  => enc(OP_NOP), 5  => enc(OP_NOP), 6  => enc(OP_NOP),
              7  => enc_li(0),             8  => imm(2),
              9  => enc(OP_ST,   0, 0),
              10 => enc(OP_HLT),
              11 => enc(OP_NOP), 12 => enc(OP_NOP),
              13 => enc(OP_NOP), 14 => enc(OP_NOP),
              15 => enc_li(0),             16 => imm(4),
              17 => enc(OP_ST,   0, 0),
              18 => enc(OP_IRET)));
        dram.clear; irq <= "0000"; do_reset;
        clk_n(10); irq <= "0001"; clk_n(2); irq <= "0000"; clk_n(50);
        check(dram.read(2), x"0004", "IRQ0: handler sentinel=4 at mem[4]");
        check(dram.read(1), x"0002", "IRQ0: IRET returned, main sentinel=2 at mem[2]");

        -- ===================================================================
        -- Suite 13: Conditional execution (inst[1:0])
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Suite 13: Conditional execution ===")); writeline(output, l);

        -- 13a. ADD.z taken: R0=R1=7, CMP→Z=1, ADD.z→14, ST→dram(7)
        load((0 => enc_li(0), 1 => imm(7),
              2 => enc(OP_MOV, 1, 0),
              3 => enc(OP_CMP, 0, 1),
              4 => enc(OP_ADD, 0, 1, W_W, C_Z),
              5 => enc(OP_ST,  0, 0),
              6 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(24);
        check(dram.read(7), x"000E", "COND_Z: ADD.z fires, R0=7+7=14");

        -- 13b. ADD.z suppressed: R0=5 R1=3, CMP→Z=0, ADD.z skipped, R0=5→dram(2)
        load((0 => enc_li(0), 1 => imm(3),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),   4 => imm(5),
              5 => enc(OP_CMP, 0, 1),
              6 => enc(OP_ADD, 0, 1, W_W, C_Z),
              7 => enc(OP_ST,  0, 0),
              8 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(28);
        check(dram.read(2), x"0005", "COND_Z: ADD.z suppressed, R0 stays 5");

        -- 13c. MOV.c taken: SHR 3→1 C=1, MOV.c R1←1, ST mem[1]←1→dram(0)
        load((0 => enc_li(0), 1 => imm(3),
              2 => enc(OP_SHR, 0, 0),
              3 => enc(OP_MOV, 1, 0, W_W, C_C),
              4 => enc(OP_ST,  1, 1),
              5 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(20);
        check(dram.read(0), x"0001", "COND_C: MOV.c fires when C=1");

        -- 13d. MOV.c suppressed: SHR 4→2 C=0, MOV.c skipped, R1=0→dram(0)=0
        load((0 => enc_li(0), 1 => imm(4),
              2 => enc(OP_SHR, 0, 0),
              3 => enc(OP_MOV, 1, 0, W_W, C_C),
              4 => enc(OP_ST,  1, 1),
              5 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(20);
        check(dram.read(0), x"0000", "COND_C: MOV.c suppressed when C=0");

        -- 13e. MOV.n taken: SUB 3-5→N=1, MOV.n R2←R1=5, ST→dram(2)
        load((0 => enc_li(0),          1 => imm(5),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),          4 => imm(3),
              5 => enc(OP_SUB, 0, 1),
              6 => enc(OP_MOV, 2, 1, W_W, C_N),
              7 => enc(OP_ST,  2, 2),
              8 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(28);
        check(dram.read(2), x"0005", "COND_N: MOV.n fires when N=1");

        -- 13f. MOV.n suppressed: SUB 5-3→N=0, R2=0→dram(0)=0
        load((0 => enc_li(0),          1 => imm(3),
              2 => enc(OP_MOV, 1, 0),
              3 => enc_li(0),          4 => imm(5),
              5 => enc(OP_SUB, 0, 1),
              6 => enc(OP_MOV, 2, 1, W_W, C_N),
              7 => enc(OP_ST,  2, 2),
              8 => enc(OP_HLT)));
        dram.clear; do_reset; clk_n(28);
        check(dram.read(0), x"0000", "COND_N: MOV.n suppressed when N=0");

        -- ===================================================================
        -- Summary
        -- ===================================================================
        write(l, string'("")); writeline(output, l);
        write(l, string'("========================================")); writeline(output, l);
        write(l, string'("Simulation complete.")); writeline(output, l);
        write(l, string'("Tests passed: ") & integer'image(pass_count)); writeline(output, l);
        write(l, string'("Tests failed: ") & integer'image(fail_count)); writeline(output, l);
        write(l, string'("========================================")); writeline(output, l);

        assert fail_count = 0 report "ONE OR MORE TESTS FAILED" severity failure;
        std.env.stop(0);
        wait;
    end process;

end architecture;