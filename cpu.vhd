-- ------- --
-- 4328 CPU --
-- ------- --
--
-- 16-bit NISC CPU for the Basys 3 (Artix-7).
--
-- Pipeline:   FETCH → DECODE → EXECUTE  (3 stages)
-- Hazards:    flush-on-taken-branch (1 bubble); no branch predictor
-- CW ROM:     512 × 32-bit  ({opcode[5:0], step[2:0]} index)
-- Sequencer:  3-bit micro-step counter, LAST_STEP terminates
-- Interrupts: 8 vectors, fixed priority, no nesting, GIE gating
--
-- CW field layout  [31:0]
--   [31:28] ALU_OP          (4)
--   [27:25] SRC_B           (3)
--   [24]    REG_WE          (1)
--   [23]    RD_FROM_INST    (1)
--   [22:20] WB_SRC          (3)
--   [19]    WIDTH_FROM_INST (1)  -- 1: take width from inst[3:2]; 0: use CW WIDTH field
--   [18:17] WIDTH           (2)  -- used when WIDTH_FROM_INST=0
--   [16]    MEM_RD          (1)
--   [15]    MEM_WR          (1)
--   [14]    MEM_WIDTH       (1)
--   [13:12] MEM_SRC         (2)
--   [11:9]  PC_SRC          (3)
--   [8:5]   BRANCH_COND     (4)
--   [4:2]   SP_OP           (3)
--   [1]     PRIV_CHECK      (1)
--   [0]     LAST_STEP       (1)
--
-- Instruction width encoding (inst[3:2], active when WIDTH_FROM_INST=1):
--   00 = 16-bit  (default, W16)
--   01 = 8-bit low byte  (.l suffix)
--   10 = 8-bit high byte (.h suffix)
--   11 = 32-bit pair     (.d suffix, ER)
--
-- Jump/branch addressing mode (inst[3:2], when JMP_AM_FROM_INST=1 in CW):
--   00 = Direct      — target in next word (2-word instruction, absolute)
--   01 = Indirect    — target in regfile[RS] (1-word instruction)
--   10 = Indir+Off   — target = regfile[RS] + next word (2-word instruction)
--   11 = Illegal     — triggers illegal-opcode fault
--
-- Instruction condition encoding (inst[1:0], evaluated in EXECUTE):
--   00 = always   (default, unconditional)
--   01 = if Z=1   (.z suffix)
--   10 = if C=1   (.c suffix)
--   11 = if N=1   (.n suffix)
-- When condition is not met the instruction executes as a NOP:
-- no writeback, no memory access, no PC redirect, no side effects.
-- LOADIMM is a 2-word instruction: opcode word + immediate word.
-- The immediate word is consumed from the instruction stream in step 0;
-- the register is written in step 1. WIDTH and COND fields in the opcode
-- word are ignored; the RD field selects the destination register.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ---------------------------------------------------------------------------
-- Entity
-- ---------------------------------------------------------------------------

entity cpu is
    port (
        clk      : in  std_logic;
        clk_en   : in  std_logic;   -- clock enable: CPU only advances when '1'
        reset    : in  std_logic;

        -- Instruction bus (async ROM — combinational read)
        iaddr    : out std_logic_vector(15 downto 0);
        idata    : in  std_logic_vector(15 downto 0);

        -- Data bus (memory_bus)
        daddr    : out std_logic_vector(15 downto 0);
        ddata_w  : out std_logic_vector(15 downto 0);
        ddata_r  : in  std_logic_vector(15 downto 0);
        dwe      : out std_logic;
        dbe      : out std_logic;                       -- bus enable (read)
        dwmask   : out std_logic_vector(1 downto 0);    -- byte write mask

        -- External IRQ lines (active-high, level)
        irq      : in  std_logic_vector(3 downto 0)
    );
end entity;

-- ---------------------------------------------------------------------------
-- Architecture
-- ---------------------------------------------------------------------------

architecture rtl of cpu is

    -- -----------------------------------------------------------------------
    -- Control word ROM  (512 × 32-bit)
    -- Indexed by {opcode[5:0], step[2:0]}
    -- -----------------------------------------------------------------------
    type cw_rom_t is array (0 to 511) of std_logic_vector(31 downto 0);

    -- CW field bit positions (constants for readability)
    constant F_ALU_OP_H   : integer := 31;
    constant F_ALU_OP_L   : integer := 28;
    constant F_SRC_B_H    : integer := 27;
    constant F_SRC_B_L    : integer := 25;
    constant F_REG_WE     : integer := 24;
    constant F_RD_FROM_INST : integer := 23;
    constant F_WB_SRC_H   : integer := 22;
    constant F_WB_SRC_L   : integer := 20;
    constant F_WIDTH_FROM_INST : integer := 19; -- 1=take width from inst[3:2]
    constant F_WIDTH_H    : integer := 18;
    constant F_WIDTH_L    : integer := 17;
    constant F_MEM_RD     : integer := 16;
    constant F_MEM_WR     : integer := 15;
    constant F_MEM_WIDTH  : integer := 14;
    constant F_MEM_SRC_H  : integer := 13;
    constant F_MEM_SRC_L  : integer := 12;
    constant F_PC_SRC_H   : integer := 11;
    constant F_PC_SRC_L   : integer := 9;
    constant F_BRANCH_H   : integer := 8;
    constant F_BRANCH_L   : integer := 5;
    constant F_SP_OP_H    : integer := 4;
    constant F_SP_OP_L    : integer := 2;
    constant F_PRIV_CHECK : integer := 1;
    constant F_LAST_STEP  : integer := 0;

    -- ALU_OP encodings
    constant ALU_ADD      : std_logic_vector(3 downto 0) := "0000";
    constant ALU_SUB      : std_logic_vector(3 downto 0) := "0001";
    constant ALU_AND      : std_logic_vector(3 downto 0) := "0010";
    constant ALU_OR       : std_logic_vector(3 downto 0) := "0011";
    constant ALU_XOR      : std_logic_vector(3 downto 0) := "0100";
    constant ALU_NOT      : std_logic_vector(3 downto 0) := "0101";
    constant ALU_SHL      : std_logic_vector(3 downto 0) := "0110";
    constant ALU_SHR      : std_logic_vector(3 downto 0) := "0111";
    constant ALU_INC      : std_logic_vector(3 downto 0) := "1000";
    constant ALU_DEC      : std_logic_vector(3 downto 0) := "1001";
    constant ALU_CMP      : std_logic_vector(3 downto 0) := "1010";
    constant ALU_PASSA    : std_logic_vector(3 downto 0) := "1011";
    constant ALU_PASSB    : std_logic_vector(3 downto 0) := "1100";
    constant ALU_NOP      : std_logic_vector(3 downto 0) := "1101";

    -- SRC_B encodings
    constant SB_RS        : std_logic_vector(2 downto 0) := "000"; -- register file RS
    constant SB_IMM       : std_logic_vector(2 downto 0) := "001"; -- 4-bit immediate
    constant SB_MEM       : std_logic_vector(2 downto 0) := "010"; -- memory read data
    constant SB_SP        : std_logic_vector(2 downto 0) := "011"; -- stack pointer
    constant SB_PC        : std_logic_vector(2 downto 0) := "100"; -- program counter

    -- WB_SRC encodings
    constant WB_ALU       : std_logic_vector(2 downto 0) := "000";
    constant WB_MEM       : std_logic_vector(2 downto 0) := "001";
    constant WB_IMM       : std_logic_vector(2 downto 0) := "010";
    constant WB_PC1       : std_logic_vector(2 downto 0) := "011"; -- PC+1
    constant WB_SPEC      : std_logic_vector(2 downto 0) := "100"; -- special reg
    constant WB_IMM_WORD  : std_logic_vector(2 downto 0) := "101"; -- captured 16-bit immediate word

    -- PC_SRC encodings
    constant PC_SEQ       : std_logic_vector(2 downto 0) := "000"; -- RPC+1 (sequential)
    constant PC_JUMP      : std_logic_vector(2 downto 0) := "001"; -- jump (mode in inst[3:2])
    constant PC_STALL     : std_logic_vector(2 downto 0) := "010"; -- hold PC (HLT)
    constant PC_INT       : std_logic_vector(2 downto 0) := "011"; -- interrupt entry
    constant PC_RET       : std_logic_vector(2 downto 0) := "100"; -- return (stack pop)
    constant PC_IRET      : std_logic_vector(2 downto 0) := "101"; -- IRET (from RIP)

    -- Jump addressing mode constants — match inst[3:2] encoding
    constant AM_DIRECT    : std_logic_vector(1 downto 0) := "00"; -- 2-word: abs target in next word
    constant AM_INDIRECT  : std_logic_vector(1 downto 0) := "01"; -- 1-word: target in regfile[RS]
    constant AM_INDIR_OFF : std_logic_vector(1 downto 0) := "10"; -- 2-word: regfile[RS] + next word
    constant AM_ILLEGAL   : std_logic_vector(1 downto 0) := "11"; -- illegal → fault

    -- BRANCH_COND encodings
    constant BR_NEVER     : std_logic_vector(3 downto 0) := "0000";
    constant BR_ALWAYS    : std_logic_vector(3 downto 0) := "0001";
    constant BR_Z         : std_logic_vector(3 downto 0) := "0010";
    constant BR_NZ        : std_logic_vector(3 downto 0) := "0011";
    constant BR_C         : std_logic_vector(3 downto 0) := "0100";
    constant BR_NC        : std_logic_vector(3 downto 0) := "0101";
    constant BR_A         : std_logic_vector(3 downto 0) := "0110"; -- C=0 AND Z=0
    constant BR_B         : std_logic_vector(3 downto 0) := "0111"; -- C=1
    constant BR_AE        : std_logic_vector(3 downto 0) := "1000"; -- C=0
    constant BR_BE        : std_logic_vector(3 downto 0) := "1001"; -- C=1 OR Z=1

    -- SP_OP encodings
    constant SP_NONE      : std_logic_vector(2 downto 0) := "000";
    constant SP_PUSH      : std_logic_vector(2 downto 0) := "001"; -- RSP-1 then write
    constant SP_POP       : std_logic_vector(2 downto 0) := "010"; -- read then RSP+1
    constant SP_INC       : std_logic_vector(2 downto 0) := "011";
    constant SP_DEC       : std_logic_vector(2 downto 0) := "100";

    -- MEM_SRC encodings
    constant MS_RS        : std_logic_vector(1 downto 0) := "00";
    constant MS_SP        : std_logic_vector(1 downto 0) := "01";
    constant MS_PC        : std_logic_vector(1 downto 0) := "10";
    constant MS_IMM       : std_logic_vector(1 downto 0) := "11";

    -- WIDTH encodings — must match inst[3:2] encoding used by WIDTH_FROM_INST path:
    --   "00" = 16-bit (default — zero bits in inst means normal word op)
    --   "01" = 8-bit low byte  (RL suffix)
    --   "10" = 8-bit high byte (RH suffix)
    --   "11" = 32-bit pair     (ER suffix)
    -- The CW WIDTH field uses these same encodings for fixed-width ops (WIDTH_FROM_INST=0).
    constant W16          : std_logic_vector(1 downto 0) := "00"; -- default
    constant W8L          : std_logic_vector(1 downto 0) := "01"; -- low byte
    constant W8H          : std_logic_vector(1 downto 0) := "10"; -- high byte
    constant W32          : std_logic_vector(1 downto 0) := "11"; -- 32-bit ER pair

    -- Convenience: build a 32-bit CW word from named fields
    -- All unmentioned bits default to zero (safe/NOP for every field)
    function make_cw (
        alu_op          : std_logic_vector(3 downto 0) := ALU_NOP;
        src_b           : std_logic_vector(2 downto 0) := SB_RS;
        reg_we          : std_logic                    := '0';
        rd_from_inst    : std_logic                    := '0';
        wb_src          : std_logic_vector(2 downto 0) := WB_ALU;
        width_from_inst : std_logic                    := '0'; -- 1=inst[3:2] selects width
        width           : std_logic_vector(1 downto 0) := W16; -- used when width_from_inst=0
        mem_rd          : std_logic                    := '0';
        mem_wr          : std_logic                    := '0';
        mem_width       : std_logic                    := '1'; -- default word
        mem_src         : std_logic_vector(1 downto 0) := MS_RS;
        pc_src          : std_logic_vector(2 downto 0) := PC_SEQ;
        branch_cond     : std_logic_vector(3 downto 0) := BR_NEVER;
        sp_op           : std_logic_vector(2 downto 0) := SP_NONE;
        priv_check      : std_logic                    := '0';
        last_step       : std_logic                    := '1'
    ) return std_logic_vector is
        variable cw : std_logic_vector(31 downto 0) := (others => '0');
    begin
        cw(31 downto 28) := alu_op;
        cw(27 downto 25) := src_b;
        cw(24)           := reg_we;
        cw(23)           := rd_from_inst;
        cw(22 downto 20) := wb_src;
        cw(19)           := width_from_inst;
        cw(18 downto 17) := width;
        cw(16)           := mem_rd;
        cw(15)           := mem_wr;
        cw(14)           := mem_width;
        cw(13 downto 12) := mem_src;
        cw(11 downto 9)  := pc_src;
        cw(8  downto 5)  := branch_cond;
        cw(4  downto 2)  := sp_op;
        cw(1)            := priv_check;
        cw(0)            := last_step;
        return cw;
    end function;

    -- NOP control word (used for bubbles and undefined opcodes)
    constant CW_NOP : std_logic_vector(31 downto 0) :=
        make_cw(alu_op => ALU_NOP, last_step => '1');

    -- Opcode assignments (6-bit, matches spec section 8)
    -- Arithmetic/Logic  0x00–0x0F
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
    constant OP_PASSA    : integer := 13;
    constant OP_PASSB    : integer := 14;
    constant OP_NOP      : integer := 15;
    -- Memory            0x10–0x17
    constant OP_LD       : integer := 16;
    constant OP_ST       : integer := 17;
    constant OP_LDB      : integer := 18;
    constant OP_STB      : integer := 19;
    constant OP_PUSH     : integer := 20;
    constant OP_POP      : integer := 21;
    constant OP_PEEK     : integer := 22;
    constant OP_FLUSH    : integer := 23;
    -- Control flow      0x18–0x2F
    constant OP_JMP      : integer := 24;
    constant OP_JZ       : integer := 25;
    constant OP_JNZ      : integer := 26;
    constant OP_JC       : integer := 27;
    constant OP_JNC      : integer := 28;
    constant OP_JA       : integer := 29;
    constant OP_JB       : integer := 30;
    constant OP_JAE      : integer := 31;
    constant OP_JBE      : integer := 32;
    constant OP_CALL     : integer := 33;
    constant OP_RET      : integer := 34;
    constant OP_IRET     : integer := 35;
    constant OP_INT      : integer := 36;
    constant OP_HLT      : integer := 37;
    -- System            0x30–0x39
    constant OP_ENIRQ    : integer := 48;
    constant OP_DISIRQ   : integer := 49;
    constant OP_SETMODE  : integer := 50;
    constant OP_GETMODE  : integer := 51;
    constant OP_WRITERIC : integer := 52;
    constant OP_READRIC  : integer := 53;
    constant OP_READRIV  : integer := 54;  -- R0 ← RIV[RS]
    constant OP_WRITERIV : integer := 55;  -- RIV[RS] ← RD
    constant OP_HALT     : integer := 57;

    -- -----------------------------------------------------------------------
    -- CW ROM initialisation
    -- Step 0 of every opcode is at index opcode*8+0,
    -- step N at opcode*8+N.
    -- -----------------------------------------------------------------------
    function init_cw_rom return cw_rom_t is
        variable r : cw_rom_t := (others => CW_NOP);
        variable base : integer;
    begin
        -- Helper: base index for an opcode
        -- base = opcode * 8

        -- -------------------------------------------------------------------
        -- NOP  (opcode 15)
        -- -------------------------------------------------------------------
        base := OP_NOP * 8;
        r(base) := make_cw(alu_op => ALU_NOP, last_step => '1');

        -- -------------------------------------------------------------------
        -- ADD  R0 ← R0 + RS
        -- -------------------------------------------------------------------
        base := OP_ADD * 8;
        r(base) := make_cw(
            alu_op => ALU_ADD, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- SUB  R0 ← R0 - RS
        -- -------------------------------------------------------------------
        base := OP_SUB * 8;
        r(base) := make_cw(
            alu_op => ALU_SUB, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- AND  R0 ← R0 AND RS
        -- -------------------------------------------------------------------
        base := OP_AND * 8;
        r(base) := make_cw(
            alu_op => ALU_AND, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- OR   R0 ← R0 OR RS
        -- -------------------------------------------------------------------
        base := OP_OR * 8;
        r(base) := make_cw(
            alu_op => ALU_OR, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- XOR  R0 ← R0 XOR RS
        -- -------------------------------------------------------------------
        base := OP_XOR * 8;
        r(base) := make_cw(
            alu_op => ALU_XOR, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- NOT  R0 ← NOT R0
        -- -------------------------------------------------------------------
        base := OP_NOT * 8;
        r(base) := make_cw(
            alu_op => ALU_NOT,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- SHL  R0 ← R0 << 1
        -- -------------------------------------------------------------------
        base := OP_SHL * 8;
        r(base) := make_cw(
            alu_op => ALU_SHL,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- SHR  R0 ← R0 >> 1
        -- -------------------------------------------------------------------
        base := OP_SHR * 8;
        r(base) := make_cw(
            alu_op => ALU_SHR,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- INC  R0 ← R0 + 1
        -- -------------------------------------------------------------------
        base := OP_INC * 8;
        r(base) := make_cw(
            alu_op => ALU_INC,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- DEC  R0 ← R0 - 1
        -- -------------------------------------------------------------------
        base := OP_DEC * 8;
        r(base) := make_cw(
            alu_op => ALU_DEC,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- CMP  flags ← R0 - RS  (no writeback)
        -- -------------------------------------------------------------------
        base := OP_CMP * 8;
        r(base) := make_cw(
            alu_op => ALU_CMP, src_b => SB_RS,
            reg_we => '0',
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- MOV  RD ← RS
        -- -------------------------------------------------------------------
        base := OP_MOV * 8;
        r(base) := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            reg_we => '1', rd_from_inst => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- LOADIMM  RD ← next_instruction_word  (2-step, variable destination)
        --
        -- The instruction word immediately following the LOADIMM opcode in
        -- the instruction stream IS the 16-bit immediate value.  The pipeline
        -- has already fetched it into fd_instr by the time LOADIMM is in
        -- EXECUTE (step 0).
        --
        -- Step 0 (LAST_STEP=0):
        --   The FETCH stage is suppressed whenever micro_step /= 0, so
        --   fd_instr is stable and holds the immediate word.
        --   The clocked process captures fd_instr → imm_word and increments
        --   rpc past the immediate (consuming it from the stream).
        --   REG_WE=0 — no writeback yet.
        --
        -- Step 1 (LAST_STEP=1):
        --   WB_IMM_WORD writes imm_word → regfile[RD].
        --   Normal fetch resumes.
        -- -------------------------------------------------------------------
        base := OP_LOADIMM * 8;
        r(base)   := make_cw(                                   -- step 0: capture
            reg_we => '0',
            last_step => '0');
        r(base+1) := make_cw(                                   -- step 1: writeback
            reg_we => '1', rd_from_inst => '1',
            wb_src => WB_IMM_WORD,
            last_step => '1');

        -- -------------------------------------------------------------------
        -- PASSA  R0 ← RD  (identity through A path)
        -- -------------------------------------------------------------------
        base := OP_PASSA * 8;
        r(base) := make_cw(
            alu_op => ALU_PASSA,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- PASSB  R0 ← RS
        -- -------------------------------------------------------------------
        base := OP_PASSB * 8;
        r(base) := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            reg_we => '1', wb_src => WB_ALU,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- LD   RD ← mem[RS]   (2 steps: issue read, then writeback)
        -- Step 0: present address, assert MEM_RD, no writeback yet
        -- Step 1: capture mem data into RD, LAST_STEP
        -- -------------------------------------------------------------------
        base := OP_LD * 8;
        r(base)   := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            mem_rd => '1', mem_width => '1',
            width_from_inst => '1',
            last_step => '0');
        r(base+1) := make_cw(
            reg_we => '1', rd_from_inst => '1', wb_src => WB_MEM,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- ST   mem[RD] ← RS
        -- -------------------------------------------------------------------
        base := OP_ST * 8;
        r(base) := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            mem_wr => '1', mem_width => '1', mem_src => MS_RS,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- LDB  RD ← mem[RS]  (byte)
        -- Step 0: address + MEM_RD, Step 1: writeback
        -- -------------------------------------------------------------------
        base := OP_LDB * 8;
        r(base)   := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            mem_rd => '1', mem_width => '0',
            width_from_inst => '1',
            last_step => '0');
        r(base+1) := make_cw(
            reg_we => '1', rd_from_inst => '1', wb_src => WB_MEM,
            width => W8L,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- STB  mem[RD] ← RS  (byte)
        -- -------------------------------------------------------------------
        base := OP_STB * 8;
        r(base) := make_cw(
            alu_op => ALU_PASSB, src_b => SB_RS,
            mem_wr => '1', mem_width => '0', mem_src => MS_RS,
            width => W8L,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- PUSH  mem[RSP-1] ← RS;  RSP ← RSP - 1
        -- Step 0: decrement SP and write memory
        -- -------------------------------------------------------------------
        base := OP_PUSH * 8;
        r(base) := make_cw(
            mem_wr => '1', mem_width => '1', mem_src => MS_RS,
            sp_op => SP_PUSH,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- POP   RD ← mem[RSP];  RSP ← RSP + 1
        -- Step 0: read memory at RSP
        -- Step 1: writeback to RD, increment RSP
        -- -------------------------------------------------------------------
        base := OP_POP * 8;
        r(base)   := make_cw(
            mem_rd => '1', mem_width => '1',
            width_from_inst => '1',
            last_step => '0');
        r(base+1) := make_cw(
            reg_we => '1', rd_from_inst => '1', wb_src => WB_MEM,
            sp_op => SP_POP,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- PEEK  RD ← mem[RSP]  (no SP change)
        -- -------------------------------------------------------------------
        base := OP_PEEK * 8;
        r(base)   := make_cw(
            mem_rd => '1', mem_width => '1',
            width_from_inst => '1',
            last_step => '0');
        r(base+1) := make_cw(
            reg_we => '1', rd_from_inst => '1', wb_src => WB_MEM,
            width_from_inst => '1',
            last_step => '1');

        -- -------------------------------------------------------------------
        -- JMP  — addressing mode in inst[3:2], condition in inst[1:0]
        -- Step 0 (LAST_STEP=0): freeze fetch, capture fd_instr → jmp_word.
        --   For AM_INDIRECT (inst[3:2]=01): the clocked process detects this,
        --   executes the jump immediately, and resets micro_step to 0 (1-word).
        --   For AM_DIRECT / AM_INDIR_OFF: step 1 executes.
        -- Step 1 (LAST_STEP=1): apply jump target from jmp_word.
        -- Same 2-step structure applies to all conditional jumps and CALL.
        -- -------------------------------------------------------------------
        base := OP_JMP * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_ALWAYS, last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_ALWAYS, last_step => '1');

        base := OP_JZ * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_Z,    last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_Z,    last_step => '1');

        base := OP_JNZ * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_NZ,   last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_NZ,   last_step => '1');

        base := OP_JC * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_C,    last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_C,    last_step => '1');

        base := OP_JNC * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_NC,   last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_NC,   last_step => '1');

        base := OP_JA * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_A,    last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_A,    last_step => '1');

        base := OP_JB * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_B,    last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_B,    last_step => '1');

        base := OP_JAE * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_AE,   last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_AE,   last_step => '1');

        base := OP_JBE * 8;
        r(base)   := make_cw(pc_src => PC_JUMP, branch_cond => BR_BE,   last_step => '0');
        r(base+1) := make_cw(pc_src => PC_JUMP, branch_cond => BR_BE,   last_step => '1');

        -- -------------------------------------------------------------------
        -- CALL  push RPC; then jump (same addressing modes as JMP)
        -- Step 0: push current PC onto stack AND capture fd_instr → jmp_word.
        --   For AM_INDIRECT: execute jump immediately (1-word).
        --   For AM_DIRECT / AM_INDIR_OFF: continue to step 1.
        -- Step 1: apply jump target.
        -- -------------------------------------------------------------------
        base := OP_CALL * 8;
        r(base)   := make_cw(
            mem_wr => '1', mem_width => '1', mem_src => MS_PC,
            sp_op => SP_PUSH,
            pc_src => PC_JUMP, branch_cond => BR_ALWAYS,
            last_step => '0');
        r(base+1) := make_cw(
            pc_src => PC_JUMP, branch_cond => BR_ALWAYS,
            last_step => '1');

        -- -------------------------------------------------------------------
        -- RET  RPC ← pop()
        -- Step 0: read mem[RSP]
        -- Step 1: RPC ← mem data, RSP++
        -- -------------------------------------------------------------------
        base := OP_RET * 8;
        r(base)   := make_cw(
            mem_rd => '1', mem_width => '1',
            last_step => '0');
        r(base+1) := make_cw(
            pc_src => PC_RET, sp_op => SP_POP,
            last_step => '1');

        -- -------------------------------------------------------------------
        -- IRET  RPC ← RIP; RM.MODE ← PREV_MODE; GIE ← 1
        -- Step 0: restore PC from RIP
        -- Step 1: restore mode
        -- Step 2: re-enable GIE, LAST_STEP
        -- (GIE restoration is handled combinationally off PC_IRET in step 2)
        -- -------------------------------------------------------------------
        base := OP_IRET * 8;
        r(base)   := make_cw(pc_src => PC_IRET,  last_step => '0', priv_check => '1');
        r(base+1) := make_cw(                     last_step => '0', priv_check => '1');
        r(base+2) := make_cw(                     last_step => '1', priv_check => '1');

        -- -------------------------------------------------------------------
        -- INT  software trap → vector 4
        -- (interrupt entry is handled by the interrupt controller logic,
        --  the CW just signals a NOP so the micro-sequencer stalls one cycle
        --  while hardware asserts vector 4 into the interrupt path)
        -- -------------------------------------------------------------------
        base := OP_INT * 8;
        r(base) := make_cw(last_step => '1');

        -- -------------------------------------------------------------------
        -- HLT  spin forever — PC stalls, pipeline loops on this instruction
        -- -------------------------------------------------------------------
        base := OP_HLT * 8;
        r(base) := make_cw(pc_src => PC_STALL, last_step => '1');

        -- -------------------------------------------------------------------
        -- System instructions (all kernel-only)
        -- -------------------------------------------------------------------

        -- ENABLE_IRQ  GIE ← 1  (handled via special decode of pc_src/priv_check)
        base := OP_ENIRQ * 8;
        r(base) := make_cw(priv_check => '1', last_step => '1');

        -- DISABLE_IRQ  GIE ← 0
        base := OP_DISIRQ * 8;
        r(base) := make_cw(priv_check => '1', last_step => '1');

        -- GETMODE  R0 ← RM
        base := OP_GETMODE * 8;
        r(base) := make_cw(
            reg_we => '1', wb_src => WB_SPEC,
            priv_check => '1', last_step => '1');

        -- READRIC  R0 ← RIC
        base := OP_READRIC * 8;
        r(base) := make_cw(
            reg_we => '1', wb_src => WB_SPEC,
            priv_check => '1', last_step => '1');

        -- WRITERIC  RIC ← RS
        base := OP_WRITERIC * 8;
        r(base) := make_cw(priv_check => '1', last_step => '1');

        -- READRIV  R0 ← RIV[RS[2:0]]
        base := OP_READRIV * 8;
        r(base) := make_cw(
            reg_we => '1', wb_src => WB_SPEC,
            priv_check => '1', last_step => '1');

        -- WRITERIV  RIV[RS[2:0]] ← RD  (side-effect only, no CW writeback needed)
        base := OP_WRITERIV * 8;
        r(base) := make_cw(priv_check => '1', last_step => '1');

        -- HALT (alias for HLT)
        base := OP_HALT * 8;
        r(base) := make_cw(pc_src => PC_STALL, last_step => '1');

        return r;
    end function;

    constant CW_ROM : cw_rom_t := init_cw_rom;

    -- -----------------------------------------------------------------------
    -- Register file  (R0–R7, 16-bit each)
    -- -----------------------------------------------------------------------
    type regfile_t is array (0 to 7) of std_logic_vector(15 downto 0);
    signal regfile : regfile_t := (others => (others => '0'));

    -- -----------------------------------------------------------------------
    -- Special registers
    -- -----------------------------------------------------------------------
    signal rpc      : std_logic_vector(15 downto 0) := x"0000"; -- program counter
    signal rsp      : std_logic_vector(15 downto 0) := x"BFFE"; -- stack pointer (top of RAM0)
    signal rip      : std_logic_vector(15 downto 0) := (others => '0'); -- interrupt return
    signal rrp      : std_logic_vector(15 downto 0) := (others => '0'); -- return pointer

    signal rm_mode      : std_logic := '1'; -- boot in kernel
    signal rm_prev_mode : std_logic := '0';

    -- RIC
    signal ric_gie     : std_logic                    := '0'; -- global interrupt enable
    signal ric_enable  : std_logic_vector(7 downto 0) := (others => '0');
    signal ric_pending : std_logic_vector(7 downto 0) := (others => '0');

    -- Interrupt vector registers
    type rivfile_t is array (0 to 7) of std_logic_vector(15 downto 0);
    signal riv : rivfile_t := (others => (others => '0'));

    -- Exception context registers XR0–XR7
    type xrfile_t is array (0 to 7) of std_logic_vector(15 downto 0);
    signal xr : xrfile_t := (others => (others => '0'));

    -- Flags
    signal flag_z : std_logic := '0'; -- zero
    signal flag_c : std_logic := '0'; -- carry
    signal flag_n : std_logic := '0'; -- negative
    signal flag_v : std_logic := '0'; -- overflow

    -- -----------------------------------------------------------------------
    -- Pipeline registers
    -- -----------------------------------------------------------------------

    -- FETCH → DECODE
    signal fd_instr  : std_logic_vector(15 downto 0) := (others => '0');
    signal fd_pc     : std_logic_vector(15 downto 0) := (others => '0');
    signal fd_valid  : std_logic := '0'; -- '0' = bubble

    -- DECODE → EXECUTE (registered CW and decoded fields)
    signal de_cw         : std_logic_vector(31 downto 0) := CW_NOP;
    signal de_instr      : std_logic_vector(15 downto 0) := (others => '0');
    signal de_pc         : std_logic_vector(15 downto 0) := (others => '0');
    signal de_valid      : std_logic := '0';
    signal de_rs_val     : std_logic_vector(15 downto 0) := (others => '0');
    signal de_rd_val     : std_logic_vector(15 downto 0) := (others => '0');

    -- -----------------------------------------------------------------------
    -- Micro-sequencer
    -- -----------------------------------------------------------------------
    signal micro_step : unsigned(2 downto 0) := (others => '0');

    -- -----------------------------------------------------------------------
    -- Interrupt controller signals
    -- -----------------------------------------------------------------------
    signal int_pending_vec : integer range 0 to 7 := 0; -- winning vector (combinational)
    signal int_request     : std_logic := '0';           -- interrupt wants service
    signal int_entry       : std_logic := '0';           -- currently in entry seq
    signal int_step        : unsigned(2 downto 0) := (others => '0');
    -- Latched pending vector: captured when int_entry is triggered so the
    -- entry state machine uses a stable vector even after the combinational
    -- ill_opcode / priv_fault / IRQ sources change during the flush.
    signal int_latched_vec : integer range 0 to 7 := 0;

    -- -----------------------------------------------------------------------
    -- Internal combinational wires
    -- -----------------------------------------------------------------------
    signal fetch_pc    : std_logic_vector(15 downto 0); -- address driven to ROM
    signal branch_taken: std_logic;
    signal alu_result  : std_logic_vector(31 downto 0);  -- 32-bit ALU result
    signal alu_carry   : std_logic;
    signal alu_zero    : std_logic;
    signal alu_neg     : std_logic;
    signal alu_ovf     : std_logic;
    signal wb_data     : std_logic_vector(15 downto 0);
    signal mem_addr    : std_logic_vector(15 downto 0);
    signal mem_wdata   : std_logic_vector(15 downto 0);

    -- Decoded CW fields from de_cw (wires, not registers)
    signal cw_alu_op          : std_logic_vector(3 downto 0);
    signal cw_src_b           : std_logic_vector(2 downto 0);
    signal cw_reg_we          : std_logic;
    signal cw_rd_from_inst    : std_logic;
    signal cw_wb_src          : std_logic_vector(2 downto 0);
    signal cw_width_from_inst : std_logic;           -- 1=read width from inst[3:2]
    signal cw_width           : std_logic_vector(1 downto 0);
    signal cw_mem_rd          : std_logic;
    signal cw_mem_wr          : std_logic;
    signal cw_mem_width       : std_logic;
    signal cw_mem_src         : std_logic_vector(1 downto 0);
    signal cw_pc_src          : std_logic_vector(2 downto 0);
    signal cw_branch_cond     : std_logic_vector(3 downto 0);
    signal cw_sp_op           : std_logic_vector(2 downto 0);
    signal cw_priv_check      : std_logic;
    signal cw_last_step       : std_logic;

    -- Effective width and half-select, resolved from CW or instruction bits
    signal eff_width    : std_logic_vector(1 downto 0); -- actual operative width
    signal eff_half_sel : std_logic;                     -- 0=low byte, 1=high byte (W8 only)

    -- Instruction fields from de_instr
    signal instr_opcode : std_logic_vector(5 downto 0);
    signal instr_rd     : std_logic_vector(2 downto 0);
    signal instr_rs     : std_logic_vector(2 downto 0);
    signal instr_imm    : std_logic_vector(3 downto 0);
    signal instr_cond   : std_logic_vector(1 downto 0); -- inst[1:0] condition field
    signal instr_am     : std_logic_vector(1 downto 0); -- inst[3:2] addressing mode (jumps)

    -- Condition met: '1' when the instruction's condition is satisfied
    -- When '0' in EXECUTE the instruction is treated as a NOP
    signal cond_met     : std_logic;

    -- Destination register index (R0 or inst[RD])
    signal wb_rd_idx : integer range 0 to 7;

    -- ALU operands (32-bit wide to support ER pair operations)
    signal alu_a : std_logic_vector(31 downto 0);
    signal alu_b : std_logic_vector(31 downto 0);

    -- Privilege fault and illegal opcode signals
    signal priv_fault : std_logic;
    signal ill_opcode : std_logic; -- set in DECODE, consumed by priority encoder

    -- Captured immediate word for LOADIMM (latched in step 0, used in step 1)
    signal imm_word   : std_logic_vector(15 downto 0) := (others => '0');

    -- Captured next-word for direct/indirect+offset jumps (latched in step 0)
    signal jmp_word   : std_logic_vector(15 downto 0) := (others => '0');

begin

    -- -----------------------------------------------------------------------
    -- Decode CW fields (pure wires)
    -- -----------------------------------------------------------------------
    cw_alu_op          <= de_cw(F_ALU_OP_H        downto F_ALU_OP_L);
    cw_src_b           <= de_cw(F_SRC_B_H         downto F_SRC_B_L);
    cw_reg_we          <= de_cw(F_REG_WE);
    cw_rd_from_inst    <= de_cw(F_RD_FROM_INST);
    cw_wb_src          <= de_cw(F_WB_SRC_H        downto F_WB_SRC_L);
    cw_width_from_inst <= de_cw(F_WIDTH_FROM_INST);
    cw_width           <= de_cw(F_WIDTH_H          downto F_WIDTH_L);
    cw_mem_rd          <= de_cw(F_MEM_RD);
    cw_mem_wr          <= de_cw(F_MEM_WR);
    cw_mem_width       <= de_cw(F_MEM_WIDTH);
    cw_mem_src         <= de_cw(F_MEM_SRC_H       downto F_MEM_SRC_L);
    cw_pc_src          <= de_cw(F_PC_SRC_H        downto F_PC_SRC_L);
    cw_branch_cond     <= de_cw(F_BRANCH_H        downto F_BRANCH_L);
    cw_sp_op           <= de_cw(F_SP_OP_H         downto F_SP_OP_L);
    cw_priv_check      <= de_cw(F_PRIV_CHECK);
    cw_last_step       <= de_cw(F_LAST_STEP);

    -- Effective width: from instruction bits [3:2] when WIDTH_FROM_INST=1,
    -- otherwise from the CW WIDTH field (used by fixed-width ops like LOADIMM).
    -- inst[3:2] encoding: 00=W16, 01=W8-low, 10=W8-high, 11=W32
    eff_width    <= de_instr(3 downto 2) when cw_width_from_inst = '1'
                    else cw_width;
    -- eff_half_sel: which byte lane for W8 ops (inst[2] when WIDTH_FROM_INST,
    -- else fixed '0' for low byte — W8-high is inst[3:2]="10" i.e. inst[2]='1').
    eff_half_sel <= de_instr(2) when cw_width_from_inst = '1' else '0';

    -- Instruction field decode
    instr_opcode <= de_instr(15 downto 10);
    instr_rd     <= de_instr(9  downto 7);
    instr_rs     <= de_instr(6  downto 4);
    instr_imm    <= de_instr(3  downto 0);
    instr_cond   <= de_instr(1  downto 0);  -- condition (always, Z, C, N)
    instr_am     <= de_instr(3  downto 2);  -- addressing mode for jump/call (00=direct,01=indirect,10=indir+off,11=illegal)

    -- Condition evaluation (combinational, from current flag state)
    -- 00=always, 01=Z, 10=C, 11=N
    with instr_cond select cond_met <=
        '1'    when "00",   -- always
        flag_z when "01",   -- Z=1
        flag_c when "10",   -- C=1
        flag_n when "11",   -- N=1
        '1'    when others;

    -- Writeback destination index
    wb_rd_idx <= to_integer(unsigned(instr_rd)) when cw_rd_from_inst = '1' else 0;

    -- -----------------------------------------------------------------------
    -- ALU operand mux (32-bit)
    -- W32: concatenate regfile[RD+1]:regfile[RD] (even-indexed pair = ER)
    -- W8:  zero-extend the selected byte lane of the register
    -- W16: zero-extend to 32 bits for uniform ALU processing
    -- -----------------------------------------------------------------------
    process(eff_width, eff_half_sel, instr_rd, instr_rs, instr_imm,
            regfile, ddata_r, rsp, de_pc, cw_src_b)
        variable rd_idx  : integer range 0 to 7;
        variable rs_idx  : integer range 0 to 7;
        variable rd_pair : integer range 0 to 7;  -- upper half of ER pair
        variable a16     : std_logic_vector(15 downto 0);
        variable b16     : std_logic_vector(15 downto 0);
    begin
        rd_idx  := to_integer(unsigned(instr_rd));
        rs_idx  := to_integer(unsigned(instr_rs));
        rd_pair := rd_idx + 1;  -- always even+1; assembler enforces even RD for W32

        case eff_width is
            when W32 =>
                -- ER pair: {regfile[RD+1], regfile[RD]}
                alu_a <= regfile(rd_pair) & regfile(rd_idx);
            when W8L | W8H =>
                -- selected byte lane, zero-extended to 32 bits
                if eff_half_sel = '1' then
                    alu_a <= x"000000" & regfile(rd_idx)(15 downto 8);
                else
                    alu_a <= x"000000" & regfile(rd_idx)(7  downto 0);
                end if;
            when others =>  -- W16
                alu_a <= x"0000" & regfile(rd_idx);
        end case;

        -- SRC_B mux — always 16-bit sources, zero-extended to 32
        case cw_src_b is
            when SB_RS  => b16 := regfile(rs_idx);
            when SB_IMM => b16 := x"000" & instr_imm;
            when SB_MEM => b16 := ddata_r;
            when SB_SP  => b16 := rsp;
            when SB_PC  => b16 := de_pc;
            when others => b16 := (others => '0');
        end case;

        case eff_width is
            when W32 =>
                -- For W32, RS points to the partner pair: {regfile[RS+1], regfile[RS]}
                alu_b <= regfile(rs_idx + 1) & regfile(rs_idx);
            when W8L | W8H =>
                if eff_half_sel = '1' then
                    alu_b <= x"000000" & b16(15 downto 8);
                else
                    alu_b <= x"000000" & b16(7  downto 0);
                end if;
            when others =>
                alu_b <= x"0000" & b16;
        end case;
    end process;

    -- -----------------------------------------------------------------------
    -- ALU (32-bit)
    -- Operates uniformly on 32-bit operands. For W8/W16 the upper bits are
    -- zero, so results and flags are naturally correct for those widths.
    -- -----------------------------------------------------------------------
    process(cw_alu_op, alu_a, alu_b, eff_width)
        variable sum33 : unsigned(32 downto 0);
        variable sub33 : unsigned(32 downto 0);
        variable r     : std_logic_vector(31 downto 0);
        variable c_out : std_logic;
        variable v_out : std_logic;
        variable msb   : integer;  -- MSB index for sign/overflow calculation
    begin
        r     := (others => '0');
        c_out := '0';
        v_out := '0';

        -- Determine the active MSB based on width for flag correctness
        case eff_width is
            when W8L | W8H => msb := 7;
            when W32   => msb := 31;
            when others => msb := 15;  -- W16 default
        end case;

        case cw_alu_op is
            when ALU_ADD =>
                sum33 := ('0' & unsigned(alu_a)) + ('0' & unsigned(alu_b));
                r     := std_logic_vector(sum33(31 downto 0));
                c_out := sum33(32);
                v_out := (alu_a(msb) xnor alu_b(msb)) and (alu_a(msb) xor r(msb));
            when ALU_SUB | ALU_CMP =>
                sub33 := ('0' & unsigned(alu_a)) - ('0' & unsigned(alu_b));
                r     := std_logic_vector(sub33(31 downto 0));
                c_out := sub33(32);
                v_out := (alu_a(msb) xor alu_b(msb)) and (alu_a(msb) xor r(msb));
            when ALU_AND  => r := alu_a and alu_b;
            when ALU_OR   => r := alu_a or  alu_b;
            when ALU_XOR  => r := alu_a xor alu_b;
            when ALU_NOT  => r := not alu_a;
            when ALU_SHL  =>
                r     := alu_a(30 downto 0) & '0';
                c_out := alu_a(msb);
            when ALU_SHR  =>
                r     := '0' & alu_a(31 downto 1);
                c_out := alu_a(0);
            when ALU_INC  =>
                sum33 := ('0' & unsigned(alu_a)) + 1;
                r     := std_logic_vector(sum33(31 downto 0));
                c_out := sum33(32);
            when ALU_DEC  =>
                sub33 := ('0' & unsigned(alu_a)) - 1;
                r     := std_logic_vector(sub33(31 downto 0));
                c_out := sub33(32);
            when ALU_PASSA => r := alu_a;
            when ALU_PASSB => r := alu_b;
            when others    => r := (others => '0');
        end case;

        alu_result <= r;
        alu_carry  <= c_out;
        -- Zero flag: check only the active width's bits
        case eff_width is
            when W8L | W8H => alu_zero <= '1' when r(7  downto 0) = x"00"         else '0';
            when W32   => alu_zero <= '1' when r                = x"00000000" else '0';
            when others => alu_zero <= '1' when r(15 downto 0) = x"0000"      else '0';
        end case;
        alu_neg    <= r(msb);
        alu_ovf    <= v_out;
    end process;

    -- -----------------------------------------------------------------------
    -- Branch condition evaluation
    -- -----------------------------------------------------------------------
    process(cw_branch_cond, flag_z, flag_c, flag_n, flag_v)
    begin
        case cw_branch_cond is
            when BR_NEVER  => branch_taken <= '0';
            when BR_ALWAYS => branch_taken <= '1';
            when BR_Z      => branch_taken <= flag_z;
            when BR_NZ     => branch_taken <= not flag_z;
            when BR_C      => branch_taken <= flag_c;
            when BR_NC     => branch_taken <= not flag_c;
            when BR_A      => branch_taken <= (not flag_c) and (not flag_z);
            when BR_B      => branch_taken <= flag_c;
            when BR_AE     => branch_taken <= not flag_c;
            when BR_BE     => branch_taken <= flag_c or flag_z;
            when others    => branch_taken <= '0';
        end case;
    end process;

    -- -----------------------------------------------------------------------
    -- Privilege check
    -- -----------------------------------------------------------------------
    priv_fault <= '1' when (cw_priv_check = '1' and rm_mode = '0' and de_valid = '1')
                  else '0';

    -- -----------------------------------------------------------------------
    -- Memory address mux
    -- PUSH writes to RSP-1 (pre-decrement semantics: decrement then write).
    -- POP and PEEK read from current RSP (post-increment for POP).
    -- All other memory ops use the RS register as the address pointer.
    -- -----------------------------------------------------------------------
    mem_addr <=
        std_logic_vector(unsigned(rsp) - 1)
            when cw_sp_op = SP_PUSH
        else rsp
            when (cw_sp_op = SP_POP or
                  to_integer(unsigned(instr_opcode)) = OP_PEEK or
                  to_integer(unsigned(instr_opcode)) = OP_POP  or
                  to_integer(unsigned(instr_opcode)) = OP_RET)
        else regfile(to_integer(unsigned(instr_rs)));

    with cw_mem_src select mem_wdata <=
        regfile(to_integer(unsigned(instr_rs)))        when MS_RS,
        rsp                                            when MS_SP,
        std_logic_vector(unsigned(de_pc) + 1)          when MS_PC,
        x"000" & instr_imm                             when MS_IMM,
        (others => '0')                                when others;

    -- Drive data bus outputs
    -- dwe and dbe are gated on cond_met so a condition-not-met store/load
    -- does not produce a real bus transaction.
    daddr   <= mem_addr;
    ddata_w <= mem_wdata;
    dwe     <= cw_mem_wr and de_valid and not priv_fault and cond_met;
    dbe     <= cw_mem_rd and de_valid and cond_met;
    -- Note: W32 memory ops are not directly supported in a single bus cycle
    -- (the data bus is 16-bit wide). The assembler must use two ST/LD word
    -- instructions for 32-bit memory transfers. eff_width=W32 only applies
    -- to register-to-register ALU operations.
    dwmask  <= "00" when cw_mem_width = '1'                   -- word: both bytes
               else "10" when eff_half_sel = '1'              -- high byte (W8H)
               else "01";                                      -- low byte (W8L)

    -- -----------------------------------------------------------------------
    -- Writeback data mux
    -- -----------------------------------------------------------------------
    process(cw_wb_src, alu_result, eff_width, eff_half_sel,
            ddata_r, instr_imm, de_pc, de_instr, imm_word,
            rsp, rm_mode, rm_prev_mode, ric_gie, ric_enable, ric_pending, riv)
        variable opcode_int : integer range 0 to 63;
    begin
        opcode_int := to_integer(unsigned(de_instr(15 downto 10)));
        case cw_wb_src is
            when WB_ALU  =>
                case eff_width is
                    when W8L | W8H =>
                        wb_data <= x"00" & alu_result(7 downto 0);
                    when others =>
                        wb_data <= alu_result(15 downto 0);
                end case;
            when WB_MEM      => wb_data <= ddata_r;
            when WB_IMM      => wb_data <= x"000" & instr_imm;
            when WB_PC1      => wb_data <= std_logic_vector(unsigned(de_pc) + 1);
            when WB_IMM_WORD => wb_data <= imm_word;   -- 16-bit immediate captured in step 0
            when WB_SPEC =>
                case opcode_int is
                    when OP_GETMODE  =>
                        wb_data <= "00000000000000" & rm_prev_mode & rm_mode;
                    when OP_READRIC  =>
                        wb_data <= ric_pending & ric_enable(7 downto 1) & ric_gie;
                    when OP_READRIV  =>
                        wb_data <= riv(to_integer(unsigned(de_instr(6 downto 4))));
                    when others      =>
                        wb_data <= rsp;
                end case;
            when others  => wb_data <= (others => '0');
        end case;
    end process;

    -- -----------------------------------------------------------------------
    -- Interrupt priority encoder
    -- Synchronous exceptions (4–7) beat async IRQs (0–3).
    -- Within each group: higher vector number = higher priority (7>6>5>4, 0>1>2>3).
    -- -----------------------------------------------------------------------
    process(irq, ric_enable, ric_pending, ric_gie, rm_mode, priv_fault, ill_opcode)
        variable req : std_logic := '0';
        variable vec : integer range 0 to 7 := 0;
    begin
        req := '0';
        vec := 0;

        -- NMI (7) — always fires regardless of GIE
        if ric_pending(7) = '1' then
            req := '1'; vec := 7;
        -- Privilege fault (6) — synchronous, generated by PRIV_CHECK in execute
        elsif priv_fault = '1' then
            req := '1'; vec := 6;
        -- Illegal opcode (5) — synchronous, detected in DECODE stage
        elsif ill_opcode = '1' then
            req := '1'; vec := 5;
        -- Software INT (4) — set by OP_INT side-effect, maskable via GIE
        elsif ric_pending(4) = '1' and ric_enable(4) = '1' and ric_gie = '1' then
            req := '1'; vec := 4;
        -- Hardware IRQs (0–3) — all gated by GIE, priority 0 > 1 > 2 > 3
        elsif ric_gie = '1' then
            if    irq(0) = '1' and ric_enable(0) = '1' then req := '1'; vec := 0;
            elsif irq(1) = '1' and ric_enable(1) = '1' then req := '1'; vec := 1;
            elsif irq(2) = '1' and ric_enable(2) = '1' then req := '1'; vec := 2;
            elsif irq(3) = '1' and ric_enable(3) = '1' then req := '1'; vec := 3;
            end if;
        end if;

        int_request     <= req;
        int_pending_vec <= vec;
    end process;

    -- -----------------------------------------------------------------------
    -- FETCH stage
    -- Present PC to instruction ROM (async read — data available same cycle)
    -- -----------------------------------------------------------------------
    iaddr    <= rpc;
    fetch_pc <= rpc; -- alias for clarity

    -- -----------------------------------------------------------------------
    -- Main clocked pipeline + execute
    -- -----------------------------------------------------------------------
    process(clk)
        variable flush          : std_logic;
        variable new_sp         : unsigned(15 downto 0);
        variable take_int       : std_logic;
        variable raw_stall      : std_logic;
        variable branch_taken_v : std_logic;

        variable ex_wr_idx : integer range 0 to 7;
        variable fd_rs_idx : integer range 0 to 7;
        variable fd_rd_idx : integer range 0 to 7;       
    begin
        if rising_edge(clk) then
            if clk_en = '1' then
               if reset = '1' then
                -- Reset state
                rpc            <= x"0000";
                rsp            <= x"BFFE";
                rip            <= (others => '0');
                rrp            <= (others => '0');
                rm_mode        <= '1';
                rm_prev_mode   <= '0';
                ric_gie        <= '0';
                ric_enable     <= (others => '0');
                ric_pending    <= (others => '0');
                regfile        <= (others => (others => '0'));
                riv            <= (others => (others => '0'));
                xr             <= (others => (others => '0'));
                flag_z         <= '0';
                flag_c         <= '0';
                flag_n         <= '0';
                flag_v         <= '0';
                fd_valid       <= '0';
                de_valid       <= '0';
                micro_step     <= (others => '0');
                int_entry      <= '0';
                int_step       <= (others => '0');
                int_latched_vec <= 0;
                imm_word       <= (others => '0');
                jmp_word       <= (others => '0');

            else
                flush     := '0';
                take_int  := '0';
                raw_stall := '0';

                -- ===========================================================
                -- EXECUTE stage
                -- Operates on de_* registered pipeline values.
                -- ===========================================================
                if de_valid = '1' then

                    -- -------------------------------------------------------
                    -- Privilege fault → redirect to interrupt entry
                    -- -------------------------------------------------------
                    if priv_fault = '1' then
                        take_int := '1';
                        -- vector 6 already selected by priority encoder
                    end if;

                    -- -------------------------------------------------------
                    -- Interrupt entry micro-sequence
                    -- -------------------------------------------------------
                    if int_entry = '1' then
                        case int_step is
                            when "000" =>
                                ric_gie             <= '0';         -- GIE off
                                -- Clear the pending bit for the vector being serviced
                                ric_pending(int_latched_vec) <= '0';
                            when "001" =>
                                rip          <= rpc;                                -- save PC
                            when "010" =>
                                rm_prev_mode <= rm_mode;                            -- save mode
                                rm_mode      <= '1';                                -- kernel
                            when "011" =>
                                xr(0)        <= de_pc;                              -- faulting PC
                                xr(1)        <= x"000" &
                                                std_logic_vector(
                                                    to_unsigned(int_latched_vec,4));
                                xr(2)        <= de_instr;                           -- faulting instr
                                xr(3)        <= mem_addr;                           -- faulting addr
                            when "100" =>
                                rpc          <= riv(int_latched_vec);               -- jump to handler
                                flush        := '1';
                                int_entry    <= '0';
                                int_step     <= (others => '0');
                            when others => null;
                        end case;

                        if int_entry = '1' and int_step /= "100" then
                            int_step <= int_step + 1;
                        end if;

                    else

                        -- ---------------------------------------------------------------------------                        -- Normal Instruction Execution:
                        -- Side effects are suppressed if 'cond_met' is false, but the micro-sequencer
                        -- continues to run until 'cw_last_step' is signaled. This ensures that 
                        -- multi-cycle/multi-word instructions always clear the pipeline stages 
                        -- before the next instruction is fetched, regardless of whether the 
                        -- operation was "skipped" by a condition.
                        -- ---------------------------------------------------------------------------
                        
                        if cw_last_step = '1' then
                            micro_step <= (others => '0');
                        else
                            micro_step <= micro_step + 1;
                        end if;

                        -- LOADIMM step 0: capture immediate word.
                        if to_integer(unsigned(instr_opcode)) = OP_LOADIMM
                           and micro_step = 0 then
                            imm_word <= fd_instr;
                            rpc      <= std_logic_vector(unsigned(rpc) + 1);
                        end if;

                        -- Jump step 0 for 2-word modes (AM_DIRECT / AM_INDIR_OFF):
                        -- capture the target/offset word and consume it from the stream.
                        -- This happens unconditionally regardless of cond_met —
                        -- a not-taken jump still must skip its target word so the
                        -- following instruction is fetched correctly.
                        if cw_pc_src = PC_JUMP and micro_step = 0
                           and instr_am /= AM_INDIRECT and instr_am /= AM_ILLEGAL then
                            jmp_word <= fd_instr;
                            rpc      <= std_logic_vector(unsigned(rpc) + 1);
                        end if;

                        -- For AM_INDIRECT and AM_ILLEGAL jumps, the sequence is
                        -- always 1 step regardless of cond_met. Override micro_step
                        -- here (outside cond_met) so a not-taken indirect jump
                        -- doesn't erroneously advance to step 1.
                        if cw_pc_src = PC_JUMP and micro_step = 0
                           and (instr_am = AM_INDIRECT or instr_am = AM_ILLEGAL) then
                            micro_step <= (others => '0');
                        end if;

                        if cond_met = '1' then

                        -- Flag update (all ALU ops except PASSA/PASSB/NOP)
                        if cw_alu_op /= ALU_NOP and cw_alu_op /= ALU_PASSA
                            and cw_alu_op /= ALU_PASSB then
                            flag_z <= alu_zero;
                            flag_c <= alu_carry;
                            flag_n <= alu_neg;
                            flag_v <= alu_ovf;
                        end if;

                        -- Register writeback
                        -- W16/default: write wb_data to destination register
                        -- W8:  merge only the selected byte lane; other byte unchanged
                        -- W32: write low word to regfile[RD], high word to regfile[RD+1]
                        if cw_reg_we = '1' then
                            case eff_width is
                                when W8L | W8H =>
                                    if eff_half_sel = '1' then
                                        -- High byte lane
                                        regfile(wb_rd_idx)(15 downto 8) <= wb_data(7 downto 0);
                                    else
                                        -- Low byte lane
                                        regfile(wb_rd_idx)(7 downto 0)  <= wb_data(7 downto 0);
                                    end if;
                                when W32 =>
                                    -- Low word to RD, high word to RD+1
                                    regfile(wb_rd_idx)     <= alu_result(15 downto 0);
                                    regfile(wb_rd_idx + 1) <= alu_result(31 downto 16);
                                when others =>  -- W16
                                    regfile(wb_rd_idx) <= wb_data;
                            end case;
                        end if;

                        -- Stack pointer update
                        new_sp := unsigned(rsp);
                        case cw_sp_op is
                            when SP_PUSH => new_sp := new_sp - 1;
                            when SP_POP  => new_sp := new_sp + 1;
                            when SP_INC  => new_sp := new_sp + 1;
                            when SP_DEC  => new_sp := new_sp - 1;
                            when others  => null;
                        end case;
                        rsp <= std_logic_vector(new_sp);

                        -- PC update
                        case cw_pc_src is
                            when PC_SEQ =>
                                null;

                            when PC_STALL =>
                                -- HLT: undo the rpc increment that fetch already did,
                                -- keeping the CPU pointed at the HLT instruction forever.
                                rpc <= de_pc;

                            when PC_JUMP =>
                                if micro_step = 0 then
                                    if instr_am = AM_INDIRECT then
                                        -- 1-word: execute jump now
                                        -- (micro_step already forced to 0 above)
                                        if branch_taken = '1' then
                                            rpc   <= regfile(to_integer(unsigned(instr_rs)));
                                            flush := '1';
                                        end if;
                                    -- AM_ILLEGAL: ill_opcode set below, no PC change
                                    -- 2-word: jmp_word captured above, step 1 executes next cycle
                                    end if;
                                else
                                    -- Step 1: apply target from captured jmp_word
                                    if branch_taken = '1' then
                                        if instr_am = AM_DIRECT then
                                            rpc <= jmp_word;
                                        else -- AM_INDIR_OFF
                                            rpc <= std_logic_vector(
                                                unsigned(regfile(to_integer(unsigned(instr_rs)))) +
                                                unsigned(jmp_word));
                                        end if;
                                        flush := '1';
                                    end if;
                                end if;

                            when PC_INT =>
                                rpc   <= riv(int_pending_vec);
                                flush := '1';
                            when PC_RET =>
                                rpc   <= ddata_r;
                                flush := '1';
                            when PC_IRET =>
                                rpc     <= rip;
                                rm_mode <= rm_prev_mode;
                                ric_gie <= '1';
                                flush   := '1';
                            when others => null;
                        end case;

                        -- System instruction side-effects
                        if de_valid = '1' and priv_fault = '0' then
                            case to_integer(unsigned(instr_opcode)) is
                                when OP_ENIRQ   => ric_gie <= '1';
                                when OP_DISIRQ  => ric_gie <= '0';
                                when OP_WRITERIC =>
                                    ric_enable(7 downto 1) <=
                                        regfile(to_integer(unsigned(instr_rs)))(7 downto 1);
                                    ric_gie <=
                                        regfile(to_integer(unsigned(instr_rs)))(0);
                                when OP_SETMODE =>
                                    rm_prev_mode <= de_rs_val(1);
                                    rm_mode      <= de_rs_val(0);
                                when OP_WRITERIV =>
                                    riv(to_integer(unsigned(instr_rs))) <=
                                        regfile(to_integer(unsigned(instr_rd)));
                                when OP_INT =>
                                    ric_pending(4) <= '1';
                                when others => null;
                            end case;
                            -- Jump with AM_ILLEGAL addressing mode → illegal opcode fault
                            if cw_pc_src = PC_JUMP and instr_am = AM_ILLEGAL then
                                ill_opcode <= '1';
                            end if;
                        end if;

                        end if; -- cond_met

                    end if; -- int_entry / normal

                    -- Check for pending interrupt at instruction boundary
                    if int_request = '1' and cw_last_step = '1' and int_entry = '0' then
                        int_entry       <= '1';
                        int_step        <= (others => '0');
                        -- Latch the winning vector NOW. ill_opcode/priv_fault
                        -- get cleared on the flush below, which would cause the
                        -- combinational int_pending_vec to collapse back to 0.
                        int_latched_vec <= int_pending_vec;
                        flush           := '1';
                    end if;

                end if; -- de_valid

                -- ===========================================================
                -- DECODE stage → latch into DE registers
                -- RAW hazard: if EXECUTE is writing a register that the
                -- incoming FD instruction reads, stall for one cycle:
                --   - inject bubble (NOP) into DE
                --   - hold FD frozen (suppress FETCH update below)
                --   - do NOT advance micro_step
                -- ===========================================================
                                   
                
                ex_wr_idx := wb_rd_idx;
                fd_rs_idx := to_integer(unsigned(fd_instr(6 downto 4)));
                fd_rd_idx := to_integer(unsigned(fd_instr(9 downto 7)));
                if de_valid = '1' and cw_reg_we = '1' and cond_met = '1'
                   and fd_valid = '1' and flush = '0'
                   and (fd_rs_idx = ex_wr_idx or fd_rd_idx = ex_wr_idx) then
                    raw_stall  :='1';
                    de_valid   <= '0';
                    de_cw      <= CW_NOP;
                    ill_opcode <= '0';
                elsif flush = '1' then
                    raw_stall  := '0';
                    de_valid   <= '0';
                    de_cw      <= CW_NOP;
                    ill_opcode <= '0';
                    -- Invalidate FD so the stale fd_instr isn't latched into DE
                    -- on the next cycle. FETCH will refill fd_instr from the
                    -- correct post-jump address on the cycle after the flush.
                    fd_valid   <= '0';
                else
                    raw_stall := '0';
                    
                    -- Advance DECODE to a new instruction ONLY when the current one finishes
                    if cw_last_step = '1' then
                        de_valid  <= fd_valid;
                        de_instr  <= fd_instr;
                        de_pc     <= fd_pc;
                        
                        -- ONLY decode the instruction if it is valid (not a bubble)
                        if fd_valid = '1' then
                            -- always fetch step 0 for new instruction
                            de_cw <= CW_ROM(to_integer(unsigned(fd_instr(15 downto 10))) * 8);
                            
                            if CW_ROM(to_integer(unsigned(fd_instr(15 downto 10))) * 8) = CW_NOP and to_integer(unsigned(fd_instr(15 downto 10))) /= OP_NOP then
                                ill_opcode <= '1';
                            else
                                ill_opcode <= '0';
                            end if;
                        else
                            -- It's a bubble: inject a NOP so we don't accidentally start a multi-step ghost sequence
                            de_cw <= CW_NOP;
                            ill_opcode <= '0';
                        end if;
                        
                    else
                        -- We are in the middle of a multi-step instruction!
                        -- Freeze de_valid, de_instr, and de_pc. Only advance the control word.
                        de_cw <= CW_ROM(to_integer(unsigned(de_instr(15 downto 10))) * 8 + to_integer(micro_step) + 1);
                    end if;

                end if;
                -- ===========================================================
                -- FETCH stage — latch instruction from async ROM into FD regs.
                -- Suppressed on flush (branch taken) or raw_stall (RAW hazard).
                -- On raw_stall rpc is NOT incremented so the same address is
                -- re-presented to the ROM next cycle when the stall clears.
                -- ===========================================================
                if flush = '0' and raw_stall = '0' and
                   (cw_last_step = '1' or 
                   (micro_step = 0 and to_integer(unsigned(de_instr(15 downto 10))) = OP_LOADIMM) or
                   (micro_step = 0 and cw_pc_src = PC_JUMP and instr_am /= AM_INDIRECT and instr_am /= AM_ILLEGAL)) then
                    
                    fd_instr <= idata;
                    fd_pc    <= rpc;
                    fd_valid <= '1';
                    
                    -- ONLY increment rpc if we didn't just perform a branch/jump in the EXECUTE stage above
                    if cw_pc_src /= PC_JUMP or branch_taken = '0' then
                        rpc <= std_logic_vector(unsigned(rpc) + 1);
                    end if;
                end if;
                end if; -- clk_en
            end if; -- rising_edge
        end if;
    end process;

    end architecture;