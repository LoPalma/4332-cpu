#!/usr/bin/python3

import sys
import re
import argparse
import struct

# =============================================================================
# CPU Architecture Definitions
# =============================================================================

# All conditional jumps are gone. Use J with a condition suffix:
#   j label         → unconditional jump (no suffix)
#   j.z label       → jump if Z set
#   j.c label       → jump if C set
#   j.n label       → jump if N set
# Addressing modes are selected by operand form, not a suffix:
#   j label         → AM_DIRECT   (2-word, absolute target)
#   j %rs           → AM_INDIRECT (1-word, target in rs)
#   j %rs, offset   → AM_INDIR_OFF (2-word, rs + offset)

OPCODES = {
    # Arithmetic / Logic
    'ADD': 0, 'SUB': 1, 'AND': 2, 'OR': 3, 'XOR': 4,
    'NOT': 5, 'SHL': 6, 'SHR': 7, 'INC': 8, 'DEC': 9,
    'CMP': 10, 'MOV': 11, 'LOADIMM': 12, 'PASSA': 13, 'PASSB': 14,
    'NOP': 15,
    # Memory
    'LD': 16, 'ST': 17, 'LDB': 18, 'STB': 19,
    'PUSH': 20, 'POP': 21, 'PEEK': 22, 'FLUSH': 23,
    # Control flow — single J mnemonic; opcode 24
    'J': 24,
    'CALL': 33, 'RET': 34, 'IRET': 35, 'INT': 36, 'HLT': 37,
    # System
    'ENIRQ': 48, 'DISIRQ': 49, 'SETMODE': 50, 'GETMODE': 51,
    'WRITERIC': 52, 'READRIC': 53, 'READRIV': 54, 'WRITERIV': 55,
    'HALT': 57
}

# Operand format groups
FMT_RDRS    = {'ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP', 'MOV',
               'LD', 'ST', 'LDB', 'STB', 'WRITERIV'}
FMT_RD      = {'NOT', 'SHL', 'SHR', 'INC', 'DEC', 'POP', 'PEEK',
               'PASSA', 'GETMODE', 'READRIC', 'READRIV'}
FMT_RS      = {'PASSB', 'PUSH', 'WRITERIC', 'SETMODE'}
FMT_CONTROL = {'J', 'CALL'}
FMT_NONE    = {'NOP', 'FLUSH', 'RET', 'IRET', 'INT', 'HLT',
               'ENIRQ', 'DISIRQ', 'HALT'}

# Width suffix → inst[3:2] encoding (data ops only — NOT used for jumps)
SIZE_MAP = {'w': 0, 'l': 1, 'h': 2, 'd': 3}

# Condition suffix → inst[1:0] encoding
# Applies to all instructions (data ops and jumps alike)
COND_MAP = {'z': 1, 'c': 2, 'n': 3}

# Addressing Modes for jumps/calls (inst[3:2]) — set by operand form, never by suffix
AM_DIRECT    = 0b00   # J label           — absolute target in next word
AM_INDIRECT  = 0b01   # J %rs             — target in regfile[rs]
AM_INDIR_OFF = 0b10   # J %rs, offset     — regfile[rs] + next word

# =============================================================================
# Helper Functions
# =============================================================================

def parse_reg(reg_str):
    s = reg_str.strip()
    if not s.startswith('%'):
        raise SyntaxError(f"Expected register starting with '%', got '{s}'")
    try:
        reg = int(s[1:])
        if 0 <= reg <= 7:
            return reg
        raise ValueError
    except ValueError:
        raise SyntaxError(f"Invalid register '{s}'. Use %0 to %7.")

def parse_imm(imm_str, labels):
    s = imm_str.strip()
    if s in labels:
        return labels[s]
    try:
        return int(s, 0)
    except ValueError:
        raise SyntaxError(f"Undefined label or invalid immediate '{s}'")

def encode_instr(opcode, rd, rs, am_or_width, cond):
    """Pack a 16-bit instruction word.
    inst[15:10]=opcode, [9:7]=rd, [6:4]=rs, [3:2]=am/width, [1:0]=cond
    """
    return ((opcode & 0x3F) << 10) | ((rd & 0x7) << 7) | \
           ((rs & 0x7) << 4) | ((am_or_width & 0x3) << 2) | (cond & 0x3)

# =============================================================================
# Directives
# =============================================================================

# Known assembler directives (not opcodes)
DIRECTIVES = {'.dw', '.db', '.ascii', '.asciz', '.str', '.strz'}

def parse_escape(s):
    """Expand Python-style escape sequences in a raw string (without quotes).
    Supported: \\n \\r \\t \\\\ \\0 \\xHH
    Returns a list of byte values (integers 0-255).
    """
    result = []
    i = 0
    while i < len(s):
        if s[i] == '\\':
            if i + 1 >= len(s):
                raise SyntaxError("Trailing backslash in string")
            nxt = s[i + 1]
            if   nxt == 'n':  result.append(0x0A); i += 2
            elif nxt == 'r':  result.append(0x0D); i += 2
            elif nxt == 't':  result.append(0x09); i += 2
            elif nxt == '0':  result.append(0x00); i += 2
            elif nxt == '\\': result.append(0x5C); i += 2
            elif nxt == '"':  result.append(0x22); i += 2
            elif nxt == 'x':
                if i + 3 >= len(s):
                    raise SyntaxError(r"Incomplete \xHH escape sequence")
                hex_str = s[i+2:i+4]
                try:
                    result.append(int(hex_str, 16))
                except ValueError:
                    raise SyntaxError(f"Invalid hex escape \\x{hex_str}")
                i += 4
            else:
                raise SyntaxError(f"Unknown escape sequence '\\{nxt}'")
        else:
            result.append(ord(s[i]))
            i += 1
    return result

def parse_string_literal(token):
    """Extract the raw content from a double-quoted string token.
    Returns a list of byte values after escape processing.
    """
    t = token.strip()
    if not (t.startswith('"') and t.endswith('"') and len(t) >= 2):
        raise SyntaxError(f"Expected a double-quoted string, got: {token}")
    return parse_escape(t[1:-1])

def bytes_to_words_packed(byte_list, line_num):
    """Pack bytes two-per-word, big-endian within the word (high byte first).
    Raises SyntaxError if the byte count is odd.
    """
    if len(byte_list) % 2 != 0:
        raise SyntaxError(
            f"Line {line_num}: Odd byte count ({len(byte_list)}) — "
            "packed strings must have an even number of bytes. "
            "Add a padding byte (e.g. \\0) or use .asciz for automatic null termination.")
    words = []
    for i in range(0, len(byte_list), 2):
        words.append((byte_list[i] << 8) | byte_list[i + 1])
    return words

def assemble_directive(line_str, line_num, labels):
    """Assemble a single directive line. Returns a list of 16-bit words.

    Directives:
      .dw  expr [, expr ...]     — emit one or more raw 16-bit words
      .db  byte, byte ...        — emit bytes packed two-per-word (must be even count)
      .ascii  "string"           — packed, no terminator
      .asciz  "string"           — packed, null-terminated (appends \\0 — must keep even)
      .str    "string"           — alias for .ascii
      .strz   "string"           — alias for .asciz
    """
    parts = line_str.split(None, 1)   # split into directive + rest
    directive = parts[0].lower()
    rest = parts[1].strip() if len(parts) > 1 else ''

    if directive == '.dw':
        words = []
        for tok in re.split(r'\s*,\s*', rest):
            tok = tok.strip()
            if not tok:
                continue
            val = parse_imm(tok, labels)
            if val < -32768 or val > 65535:
                raise SyntaxError(f"Value {val} out of 16-bit range in .dw")
            words.append(val & 0xFFFF)
        return words

    elif directive == '.db':
        byte_vals = []
        for tok in re.split(r'\s*,\s*', rest):
            tok = tok.strip()
            if not tok:
                continue
            val = parse_imm(tok, labels)
            if val < 0 or val > 255:
                raise SyntaxError(f"Byte value {val} out of range in .db")
            byte_vals.append(val)
        return bytes_to_words_packed(byte_vals, line_num)

    elif directive in ('.ascii', '.str'):
        # Reconstruct the full string in case it contained spaces
        byte_vals = parse_string_literal(rest)
        return bytes_to_words_packed(byte_vals, line_num)

    elif directive in ('.asciz', '.strz'):
        byte_vals = parse_string_literal(rest)
        byte_vals.append(0x00)   # null terminator
        return bytes_to_words_packed(byte_vals, line_num)

    else:
        raise SyntaxError(f"Unknown directive '{directive}'")

def directive_word_count(line_str, line_num):
    """Compute the number of 16-bit words emitted by a directive in pass 1.
    We need this to correctly advance PC before labels are fully resolved.
    String literals are parsed in full; .dw counts tokens.
    """
    parts = line_str.split(None, 1)
    directive = parts[0].lower()
    rest = parts[1].strip() if len(parts) > 1 else ''

    if directive == '.dw':
        count = sum(1 for t in re.split(r'\s*,\s*', rest) if t.strip())
        return count

    elif directive == '.db':
        byte_count = sum(1 for t in re.split(r'\s*,\s*', rest) if t.strip())
        if byte_count % 2 != 0:
            raise SyntaxError(
                f"Line {line_num}: Odd byte count in .db — must be even.")
        return byte_count // 2

    elif directive in ('.ascii', '.str'):
        byte_vals = parse_string_literal(rest)
        if len(byte_vals) % 2 != 0:
            raise SyntaxError(
                f"Line {line_num}: String has odd byte count ({len(byte_vals)}). "
                "Add a padding byte or use .asciz.")
        return len(byte_vals) // 2

    elif directive in ('.asciz', '.strz'):
        byte_vals = parse_string_literal(rest)
        total = len(byte_vals) + 1   # +1 for null terminator
        if total % 2 != 0:
            raise SyntaxError(
                f"Line {line_num}: Null-terminated string has odd byte count ({total}). "
                "The string plus its terminator must together be even-length.")
        return total // 2

    else:
        raise SyntaxError(f"Unknown directive '{directive}'")


def parse_mnemonic(raw):
    """Return (op_name_upper, width_or_0, cond_or_0).

    Suffixes are separated by '.' or '/'.
    Width suffixes (w l h d) are only meaningful for data ops; the assembler
    passes them through and lets the CPU CW decide whether to honour them.
    Condition suffixes (z c n) produce a non-zero cond field.
    An unknown suffix raises SyntaxError.
    Conflict: 'd' is a valid width suffix but 'z/c/n' are conditions only.
    """
    parts = re.split(r'[./]', raw)
    op_name = parts[0].upper()
    width = 0
    cond  = 0
    for suffix in parts[1:]:
        s = suffix.lower()
        if s in SIZE_MAP:
            width = SIZE_MAP[s]
        elif s in COND_MAP:
            cond = COND_MAP[s]
        else:
            raise SyntaxError(f"Unknown suffix '{suffix}'")
    return op_name, width, cond

# =============================================================================
# Assembler — two-pass
# =============================================================================

def assemble(source_lines):
    labels  = {}
    parsed  = []   # list of instruction dicts after pass 1

    # ------------------------------------------------------------------
    # PASS 1 — tokenise, record label addresses, compute instruction sizes
    # ------------------------------------------------------------------
    pc = 0
    for line_num, raw_line in enumerate(source_lines, 1):
        # Strip comments (# or ;) and surrounding whitespace
        line = re.split(r'[;#]', raw_line)[0].strip()
        if not line:
            continue

        # Label definition
        if line.endswith(':'):
            label = line[:-1].strip()
            if not label:
                raise SyntaxError(f"Line {line_num}: Empty label")
            if label in labels:
                raise SyntaxError(f"Line {line_num}: Duplicate label '{label}'")
            labels[label] = pc
            continue

        # Directives start with '.'
        first_token = line.split()[0].lower()
        if first_token in DIRECTIVES:
            try:
                instr_size = directive_word_count(line, line_num)
            except SyntaxError as e:
                print(f"Error on line {line_num} ('{line}'): {e}", file=sys.stderr)
                sys.exit(1)
            parsed.append({
                'pc':       pc,
                'line_num': line_num,
                'op':       '__directive__',
                'raw':      line,
            })
            pc += instr_size
            continue

        # Tokenise — commas are optional separators
        parts = line.replace(',', ' ').split()
        try:
            op_name, width, cond = parse_mnemonic(parts[0])
        except SyntaxError as e:
            print(f"Error on line {line_num} ('{line}'): {e}", file=sys.stderr)
            sys.exit(1)

        if op_name not in OPCODES:
            print(f"Error on line {line_num}: Unknown opcode '{op_name}'", file=sys.stderr)
            sys.exit(1)

        args = parts[1:]

        # Determine instruction word count
        instr_size = 1
        if op_name == 'LOADIMM':
            instr_size = 2          # opcode word + 16-bit immediate word
        elif op_name in FMT_CONTROL:
            # Indirect (%rs only) → 1 word; everything else → 2 words
            if len(args) == 1 and args[0].startswith('%'):
                instr_size = 1      # AM_INDIRECT
            else:
                instr_size = 2      # AM_DIRECT or AM_INDIR_OFF

        parsed.append({
            'pc':       pc,
            'line_num': line_num,
            'op':       op_name,
            'width':    width,
            'cond':     cond,
            'args':     args,
            'raw':      line,
        })
        pc += instr_size

    # ------------------------------------------------------------------
    # PASS 2 — emit machine code
    # ------------------------------------------------------------------
    machine_code = []

    for rec in parsed:
        op  = rec['op']
        pc  = rec['pc']

        # ---- directives ----------------------------------------------------
        if op == '__directive__':
            try:
                words = assemble_directive(rec['raw'], rec['line_num'], labels)
                machine_code.extend(words)
            except SyntaxError as e:
                print(f"Error on line {rec['line_num']} (\'{rec['raw']}\'): {e}", file=sys.stderr)
                sys.exit(1)
            continue

        opcode = OPCODES[op]
        args   = rec['args']
        w      = rec['width']
        cond   = rec['cond']

        try:
            # ---- data-width operand formats --------------------------------

            if op in FMT_RDRS:
                if len(args) != 2:
                    raise SyntaxError(f"{op} requires two register operands")
                rd = parse_reg(args[0])
                rs = parse_reg(args[1])
                machine_code.append(encode_instr(opcode, rd, rs, w, cond))

            elif op in FMT_RD:
                if len(args) != 1:
                    raise SyntaxError(f"{op} requires one register operand")
                if op == 'READRIV':
                    rs = parse_reg(args[0])
                    machine_code.append(encode_instr(opcode, 0, rs, w, cond))
                else:
                    rd = parse_reg(args[0])
                    machine_code.append(encode_instr(opcode, rd, 0, w, cond))

            elif op in FMT_RS:
                if len(args) != 1:
                    raise SyntaxError(f"{op} requires one register operand")
                rs = parse_reg(args[0])
                machine_code.append(encode_instr(opcode, 0, rs, w, cond))

            elif op in FMT_NONE:
                if len(args) != 0:
                    raise SyntaxError(f"{op} takes no operands")
                machine_code.append(encode_instr(opcode, 0, 0, w, cond))

            elif op == 'LOADIMM':
                if len(args) != 2:
                    raise SyntaxError("LOADIMM requires %rd and a 16-bit immediate")
                if w == SIZE_MAP['d']:
                    raise SyntaxError(
                        "LOADIMM.d is not supported: the CPU captures one 16-bit word. "
                        "Use two LOADIMM instructions into an even/odd register pair.")
                rd  = parse_reg(args[0])
                imm = parse_imm(args[1], labels)
                if imm < -32768 or imm > 65535:
                    raise SyntaxError(f"Immediate {imm} out of 16-bit range")
                machine_code.append(encode_instr(opcode, rd, 0, 0, 0))
                machine_code.append(imm & 0xFFFF)

            elif op in FMT_CONTROL:
                if w != 0:
                    raise SyntaxError(
                        f"Width suffix not valid on '{op}'. "
                        f"Use condition suffixes (.z .c .n) only.")
                if len(args) == 0:
                    raise SyntaxError(f"{op} requires at least one operand")
                if len(args) == 1 and not args[0].startswith('%'):
                    target = parse_imm(args[0], labels)
                    machine_code.append(encode_instr(opcode, 0, 0, AM_DIRECT, cond))
                    machine_code.append(target & 0xFFFF)
                elif len(args) == 1 and args[0].startswith('%'):
                    rs = parse_reg(args[0])
                    machine_code.append(encode_instr(opcode, 0, rs, AM_INDIRECT, cond))
                elif len(args) == 2 and args[0].startswith('%'):
                    rs     = parse_reg(args[0])
                    offset = parse_imm(args[1], labels)
                    machine_code.append(encode_instr(opcode, 0, rs, AM_INDIR_OFF, cond))
                    machine_code.append(offset & 0xFFFF)
                else:
                    raise SyntaxError(
                        f"Invalid operands for '{op}': {args}\n"
                        f"  Forms: '{op} label'  |  '{op} %rs'  |  '{op} %rs, offset'")

        except SyntaxError as e:
            print(f"Error on line {rec['line_num']} (\'{rec['raw']}\'): {e}", file=sys.stderr)
            sys.exit(1)

    return machine_code

# =============================================================================
# Output Writers
# =============================================================================

def write_bin(machine_code, path):
    """Raw big-endian binary. One 16-bit word per two bytes."""
    with open(path, 'wb') as f:
        for word in machine_code:
            f.write(struct.pack('>H', word & 0xFFFF))

def write_hex(machine_code, path):
    """ASCII hex, one word per line, uppercase. e.g. DEAD"""
    with open(path, 'w') as f:
        for word in machine_code:
            f.write(f"{word:04X}\n")

def write_textio(machine_code, path):
    """ASCII binary, one 16-bit word per line as '0' and '1' characters.
    Directly loadable from VHDL via std.textio + READ(line, bit_vector).

    Example VHDL snippet:
        file f : text open read_mode is "a.out";
        variable l : line;
        variable bv : bit_vector(15 downto 0);
        while not endfile(f) loop
            readline(f, l);
            read(l, bv);
            -- use bv
        end loop;
    """
    with open(path, 'w') as f:
        for word in machine_code:
            f.write(f"{word:016b}\n")

WRITERS = {
    'bin':    (write_bin,    "raw big-endian binary"),
    'hex':    (write_hex,    "ASCII hex"),
    'textio': (write_textio, "ASCII binary (VHDL textio)"),
}

# =============================================================================
# CLI Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="4332 CPU Assembler",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Output formats (-f / --format):
  bin     Raw big-endian binary (default). One word = two bytes.
  hex     ASCII hex, one 4-digit uppercase word per line.
  textio  ASCII binary, one 16-bit word per line as '0'/'1' characters.
          Directly readable by VHDL std.textio READ(line, bit_vector).
""")
    parser.add_argument("input",
        help="Input assembly source file (.asm)")
    parser.add_argument("-o", "--output", default="a.out",
        help="Output file path (default: a.out)")
    parser.add_argument("-f", "--format",
        dest="fmt", choices=WRITERS.keys(), default="bin",
        metavar="FORMAT",
        help="Output format: bin | hex | textio  (default: bin)")
    args = parser.parse_args()

    with open(args.input, 'r') as f:
        source_lines = f.readlines()

    machine_code = assemble(source_lines)

    writer_fn, fmt_label = WRITERS[args.fmt]
    writer_fn(machine_code, args.output)
    print(f"Assembled {len(machine_code)} words → {args.output} ({fmt_label})")

if __name__ == "__main__":
    main()