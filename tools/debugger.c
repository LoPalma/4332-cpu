#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>

#define MEMORY_WORDS	65536
#define MAX_BPS		64
#define MAX_WATCHES	16

// WIDTH Constants
#define WIDTH_16	0x00
#define WIDTH_8L	0x01
#define WIDTH_8H	0x02
#define WIDTH_32	0x03

// Opcodes
#define OP_ADD		0x00
#define OP_SUB		0x01
#define OP_AND		0x02
#define OP_OR		0x03
#define OP_XOR		0x04
#define OP_NOT		0x05
#define OP_SHL		0x06
#define OP_SHR		0x07
#define OP_INC		0x08
#define OP_DEC		0x09
#define OP_CMP		0x0A
#define OP_MOV		0x0B
#define OP_LOADIMM	0x0C
#define OP_PASSA	0x0D
#define OP_PASSB	0x0E
#define OP_LD		0x10
#define OP_ST		0x11
#define OP_LDB		0x12
#define OP_STB		0x13
#define OP_PUSH		0x14
#define OP_POP		0x15
#define OP_PEEK		0x16
#define OP_JMP		0x18
#define OP_JZ		0x19
#define OP_JNZ		0x1A
#define OP_JC		0x1B
#define OP_JNC		0x1C
#define OP_JA		0x1D
#define OP_JB		0x1E
#define OP_JAE		0x1F
#define OP_JBE		0x20
#define OP_CALL		0x21
#define OP_RET		0x22
#define OP_IRET		0x23
#define OP_INT		0x24
#define OP_HLT		0x25

struct CPU {
	uint16_t r[8];
	uint16_t xr[8];
	uint16_t pc;
	uint16_t sp;
	
	bool flag_z;
	bool flag_c;
	bool flag_n;
	bool flag_v;

	uint16_t mem[MEMORY_WORDS];
	bool halted;
};

struct Debugger {
	struct CPU cpu;
	uint16_t bps[MAX_BPS];
	int bp_count;
	char watches[MAX_WATCHES][32];
	int watch_count;
};

// Dispatch table prototype
typedef void (*op_func)(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm);

// -----------------------------------------------------------------------------
// WIDTH-Aware Register Helpers
// -----------------------------------------------------------------------------

uint32_t get_val(struct CPU *cpu, uint8_t idx, uint8_t width) {
	switch (width) {
	case WIDTH_16: {
		return cpu->r[idx];
	}
	case WIDTH_8L: {
		return cpu->r[idx] & 0xFF;
	}
	case WIDTH_8H: {
		return (cpu->r[idx] >> 8) & 0xFF;
	}
	case WIDTH_32: {
		return ((uint32_t)cpu->xr[idx] << 16) | cpu->r[idx];
	}
	default: {
		return 0;
	}
	}
}

void set_val(struct CPU *cpu, uint8_t idx, uint8_t width, uint32_t val) {
	switch (width) {
	case WIDTH_16: {
		cpu->r[idx] = val & 0xFFFF;
		cpu->flag_z = (cpu->r[idx] == 0);
	}
	break;

	case WIDTH_8L: {
		cpu->r[idx] = (cpu->r[idx] & 0xFF00) | (val & 0xFF);
		cpu->flag_z = ((val & 0xFF) == 0);
	}
	break;

	case WIDTH_8H: {
		cpu->r[idx] = (cpu->r[idx] & 0x00FF) | ((val & 0xFF) << 8);
		cpu->flag_z = ((val & 0xFF) == 0);
	}
	break;

	case WIDTH_32: {
		cpu->r[idx] = val & 0xFFFF;
		cpu->xr[idx] = (val >> 16) & 0xFFFF;
		cpu->flag_z = (val == 0);
	}
	break;
	}
}

// -----------------------------------------------------------------------------
// Opcode Handlers
// -----------------------------------------------------------------------------

void handler_add(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint32_t a = get_val(cpu, rd, width);
	uint32_t b = get_val(cpu, rs, width);
	uint64_t res = (uint64_t)a + b;
	set_val(cpu, rd, width, (uint32_t)res);
	cpu->flag_c = (res > 0xFFFFFFFF && width == WIDTH_32) || (res > 0xFFFF && width == WIDTH_16);
}

void handler_sub_cmp(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint32_t a = get_val(cpu, rd, width);
	uint32_t b = get_val(cpu, rs, width);
	uint32_t res = a - b;
	cpu->flag_c = (a < b);
	// RD is bits 15:10, if opcode was SUB (0x01) we write back. If CMP (0x0A) we don't.
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	if (op == OP_SUB) {
		set_val(cpu, rd, width, res);
	}
	else {
		cpu->flag_z = (res == 0);
	}
}

void handler_logic(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint32_t a = get_val(cpu, rd, width);
	uint32_t b = get_val(cpu, rs, width);
	uint32_t res = 0;
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	switch (op) {
	case OP_AND: res = a & b; break;
	case OP_OR:  res = a | b; break;
	case OP_XOR: res = a ^ b; break;
	case OP_NOT: res = ~a;    break;
	}
	set_val(cpu, rd, width, res);
}

void handler_shift_inc(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint32_t a = get_val(cpu, rd, width);
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	if (op == OP_SHL) a <<= 1;
	else if (op == OP_SHR) a >>= 1;
	else if (op == OP_INC) a += 1;
	else if (op == OP_DEC) a -= 1;
	set_val(cpu, rd, width, a);
}

void handler_loadimm(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint32_t val = 0;
	if (width == WIDTH_32) {
		uint16_t low = cpu->mem[cpu->pc++];
		uint16_t high = cpu->mem[cpu->pc++];
		val = ((uint32_t)high << 16) | low;
	}
	else {
		val = cpu->mem[cpu->pc++];
	}
	set_val(cpu, rd, width, val);
}

void handler_mov_pass(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	uint32_t val = (op == OP_PASSA) ? get_val(cpu, rd, width) : get_val(cpu, rs, width);
	// For MOV/PASS logic, user code usually puts result in R0 or RD.
	// Following v2 spec: results go to RD.
	set_val(cpu, rd, width, val);
}

void handler_mem(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	uint16_t addr = cpu->r[rs];
	switch (op) {
	case OP_LD:  cpu->r[rd] = cpu->mem[addr]; break;
	case OP_ST:  cpu->mem[cpu->r[rd]] = cpu->r[rs]; break;
	case OP_LDB: cpu->r[rd] = cpu->mem[addr] & 0xFF; break;
	case OP_STB: cpu->mem[cpu->r[rd]] = cpu->r[rs] & 0xFF; break;
	}
}

void handler_stack(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	if (op == OP_PUSH) {
		cpu->sp--;
		cpu->mem[cpu->sp] = cpu->r[rs];
	}
	else if (op == OP_POP) {
		cpu->r[rd] = cpu->mem[cpu->sp++];
	}
	else if (op == OP_PEEK) {
		cpu->r[rd] = cpu->mem[cpu->sp];
	}
}

void handler_jump(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	bool taken = false;
	int8_t offset = (int8_t)(imm << 4) >> 4; // 4-bit sign extend

	switch (op) {
	case OP_JMP: taken = true; cpu->pc = cpu->r[rs]; return;
	case OP_JZ:  taken = cpu->flag_z; break;
	case OP_JNZ: taken = !cpu->flag_z; break;
	case OP_JC:  taken = cpu->flag_c; break;
	case OP_JNC: taken = !cpu->flag_c; break;
	case OP_JA:  taken = (!cpu->flag_c && !cpu->flag_z); break;
	case OP_JB:  taken = cpu->flag_c; break;
	case OP_JAE: taken = !cpu->flag_c; break;
	case OP_JBE: taken = (cpu->flag_c || cpu->flag_z); break;
	}

	if (taken) {
		cpu->pc += offset;
	}
}

void handler_call_ret(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	uint8_t op = (cpu->mem[cpu->pc - 1] >> 10) & 0x3F;
	if (op == OP_CALL) {
		cpu->sp--;
		cpu->mem[cpu->sp] = cpu->pc;
		cpu->pc = cpu->r[rs];
	}
	else {
		cpu->pc = cpu->mem[cpu->sp++];
	}
}

void handler_fault(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	fprintf(stdout, "Faulted at address %04X, \nwhile running %04X.\nHalted.\n", 
		cpu->pc - 1, cpu->mem[cpu->pc - 1]);
	cpu->halted = true;
}

void handler_hlt(struct CPU *cpu, uint8_t rd, uint8_t rs, uint8_t width, uint8_t imm) {
	cpu->halted = true;
}

// -----------------------------------------------------------------------------
// Dispatch Table Initialization
// -----------------------------------------------------------------------------

op_func dispatch[64];

void init_dispatch() {
	for (int i = 0; i < 64; i++) dispatch[i] = handler_fault;

	dispatch[OP_ADD]	= handler_add;
	dispatch[OP_SUB]	= handler_sub_cmp;
	dispatch[OP_CMP]	= handler_sub_cmp;
	dispatch[OP_AND]	= handler_logic;
	dispatch[OP_OR]		= handler_logic;
	dispatch[OP_XOR]	= handler_logic;
	dispatch[OP_NOT]	= handler_logic;
	dispatch[OP_SHL]	= handler_shift_inc;
	dispatch[OP_SHR]	= handler_shift_inc;
	dispatch[OP_INC]	= handler_shift_inc;
	dispatch[OP_DEC]	= handler_shift_inc;
	dispatch[OP_MOV]	= handler_mov_pass;
	dispatch[OP_PASSA]	= handler_mov_pass;
	dispatch[OP_PASSB]	= handler_mov_pass;
	dispatch[OP_LOADIMM]	= handler_loadimm;
	dispatch[OP_LD]		= handler_mem;
	dispatch[OP_ST]		= handler_mem;
	dispatch[OP_LDB]	= handler_mem;
	dispatch[OP_STB]	= handler_mem;
	dispatch[OP_PUSH]	= handler_stack;
	dispatch[OP_POP]	= handler_stack;
	dispatch[OP_PEEK]	= handler_stack;
	dispatch[OP_JMP]	= handler_jump;
	dispatch[OP_JZ]		= handler_jump;
	dispatch[OP_JNZ]	= handler_jump;
	dispatch[OP_JC]		= handler_jump;
	dispatch[OP_JNC]	= handler_jump;
	dispatch[OP_JA]		= handler_jump;
	dispatch[OP_JB]		= handler_jump;
	dispatch[OP_JAE]	= handler_jump;
	dispatch[OP_JBE]	= handler_jump;
	dispatch[OP_CALL]	= handler_call_ret;
	dispatch[OP_RET]	= handler_call_ret;
	dispatch[OP_IRET]	= handler_hlt; // Stub
	dispatch[OP_INT]	= handler_hlt; // Stub
	dispatch[OP_HLT]	= handler_hlt;
}
// -----------------------------------------------------------------------------
// Debugger Execution Helpers
// -----------------------------------------------------------------------------

void cpu_init(struct CPU *cpu);
void cpu_step(struct CPU *cpu);

void process_watches(struct Debugger *dbg) {
	if (dbg->watch_count > 0) {
		printf("\n--- Watches ---\n");
		for (int i = 0; i < dbg->watch_count; i++) {
			// Reuse the register display logic
			if (strcasecmp(dbg->watches[i], "pc") == 0) {
				printf("PC : 0x%04X\n", dbg->cpu.pc);
			}
			else if (toupper(dbg->watches[i][0]) == 'R' && isdigit(dbg->watches[i][1])) {
				int idx = dbg->watches[i][1] - '0';
				uint32_t val = get_val(&dbg->cpu, idx, WIDTH_32);
				printf("R%d : 0x%08X\n", idx, val);
			}
		}
		printf("---------------\n");
	}
}

void execute_run(struct Debugger *dbg) {
	if (dbg->cpu.halted) {
		printf("CPU is halted. Resetting...\n");
		cpu_init(&dbg->cpu);
	}

	while (!dbg->cpu.halted) {
		cpu_step(&dbg->cpu);
		
		// Check breakpoints
		bool hit = false;
		for (int i = 0; i < dbg->bp_count; i++) {
			if (dbg->cpu.pc == dbg->bps[i]) {
				hit = true;
				break;
			}
		}

		if (hit) {
			printf("Breakpoint hit at 0x%04X\n", dbg->cpu.pc);
			break;
		}
	}

	if (dbg->cpu.halted) {
		// The fault log is already printed by handler_fault inside cpu_step
		// so we just stop here.
	}

	process_watches(dbg);
}
// -----------------------------------------------------------------------------
// Debugger Core
// -----------------------------------------------------------------------------

void cpu_init(struct CPU *cpu) {
	memset(cpu->r, 0, sizeof(cpu->r));
	memset(cpu->xr, 0, sizeof(cpu->xr));
	cpu->pc = 0;
	cpu->sp = 0xBFFE;
	cpu->halted = false;
}

void cpu_step(struct CPU *cpu) {
	if (cpu->halted) return;
	uint16_t instr = cpu->mem[cpu->pc++];
	uint8_t op    = (instr >> 10) & 0x3F;
	uint8_t rd    = (instr >> 7) & 0x07;
	uint8_t rs    = (instr >> 4) & 0x07;
	uint8_t width = (instr >> 2) & 0x03;
	uint8_t imm   = (instr & 0x0F);

	dispatch[op](cpu, rd, rs, width, imm);
}

void run_repl(struct Debugger *dbg) {
	char line[256];
	char cmd[32];
	char arg1[32];
	char arg2[32];

	init_dispatch();
	printf("4328 Debugger v3\n");
	printf("Commands: step, run, break <addr>, clear, watch <reg>, set <reg> <val>, show <reg/rom/frame/bps>\n");

	while (1) {
		if (dbg->cpu.halted) {
			cpu_init(&dbg->cpu);
			printf("CPU reset.\n");
		}

		printf("DB] ");
		if (!fgets(line, sizeof(line), stdin)) {
			break;
		}

		int parsed = sscanf(line, "%31s %31s %31s", cmd, arg1, arg2);
		if (parsed < 1) {
			continue;
		}

		if (strcmp(cmd, "exit") == 0 || strcmp(cmd, "quit") == 0) {
			break;
		}
		else if (strcmp(cmd, "step") == 0) {
			cpu_step(&dbg->cpu);
			printf("Stepped. PC is now 0x%04X\n", dbg->cpu.pc);
			process_watches(dbg);
		}
		else if (strcmp(cmd, "run") == 0 || strcmp(cmd, "continue") == 0 || strcmp(cmd, "next") == 0) {
			execute_run(dbg);
		}
		else if (strcmp(cmd, "break") == 0) {
			if (parsed >= 2) {
				uint16_t addr = (uint16_t)strtoul(arg1, NULL, 16);
				if (dbg->bp_count < MAX_BPS) {
					dbg->bps[dbg->bp_count++] = addr;
					printf("Breakpoint set at 0x%04X\n", addr);
				}
			}
		}
		else if (strcmp(cmd, "clear") == 0) {
			dbg->bp_count = 0;
			printf("All breakpoints cleared.\n");
		}
		else if (strcmp(cmd, "watch") == 0) {
			if (parsed >= 2 && dbg->watch_count < MAX_WATCHES) {
				strncpy(dbg->watches[dbg->watch_count], arg1, 31);
				dbg->watch_count++;
				printf("Watching %s\n", arg1);
			}
		}
		else if (strcmp(cmd, "set") == 0) {
			if (parsed >= 3) {
				uint32_t val = (uint32_t)strtoul(arg2, NULL, 16);
				// We use WIDTH_32 for manual 'set' to allow full 32-bit modification
				if (arg1[0] == 'r' || arg1[0] == 'R') {
					int idx = arg1[1] - '0';
					if (idx >= 0 && idx < 8) {
						set_val(&dbg->cpu, idx, WIDTH_32, val);
						printf("Set R%d (paired) to 0x%08X\n", idx, val);
					}
				}
				else if (strcasecmp(arg1, "pc") == 0) {
					dbg->cpu.pc = (uint16_t)val;
				}
				else if (strcasecmp(arg1, "sp") == 0) {
					dbg->cpu.sp = (uint16_t)val;
				}
			}
		}
		else if (strcmp(cmd, "show") == 0) {
			if (parsed < 2) {
				printf("Usage: show <reg>, show breakpoints, show frame, show rom <n> <m>\n");
			}
			else if (strcmp(arg1, "breakpoints") == 0 || strcmp(arg1, "bps") == 0) {
				for (int i = 0; i < dbg->bp_count; i++) {
					printf("BP %d: 0x%04X\n", i, dbg->bps[i]);
				}
			}
			else if (strcmp(arg1, "frame") == 0) {
				printf("Stack Frame (0xBFFE down to SP: 0x%04X):\n", dbg->cpu.sp);
				for (uint32_t addr = 0xBFFE; addr >= dbg->cpu.sp && addr <= 0xBFFE; addr--) {
					printf("  [0x%04X] : 0x%04X\n", addr, dbg->cpu.mem[addr]);
				}
			}
			else if (strcmp(arg1, "rom") == 0) {
				if (parsed >= 3 && strcmp(arg2, "all") == 0) {
					for (int i = 0; i < 256; i++) {
						printf("0x%04X: 0x%04X\n", i, dbg->cpu.mem[i]);
					}
				}
				else if (parsed >= 3) {
					char arg3[32];
					// Re-parse to get the third argument for the range end
					sscanf(line, "%*s %*s %31s %31s", arg2, arg3);
					uint16_t n = (uint16_t)strtoul(arg2, NULL, 16);
					uint16_t m = (uint16_t)strtoul(arg3, NULL, 16);
					for (uint32_t addr = n; addr <= m && addr < MEMORY_WORDS; addr++) {
						printf("0x%04X: 0x%04X\n", addr, dbg->cpu.mem[addr]);
					}
				}
			}
			else {
				// Fallback to register display
				if (strcasecmp(arg1, "pc") == 0) printf("PC = 0x%04X\n", dbg->cpu.pc);
				else if (strcasecmp(arg1, "sp") == 0) printf("SP = 0x%04X\n", dbg->cpu.sp);
				else if (toupper(arg1[0]) == 'R' && isdigit(arg1[1])) {
					int idx = arg1[1] - '0';
					uint32_t full = get_val(&dbg->cpu, idx, WIDTH_32);
					printf("R%d: 0x%04X | XR%d: 0x%04X (32-bit: 0x%08X)\n", 
						idx, dbg->cpu.r[idx], idx, dbg->cpu.xr[idx], full);
				}
			}
		}
		else {
			printf("Unknown command: %s\n", cmd);
		}
	}
}

int main(int argc, char **argv) {
	struct Debugger dbg = {0};
	cpu_init(&dbg.cpu);
	if (argc > 1) {
		FILE *f = fopen(argv[1], "rb");
		if (f) {
			fread(dbg.cpu.mem, 2, MEMORY_WORDS, f);
			fclose(f);
		}
	}
	run_repl(&dbg);
	return 0;
}
