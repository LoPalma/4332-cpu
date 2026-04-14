import sys
import re
import argparse
import struct

# =============================================================================
# CPU Architecture Definitions
# =============================================================================

OPCODES = {
    'ADD': 0, 'SUB': 1, 'AND': 2, 'OR': 3, 'XOR': 4,
    'NOT': 5, 'SHL': 6, 'SHR': 7, 'INC': 8, 'DEC': 9,
    'CMP': 10, 'MOV': 11, 'LOADIMM': 12, 'PASSA': 13, 'PASSB': 14,
    'NOP': 15, 'LD': 16, 'ST': 17, 'LDB': 18, 'STB': 19,
    'PUSH': 20, 'POP': 21, 'PEEK': 22, 'FLUSH': 23,
    'JMP': 24, 'JZ': 25, 'JNZ': 26, 'JC': 27, 'JNC': 28,
    'JA': 29, 'JB': 30, 'JAE': 31, 'JBE': 32, 'CALL': 33,
    'RET': 34, 'IRET': 35, 'INT': 36, 'HLT': 37,
    'ENIRQ': 48, 'DISIRQ': 49, 'SETMODE': 50, 'GETMODE': 51,
    'WRITERIC': 52, 'READRIC': 53, 'READRIV': 54, 'WRITERIV': 55,
    'HALT': 57
}

# Grouping by operand signature
FMT_RDRS   = {'ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP', 'MOV', 'LD', 'ST', 'LDB', 'STB', 'WRITERIV', 'SETMODE'}
FMT_RD     = {'NOT', 'SHL', 'SHR', 'INC', 'DEC', 'POP', 'PEEK', 'PASSA', 'GETMODE', 'READRIC', 'READRIV'}
FMT_RS     = {'PASSB', 'PUSH', 'JMP', 'CALL', 'WRITERIC'}
FMT_BRANCH = {'JZ', 'JNZ', 'JC', 'JNC', 'JA', 'JB', 'JAE', 'JBE'}
FMT_NONE   = {'NOP', 'FLUSH', 'RET', 'IRET', 'INT', 'HLT', 'ENIRQ', 'DISIRQ', 'HALT'}

SIZE_MAP = {'w': 0, 'l': 1, 'h': 2, 'd': 3}
COND_MAP = {'z': 1, 'c': 2, 'n': 3}

# =============================================================================
# Helper Functions
# =============================================================================

def parse_reg(reg_str):
    if not reg_str.startswith('%'):
        raise SyntaxError(f"Expected register starting with '%', got '{reg_str}'")
    try:
        reg = int(reg_str[1:])
        if reg < 0 or reg > 7:
            raise ValueError
        return reg
    except ValueError:
        raise SyntaxError(f"Invalid register '{reg_str}'. Must be %0 to %7.")

def parse_imm(imm_str):
    try:
        return int(imm_str, 0)
    except ValueError:
        raise SyntaxError(f"Invalid immediate value '{imm_str}'")

def encode_instr(opcode, rd, rs, width, cond):
    return (opcode << 10) | (rd << 7) | (rs << 4) | (width << 2) | cond

# =============================================================================
# Assembler Logic
# =============================================================================

def assemble(source_lines):
    labels = {}
    instructions = [] # Stores (pc, filename, line_num, parsed_data)
    
    # PASS 1: Parse syntax and resolve labels
    pc = 0
    for line_num, line in enumerate(source_lines, 1):
        # Strip comments and whitespace
        line = line.split(';')[0].split('#')[0].strip()
        if not line:
            continue
            
        # Handle Labels
        if line.endswith(':'):
            label = line[:-1]
            if label in labels:
                raise SyntaxError(f"Line {line_num}: Duplicate label '{label}'")
            labels[label] = pc
            continue
            
        # Extract mnemonic and operands
        parts = line.replace(',', ' ').split()
        mnemonic_parts = parts[0].split('/')
        op_name = mnemonic_parts[0].upper()
        
        if op_name not in OPCODES:
            raise SyntaxError(f"Line {line_num}: Unknown opcode '{op_name}'")
            
        width, cond = 0, 0 # Default: 16-bit, Always
        for suffix in mnemonic_parts[1:]:
            s = suffix.lower()
            if s in SIZE_MAP:
                width = SIZE_MAP[s]
            elif s in COND_MAP:
                cond = COND_MAP[s]
            else:
                raise SyntaxError(f"Line {line_num}: Unknown suffix '/{suffix}'")
                
        args = parts[1:]
        instructions.append((pc, line_num, op_name, width, cond, args, line))
        
        # Advance PC (LOADIMM takes 2 words, others take 1)
        pc += 2 if op_name == 'LOADIMM' else 1

    # PASS 2: Code Generation
    machine_code = []
    
    for pc, line_num, op_name, width, cond, args, raw_line in instructions:
        opcode = OPCODES[op_name]
        try:
            if op_name in FMT_RDRS:
                if len(args) != 2: raise SyntaxError(f"Expected 2 operands for {op_name}")
                rd, rs = parse_reg(args[0]), parse_reg(args[1])
                word = encode_instr(opcode, rd, rs, width, cond)
                machine_code.append(word)
                
            elif op_name in FMT_RD:
                if len(args) != 1: raise SyntaxError(f"Expected 1 operand (RD) for {op_name}")
                rd = parse_reg(args[0])
                word = encode_instr(opcode, rd, 0, width, cond)
                machine_code.append(word)
                
            elif op_name in FMT_RS:
                if len(args) != 1: raise SyntaxError(f"Expected 1 operand (RS) for {op_name}")
                rs = parse_reg(args[0])
                word = encode_instr(opcode, 0, rs, width, cond)
                machine_code.append(word)
                
            elif op_name in FMT_NONE:
                if len(args) != 0: raise SyntaxError(f"Expected 0 operands for {op_name}")
                word = encode_instr(opcode, 0, 0, width, cond)
                machine_code.append(word)
                
            elif op_name == 'LOADIMM':
                if len(args) != 2: raise SyntaxError(f"Expected '%RD, IMM' for LOADIMM")
                rd = parse_reg(args[0])
                imm = parse_imm(args[1])
                # Word 1: Opcode + RD
                machine_code.append(encode_instr(opcode, rd, 0, 0, 0))
                # Word 2: Immediate Data
                machine_code.append(imm & 0xFFFF)
                
            elif op_name in FMT_BRANCH:
                if len(args) != 1: raise SyntaxError(f"Expected target label or offset for {op_name}")
                target = args[0]
                
                # Check if it's a label or an explicit offset
                if target in labels:
                    offset = labels[target] - pc
                else:
                    try:
                        offset = int(target, 0)
                    except ValueError:
                        raise SyntaxError(f"Undefined label or invalid offset '{target}'")
                
                if not (-8 <= offset <= 7):
                    raise SyntaxError(f"Branch offset {offset} out of 4-bit signed bounds [-8, +7]")
                
                # Encode 4-bit signed offset into inst[3:0]
                offset_4bit = offset & 0xF
                word = encode_instr(opcode, 0, 0, 0, 0) | offset_4bit
                machine_code.append(word)

        except Exception as e:
            print(f"Error on line {line_num} ('{raw_line}'): {e}", file=sys.stderr)
            sys.exit(1)
            
    return machine_code

# =============================================================================
# CLI Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="4328 CPU Assembler")
    parser.add_argument("input", help="Input assembly file")
    parser.add_argument("-o", "--output", default="a.out", help="Output file")
    parser.add_argument("-a", "--ascii", action="store_true", help="Output ASCII binary strings")
    parser.add_argument("-x", "--hex", action="store_true", help="Output ASCII hex strings")
    args = parser.parse_args()

    with open(args.input, 'r') as f:
        source_lines = f.readlines()

    machine_code = assemble(source_lines)

    if args.ascii:
        with open(args.output, 'w') as f:
            for word in machine_code:
                f.write(f"{word:016b}\n")
        print(f"Successfully assembled {len(machine_code)} words to {args.output} (ASCII Binary).")
    
    elif args.hex:
        with open(args.output, 'w') as f:
            for word in machine_code:
                f.write(f"{word:04X}\n")
        print(f"Successfully assembled {len(machine_code)} words to {args.output} (ASCII Hex).")
    
    else:
        with open(args.output, 'wb') as f:
            for word in machine_code:
                # >H means Big-Endian 16-bit unsigned short
                f.write(struct.pack('>H', word))
        print(f"Successfully assembled {len(machine_code)} words to {args.output} (Raw Binary).")

if __name__ == "__main__":
    main()