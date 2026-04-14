# 4328 CPU — Consolidated Architecture Specification

# v2.0 — Design-Complete Draft

------

## 1. Overview

The 4328 is a 16-bit NISC (Not Instruction Set Computer) CPU targeting FPGA implementation on the Basys 3 (Xilinx Artix-7). It uses a control-word ROM architecture where each opcode maps directly to one or more 32-bit control words that drive the datapath. The ISA is intentionally minimal, with complexity pushed into firmware rather than hardware.

**Key properties:**

- 16-bit data path, 16-bit address space
- 3-stage pipeline: FETCH → DECODE → EXECUTE
- NISC: control word ROM replaces traditional decode logic
- Micro-sequencer for multi-cycle instructions (up to 8 steps per opcode)
- Hardware interrupt support with privilege separation
- Memory-mapped I/O

------

## 2. Memory Map

| Range         | Size | Region      | Notes                         |
| ------------- | ---- | ----------- | ----------------------------- |
| 0x0000–0x0FFF | 4K   | ROM         | Instruction fetch + boot code |
| 0x4000–0x4FFF | 4K   | Peripherals | Memory-mapped I/O             |
| 0x8000–0x8FFF | 4K   | RAM bank 0  | General purpose               |
| 0xC000–0xCFFF | 4K   | RAM bank 1  | General purpose               |

ROM is writable after boot (for self-modifying firmware). Peripheral address decode uses bits [15:14]. ROM uses combinational (async) reads for zero-latency instruction fetch. Both RAM banks use synchronous BRAM reads.

------

## 3. Register File

### 3.1 General Purpose Registers (GPRs)

8 physical 16-bit registers, 3-bit index.

| Index | Name | Notes                                                        |
| ----- | ---- | ------------------------------------------------------------ |
| 000   | R0   | **Accumulator** — implicit write destination for all ALU ops |
| 001   | R1   | General purpose                                              |
| 010   | R2   | General purpose                                              |
| 011   | R3   | General purpose                                              |
| 100   | R4   | General purpose                                              |
| 101   | R5   | General purpose                                              |
| 110   | R6   | General purpose                                              |
| 111   | R7   | General purpose                                              |

R0 is the hardwired ALU result destination. All arithmetic and logic operations write to R0 implicitly. Explicit destination selection (RD_FROM_INST=1 in CW) applies only to data-movement instructions (MOV, LD, POP, etc.).

### 3.2 Derived Register Views (Assembler Only)

No additional hardware cost. The assembler resolves these to a parent register index plus WIDTH and HALF_SEL fields in the control word.

| Name    | Parent | View             | CW encoding         |
| ------- | ------ | ---------------- | ------------------- |
| RL0–RL7 | R0–R7  | Low byte [7:0]   | WIDTH=8, HALF_SEL=0 |
| RH0–RH7 | R0–R7  | High byte [15:8] | WIDTH=8, HALF_SEL=1 |
| ER0     | R0:R1  | 32-bit pair      | WIDTH=32            |
| ER2     | R2:R3  | 32-bit pair      | WIDTH=32            |
| ER4     | R4:R5  | 32-bit pair      | WIDTH=32            |
| ER6     | R6:R7  | 32-bit pair      | WIDTH=32            |

Register pairs are always even-indexed. ER1, ER3, ER5, ER7 do not exist. WIDTH=32 implicitly selects the even-indexed register and its successor as a pair. The accumulator pair is ER0 (R0:R1).

### 3.3 Special Registers

#### RPC — Program Counter

- **Width:** 16-bit
- Holds address of currently executing instruction
- Advanced by fetch unit; written by jump/call/interrupt/return logic via PC_SRC CW field
- Not directly accessible by user-mode software

#### RSP — Stack Pointer

- **Width:** 16-bit
- Points to top of stack; grows **downward**
- PUSH: RSP ← RSP − 1, then write memory
- POP: read memory, then RSP ← RSP + 1
- Modified by SP_OP field in control word
- Accessible from user mode

#### RIP — Interrupt Return Pointer

- **Width:** 16-bit
- Set automatically on interrupt entry: RIP ← RPC
- Restored to RPC by IRET
- **Kernel-mode only**

#### RRP — Return Pointer

- **Width:** 16-bit
- Holds return address for CALL/RET (stack-based ABI; see Section 6.3)
- **Kernel-mode accessible**

#### RM — Mode Register

- **Width:** 2-bit

| Bit  | Name      | Description                                                  |
| ---- | --------- | ------------------------------------------------------------ |
| [0]  | MODE      | Current privilege. 0=user, 1=kernel                          |
| [1]  | PREV_MODE | Privilege prior to last interrupt. Saved/restored by interrupt entry/IRET |

Reset state: MODE=1 (boot in kernel mode), PREV_MODE=0. Writing RM from user mode triggers privilege fault (vector 6).

#### RIC — Interrupt Control Register

- **Width:** 16-bit
- **Kernel-mode only**

| Bits   | Name    | Description                                                  |
| ------ | ------- | ------------------------------------------------------------ |
| [0]    | GIE     | Global Interrupt Enable. Cleared on interrupt entry, restored by IRET. NMI ignores this bit. |
| [7:1]  | ENABLE  | Per-vector enable. Bit N enables vector N. NMI (vector 7) ignores its enable bit. |
| [15:8] | PENDING | Per-vector pending flags. Set when vector N fires, cleared by INT_ACK in CW. Read-only from software. |

#### RIV0–RIV7 — Interrupt Vector Registers

- **Width:** 16-bit each (8 registers)
- Each holds the jump target for the corresponding interrupt vector
- Must be initialised by boot firmware before enabling interrupts
- **Kernel-mode only**

#### XR0–XR7 — Exception Context Registers

- **Width:** 16-bit each (8 registers)
- Written automatically by hardware on interrupt entry (XR0–XR3)
- XR4–XR7 reserved / kernel scratch

| Register | Contents                                       |
| -------- | ---------------------------------------------- |
| XR0      | Faulting RPC (address of faulting instruction) |
| XR1      | Fault code (vector number, zero-extended)      |
| XR2      | Faulting instruction word                      |
| XR3      | Faulting memory address                        |
| XR4–XR7  | Reserved / kernel scratch                      |

**Kernel-mode only.**

#### D0–D7 — Debug Registers

- **Width:** 16-bit each (8 registers)
- No hardware-defined semantics; OS/debugger interprets them freely
- Suitable for breakpoint addresses, watchpoints, debug state flags
- **Kernel-mode only.** Writes from user mode are silently ignored.

### 3.4 Register Summary

| Register | Count | Width  | Kernel Only | HW Written             |
| -------- | ----- | ------ | ----------- | ---------------------- |
| R0–R7    | 8     | 16-bit | No          | No                     |
| RPC      | 1     | 16-bit | Implicit    | Yes                    |
| RSP      | 1     | 16-bit | No          | Partial (SP_OP)        |
| RIP      | 1     | 16-bit | Yes         | Yes (int entry)        |
| RRP      | 1     | 16-bit | Yes         | No                     |
| RM       | 1     | 2-bit  | Yes         | Yes (int entry)        |
| RIC      | 1     | 16-bit | Yes         | Partial (PENDING, GIE) |
| RIV0–7   | 8     | 16-bit | Yes         | No                     |
| XR0–7    | 8     | 16-bit | Yes         | Yes (XR0–XR3)          |
| D0–D7    | 8     | 16-bit | Yes         | No                     |

**Total physical registers:** 37 (plus zero-cost derived views)

------

## 4. Instruction Format

All instructions are 16-bit encoded.

```
[ OPCODE (6) ][ RD (3) ][ RS (3) ][ IMM/FLAGS (4) ]
```

- Opcode space: 64 entries (6 bits)
- 58 defined, 6 reserved
- RD: destination register index (used when RD_FROM_INST=1 in CW; otherwise implicit R0)
- RS: source register index
- IMM/FLAGS: 4-bit immediate or flag field; interpretation is opcode-dependent

------

## 5. Pipeline

### 5.1 Stages

3-stage pipeline:

```
FETCH → DECODE → EXECUTE
```

**FETCH:**

- Present RPC to instruction ROM (combinational/async read — zero latency)
- Increment RPC
- On a taken branch or jump: flush the instruction currently in FETCH (insert one bubble) and redirect RPC to the branch target. Cost: 1 cycle per taken branch.

**DECODE:**

- Extract opcode from fetched instruction
- Read CW ROM using {opcode, micro_step} index
- Read source registers from register file

**EXECUTE:**

- CW drives all datapath signals
- ALU computes result
- Memory read/write initiated
- Writeback to register file
- PC_SRC selected based on CW and branch condition evaluation
- Micro-step counter advances or resets

### 5.2 Hazard Strategy

**Branches / jumps:** Flush-on-taken. One bubble inserted on every taken branch or jump. No branch prediction. Not-taken branches cost zero cycles. This is the correct engineering tradeoff for a 3-stage pipeline — the penalty is 1 cycle, and a predictor would save exactly 1 cycle while adding significant complexity.

**Data hazards:** Register file reads occur in DECODE, writes occur at the end of EXECUTE. Back-to-back dependent instructions must be evaluated for RAW hazards based on exact read/write timing. If a hazard exists, a stall (bubble injection) is required. (To be confirmed during RTL implementation.)

**Memory latency:** Instruction ROM uses combinational reads — no fetch stall. Data RAM uses synchronous (1-cycle latency) reads — Option C overlap applies: during EXECUTE the next address is already presented to RAM so data is available at the start of the following cycle.

------

## 6. Control Word Architecture

### 6.1 CW ROM Dimensions

- **Index:** {opcode[5:0], micro_step[2:0]} = 9 bits → **512 entries**
- **Width:** 32 bits per entry
- **Total ROM size:** 512 × 32 = 16 Kbits (fits comfortably in one Artix-7 BRAM)

Most instructions use only step 0. Multi-cycle instructions (CALL, RET, interrupt entry) use steps 0–N with LAST_STEP=1 on the final step.

### 6.2 Control Word Field Layout (32 bits)

```
[31:28] ALU_OP       (4)  — ALU operation select
[27:25] SRC_B        (3)  — ALU B-input source
[24]    REG_WE       (1)  — Register file write enable
[23]    RD_FROM_INST (1)  — 0: write R0, 1: write inst[RD]
[22:20] WB_SRC       (3)  — Writeback source mux
[19]    HALF_SEL     (1)  — Byte half select (0=low, 1=high)
[18:17] WIDTH        (2)  — Operand width (00=8, 01=16, 10=32)
[16]    MEM_RD       (1)  — Memory read enable
[15]    MEM_WR       (1)  — Memory write enable
[14]    MEM_WIDTH    (1)  — Memory access width (0=byte, 1=word)
[13:12] MEM_SRC      (2)  — Memory write data source
[11:9]  PC_SRC       (3)  — PC update source
[8:5]   BRANCH_COND  (4)  — Branch condition select
[4:2]   SP_OP        (3)  — Stack pointer operation
[1]     PRIV_CHECK   (1)  — Fault if MODE=user
[0]     LAST_STEP    (1)  — Final micro-step for this instruction
```

Remaining system fields (INT_ACK, MODE_WR, GIE_CLR) are packed into spare encoding space within existing fields or handled as decoded combinational outputs. To be finalised during RTL.

### 6.3 Field Encodings

**ALU_OP [31:28]**

| Code | Operation  |
| ---- | ---------- |
| 0000 | ADD        |
| 0001 | SUB        |
| 0010 | AND        |
| 0011 | OR         |
| 0100 | XOR        |
| 0101 | NOT        |
| 0110 | SHL        |
| 0111 | SHR        |
| 1000 | INC        |
| 1001 | DEC        |
| 1010 | CMP        |
| 1011 | PASSA      |
| 1100 | PASSB      |
| 1101 | NOP        |
| 1110 | (reserved) |
| 1111 | (reserved) |

**SRC_B [27:25]**

| Code | Source                                    |
| ---- | ----------------------------------------- |
| 000  | RS (register file)                        |
| 001  | IMM (4-bit, zero-extended from inst[3:0]) |
| 010  | Memory read data                          |
| 011  | SP                                        |
| 100  | PC                                        |
| 101  | (reserved)                                |
| 110  | (reserved)                                |
| 111  | (reserved)                                |

SRC_A is always the RD register from the instruction (or R0 implicitly for ALU ops). No CW field needed.

**WB_SRC [22:20]**

| Code    | Source                    |
| ------- | ------------------------- |
| 000     | ALU result                |
| 001     | Memory read               |
| 010     | Immediate (zero-extended) |
| 011     | PC + 1                    |
| 100     | Special register read     |
| 101–111 | (reserved)                |

**WIDTH [18:17]**

| Code | Width      | Notes                         |
| ---- | ---------- | ----------------------------- |
| 00   | 8-bit      | Uses HALF_SEL for byte lane   |
| 01   | 16-bit     | Default                       |
| 10   | 32-bit     | Implies ER pair (R[n]:R[n+1]) |
| 11   | (reserved) |                               |

**PC_SRC [11:9]**

| Code    | Source                                                 |
| ------- | ------------------------------------------------------ |
| 000     | Sequential (RPC+1)                                     |
| 001     | Jump (absolute, from instruction immediate / register) |
| 010     | Branch (PC-relative, if BRANCH_COND met)               |
| 011     | Interrupt entry (RIV[n])                               |
| 100     | Return / RET (from stack)                              |
| 101     | IRET (from RIP)                                        |
| 110–111 | (reserved)                                             |

**BRANCH_COND [8:5]**

| Code      | Condition                   |
| --------- | --------------------------- |
| 0000      | Never (no branch)           |
| 0001      | Always                      |
| 0010      | Zero (Z=1)                  |
| 0011      | Not zero (Z=0)              |
| 0100      | Carry (C=1)                 |
| 0101      | No carry (C=0)              |
| 0110      | Above (C=0 AND Z=0)         |
| 0111      | Below (C=1)                 |
| 1000      | Above or equal (C=0)        |
| 1001      | Below or equal (C=1 OR Z=1) |
| 1010–1111 | (reserved)                  |

**SP_OP [4:2]**

| Code    | Operation                |
| ------- | ------------------------ |
| 000     | None                     |
| 001     | Push (RSP−1, then write) |
| 010     | Pop (read, then RSP+1)   |
| 011     | Increment RSP            |
| 100     | Decrement RSP            |
| 101–111 | (reserved)               |

**MEM_SRC [13:12]**

| Code | Source    |
| ---- | --------- |
| 00   | GPR (RS)  |
| 01   | SP        |
| 10   | PC        |
| 11   | Immediate |

------

## 7. Micro-Sequencer

### 7.1 Structure

A 3-bit counter (`micro_step`) is appended to the opcode to form the CW ROM index:

```
cw_rom_index = { opcode[5:0], micro_step[2:0] }   -- 9-bit index, 512 entries
```

On each clock cycle in EXECUTE:

- If `LAST_STEP = 1`: reset `micro_step` to 0, fetch next instruction
- If `LAST_STEP = 0`: increment `micro_step`, stay on current instruction

### 7.2 Step Usage by Instruction Class

| Class             | Steps used | Notes                         |
| ----------------- | ---------- | ----------------------------- |
| ALU ops, MOV, NOP | 0          | Single-cycle                  |
| LD, ST, LDB, STB  | 0–1        | Memory access + writeback     |
| PUSH              | 0–1        | SP decrement + memory write   |
| POP               | 0–1        | Memory read + SP increment    |
| CALL              | 0–1        | Push RPC + jump               |
| RET               | 0–1        | Pop into RPC                  |
| Interrupt entry   | 0–5        | 6 micro-ops (see Section 8.2) |
| IRET              | 0–2        | Restore PC, mode, GIE         |

------

## 8. Interrupt Architecture

### 8.1 Interrupt Priority

Two classes: synchronous exceptions (caused by the current instruction) always beat asynchronous IRQs (caused by external hardware).

**Full priority order (highest to lowest):**

```
7 (NMI)           — Non-maskable, unblockable
6 (PRIV_FAULT)    — Synchronous: privilege violation
5 (ILL_OPCODE)    — Synchronous: illegal opcode
4 (SOFT_INT)      — Synchronous: software INT instruction (trap)
0 (IRQ0)          — Asynchronous hardware IRQ, highest HW priority
1 (IRQ1)          — Asynchronous hardware IRQ
2 (IRQ2)          — Asynchronous hardware IRQ
3 (IRQ3)          — Asynchronous hardware IRQ, lowest HW priority
```

IRQ0 has the highest priority among hardware IRQs. Priority among simultaneously asserted IRQs is resolved by a fixed priority encoder (combinational logic on PENDING bits).

### 8.2 Interrupt Entry Micro-Sequence

On interrupt entry, the hardware executes the following micro-ops in order:

```
Step 0: GIE ← 0                        (disable all maskable interrupts)
Step 1: RIP ← RPC                      (save return address)
Step 2: RM.PREV_MODE ← RM.MODE         (save current privilege level)
        RM.MODE ← 1                    (enter kernel mode)
Step 3: XR0 ← faulting RPC
        XR1 ← vector number (zero-extended)
        XR2 ← faulting instruction word
        XR3 ← faulting memory address
Step 4: RPC ← RIV[n]                   (jump to handler)
Step 5: LAST_STEP=1, resume fetch
```

Steps 3 and 4 may be collapsed depending on RTL timing. Maximum 6 micro-ops, within the 3-bit step counter range (0–7).

### 8.3 Interrupt Nesting

**No nesting.** On interrupt entry, GIE is cleared. All maskable interrupts are disabled for the duration of the handler. NMI (vector 7) is always active regardless of GIE.

IRET restores GIE alongside RPC and RM.MODE.

This is intentional: nested interrupt handling is deferred to v2. The no-nesting policy eliminates a class of re-entrancy bugs and stack corruption during v1 development.

### 8.4 IRET Sequence

```
Step 0: RPC ← RIP                      (restore return address)
Step 1: RM.MODE ← RM.PREV_MODE         (restore privilege level)
Step 2: GIE ← 1, LAST_STEP=1          (re-enable interrupts, resume fetch)
```

### 8.5 Interrupt Vector Table

| Vector | Source          | Maskable | Notes                          |
| ------ | --------------- | -------- | ------------------------------ |
| 0      | Hardware IRQ 0  | Yes      | Highest HW IRQ priority        |
| 1      | Hardware IRQ 1  | Yes      |                                |
| 2      | Hardware IRQ 2  | Yes      |                                |
| 3      | Hardware IRQ 3  | Yes      | Lowest HW IRQ priority         |
| 4      | Software INT    | Yes      | Trap / syscall                 |
| 5      | Illegal opcode  | Yes      | Synchronous fault              |
| 6      | Privilege fault | Yes      | Synchronous fault              |
| 7      | NMI             | **No**   | Always fires regardless of GIE |

RIV0–RIV7 must be initialised by boot firmware before GIE is set.

------

## 9. Flag Register

The ALU maintains a set of condition flags, written on every ALU operation:

| Flag | Name     | Description                          |
| ---- | -------- | ------------------------------------ |
| Z    | Zero     | Result is zero                       |
| C    | Carry    | Carry out of MSB (unsigned overflow) |
| N    | Negative | MSB of result is 1                   |
| V    | Overflow | Signed overflow                      |

Flags are read by the branch condition logic (BRANCH_COND field). CMP sets flags without writing a result. Flags are not directly addressable by software in v1.

------

## 10. CALL / RET Convention

Stack-based. The hardware implements:

**CALL target:**

```
Step 0: Push RPC → memory[RSP], RSP ← RSP − 1
Step 1: RPC ← target
```

**RET:**

```
Step 0: RSP ← RSP + 1, RPC ← memory[RSP]
```

RRP is available as a fast return register for leaf functions (no nested calls), but the hardware CALL/RET instructions use the stack.

## 11. Architectural Diagram

````mermaid
graph LR
    %% Styling
    %% classDef register fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    %% classDef logic fill:#fff3e0,stroke:#e65100,stroke-width:2px;
    %% classDef mux fill:#f3e5f5,stroke:#4a148c,stroke-width:2px;
    %% classDef memory fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px;
    %%      classDef control fill:#eceff1,stroke:#263238,stroke-width:2px,stroke-dasharray: 5 5;

    %% --- STAGE 1: FETCH ---
    subgraph IF [Instruction Fetch]
        PC[("RPC<br/>(Program Counter)")]:::register
        PC_INC["PC + 1"]:::logic
        INST_ROM[["Instruction ROM<br/>(idata)"]]:::memory
    end

    %% --- STAGE 2: DECODE & CONTROL ---
    subgraph ID [Decode & Control]
        FD_REG["FD_INSTR / FD_PC<br/>(Pipeline Regs)"]:::register
        
        subgraph CU [Control Unit]
            SEQ["Micro-step<br/>Sequencer"]:::logic
            CW_ROM[["CW ROM<br/>(512 x 32)"]]:::memory
            CW_BUS{{"Control Word Bus<br/>[31:0]"}}:::control
        end
        
        DEC["Instruction<br/>Decoder"]:::logic
    end

    %% --- STAGE 3: EXECUTE / DATAPATH ---
    subgraph EX [Execute / Datapath]
        REG_FILE[["Register File<br/>(R0-R7)"]]:::register
        
        MUX_B["SRC_B MUX"]:::mux
        ALU{{"ALU<br/>(16-bit)"}}:::logic
        
        FLAGS["Flags Register<br/>(Z, C, N, V)"]:::register
        
        SP[("RSP<br/>(Stack Pointer)")]:::register
    end

    %% --- MEMORY & WRITEBACK ---
    subgraph WB [Memory & Writeback]
        ADDR_MUX["MEM_SRC MUX"]:::mux
        DATA_RAM[["Data RAM<br/>(ddata)"]]:::memory
        WB_MUX["WB_SRC MUX"]:::mux
    end

    %% --- CONNECTIONS: CONTROL FLOW ---
    PC --> INST_ROM
    INST_ROM --> FD_REG
    PC --> PC_INC
    
    FD_REG -- "Opcode [15:10]" --> CU
    SEQ -- "Step [2:0]" --> CU
    CU -- "de_cw bits" --> CW_BUS

    %% --- CONNECTIONS: DATA ---
    FD_REG -- "rs/rt indices" --> REG_FILE
    
    REG_FILE -- "Port A" --> ALU
    REG_FILE -- "Port B" --> MUX_B
    
    CW_BUS -. "SRC_B [27:25]" .-> MUX_B
    CW_BUS -. "ALU_OP [31:28]" .-> ALU
    
    MUX_B -- "Operand B" --> ALU
    ALU -- "Result" --> ADDR_MUX
    ALU -- "Result" --> WB_MUX
    
    SP --> ADDR_MUX
    CW_BUS -. "MEM_SRC [13:12]" .-> ADDR_MUX
    ADDR_MUX -- "daddr" --> DATA_RAM
    
    DATA_RAM -- "ddata_r" --> WB_MUX
    CW_BUS -. "WB_SRC [22:20]" .-> WB_MUX
    
    WB_MUX -- "Write Data" --> REG_FILE
    CW_BUS -. "REG_WE [24]" .-> REG_FILE

    %% --- CONNECTIONS: FEEDBACK ---
    ALU -- "Compare" --> FLAGS
    FLAGS -- "Condition Met" --> PC
    CW_BUS -. "PC_SRC [11:9]" .-> PC
    CW_BUS -. "LAST_STEP [0]" .-> SEQ

    %% Legend/Note
    note1[/"Dashted Lines = Control Signals<br/>Solid Lines = Data Bus"/]   
````



------

## 12. Open Items (v1 RTL Phase)

- Exact CW ROM initialisation (all 512 entries, undefined opcodes → ILL_OPCODE fault)
- Flag register reset state
- Precise read/write timing in EXECUTE to confirm/deny RAW hazard stall requirement
- Special register read mux (WB_SRC=100) — which register is selected and how
- System instruction CW encodings (ENABLE_IRQ, DISABLE_IRQ, SET_MODE, READ_RIC, WRITE_RIC)
- Peripheral port reconciliation (memory_bus vs peripherals entity mismatch)
- Byte addressing semantics for LDB/STB with misaligned addresses

------

*4328 CPU Spec v2.0 — end of document*