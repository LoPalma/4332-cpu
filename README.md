# 4332 CPU
A 16-bit microcoded CISC (with a flavor of RISC and a NISC infrastructure)
tested for the Artix-7 FPGA. For just 1061 LUTs (which are being optimized
to be as low as ~750) you get:

- Privilege modes
- Hardware interrupts
- Microcode
- Suffix based condition system

## What makes it special

- Adding an opcode is a single `make_cw()` call in ROM
- Full interrupt system with 8 vectors, hardware context save,
  privilege fault detection
- Comes with an assembler, a debugger/VM, and a self-checking testbench.


# Quick start
Clone this repo, and at toplevel, run:

````bash
chmod +x build.sh
python3 as.py -f textio firmware.4332 -o firmware
mv firmware .. && cd ..
./build.sh
./build.sh vivado
````

For very detailed information about the processor,
refer to the documentation: `doc/4332_trm.pdf`.
