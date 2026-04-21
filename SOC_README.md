# 4328 SoC — Compact System-on-Chip Design

## Overview

The **4328 SoC** is a compact, self-contained FPGA design that integrates the 4328 CPU core with memory and basic peripherals into a single top-level entity. It is designed for **small FPGA boards with limited I/O**, requiring only **8 external pins**:

- `clk` — System clock
- `reset` — Active-high reset
- `uart_tx` / `uart_rx` — UART for debugging and communication
- `gpio[3:0]` — 4-bit bidirectional GPIO (can be LEDs, buttons, switches, etc.)

This design reduces the external pin count from **58 pins** (original CPU + memory_bus) to **8 pins**, making it suitable for low-cost 32-pin FPGA boards (e.g., TinyFPGA, iCEstick, or custom boards).

---

## Architecture

### Block Diagram

```
┌────────────────────────────────────────────────┐
│                   4328 SoC                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │   CPU    │  │   ROM    │  │  RAM0    │     │
│  │  (core)  │  │  4K×16   │  │  4K×16   │     │
│  └──────────┘  └──────────┘  └──────────┘     │
│       │             │              │           │
│       └─────────────┴──────────────┘           │
│                Internal Bus                    │
│  ┌──────────┐  ┌──────────────────────┐       │
│  │  RAM1    │  │  Peripherals         │       │
│  │  4K×16   │  │  (GPIO, UART, Timer) │       │
│  └──────────┘  └──────────────────────┘       │
└────────────────────────────────────────────────┘
         │         │          │         │
        clk     reset      uart_tx   gpio[3:0]
                          uart_rx
```

### Memory Map

| Address Range   | Device       | Size  | Notes                      |
|-----------------|--------------|-------|----------------------------|
| `0x0000-0x0FFF` | ROM          | 4K    | Writable after boot        |
| `0x4000-0x4FFF` | Peripherals  | 4K    | Memory-mapped I/O          |
| `0x8000-0x8FFF` | RAM Bank 0   | 4K    | General-purpose SRAM       |
| `0xC000-0xCFFF` | RAM Bank 1   | 4K    | General-purpose SRAM       |

### Peripheral Registers

All peripherals are memory-mapped starting at `0x4000`:

| Address  | Register      | Bits      | R/W | Description                           |
|----------|---------------|-----------|-----|---------------------------------------|
| `0x4000` | `GPIO_DATA`   | [3:0]     | R/W | GPIO pin values                       |
| `0x4001` | `GPIO_DIR`    | [3:0]     | R/W | GPIO direction (0=input, 1=output)    |
| `0x4002` | `UART_TX`     | [7:0]     | W   | Write byte to transmit (placeholder)  |
| `0x4003` | `UART_RX`     | [7:0]     | R   | Read received byte (placeholder)      |
| `0x4004` | `UART_STATUS` | [0] [1]   | R   | [0]=tx_busy, [1]=rx_valid             |
| `0x4005` | `TIMER_LO`    | [15:0]    | R/W | Timer match value (low word)          |
| `0x4006` | `TIMER_HI`    | [7:0]     | R/W | Timer match value (high byte)         |

**Note:** The UART module is currently a placeholder. To use UART, implement a proper baud-rate generator and shift-register-based TX/RX logic.

---

## Build Instructions

### 1. Analyze and Elaborate (GHDL)

```bash
./build.sh soc
```

This compiles and elaborates the SoC design for synthesis readiness checks.

### 2. Generate Vivado Project

```bash
./build.sh vivado-soc
```

This creates `vivado_soc.tcl` which sets up a Vivado project with the minimal source files:
- `ram.vhd`
- `memory.vhd`
- `cpu.vhd`
- `soc.vhd`

### 3. Synthesize with Vivado

```bash
vivado -mode batch -source vivado_soc.tcl
```

Or open the project in GUI mode:

```bash
vivado vivado_soc/4328_soc.xpr
```

---

## Pin Constraints

Edit `soc_constraints.xdc` to match your FPGA board's pinout:

```tcl
## Example for a hypothetical 32-pin board:
set_property -dict { PACKAGE_PIN A1 IOSTANDARD LVCMOS33 } [get_ports { clk }]
set_property -dict { PACKAGE_PIN B2 IOSTANDARD LVCMOS33 } [get_ports { reset }]
set_property -dict { PACKAGE_PIN C3 IOSTANDARD LVCMOS33 } [get_ports { uart_tx }]
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]
set_property -dict { PACKAGE_PIN E5 IOSTANDARD LVCMOS33 } [get_ports { gpio[0] }]
set_property -dict { PACKAGE_PIN F6 IOSTANDARD LVCMOS33 } [get_ports { gpio[1] }]
set_property -dict { PACKAGE_PIN G7 IOSTANDARD LVCMOS33 } [get_ports { gpio[2] }]
set_property -dict { PACKAGE_PIN H8 IOSTANDARD LVCMOS33 } [get_ports { gpio[3] }]
```

Adjust the clock period in the XDC to match your board's oscillator frequency.

---

## Resource Utilization (Estimated)

For a Xilinx Artix-7 XC7A35T (Basys 3):

| Resource       | Usage (Approx.) | Available | %   |
|----------------|-----------------|-----------|-----|
| LUTs           | 2500-3500       | 20,800    | 15% |
| FFs            | 1200-1800       | 41,600    | 4%  |
| BRAM (18K)     | 16-20           | 50        | 40% |
| DSP Slices     | 0               | 90        | 0%  |

The design fits comfortably on small FPGAs (even XC7A35T or ICE40 HX8K with external SRAM).

---

## Interrupt Sources

- **IRQ0:** 24-bit timer (fires when `timer_count == timer_match`)
- **IRQ1:** UART (placeholder, implement RX interrupt logic)
- **IRQ2-3:** Reserved (tie to external GPIO or internal peripherals)

---

## Next Steps

1. **Implement UART TX/RX:**  
   Replace the placeholder with a proper UART module (baud rate = `clk_freq / 16 / baud`).

2. **Add More Peripherals:**  
   Extend the peripheral register map (e.g., SPI, I²C, PWM) while staying within the 4K peripheral address space.

3. **Optimize for Smaller FPGAs:**  
   Reduce RAM banks to 2K each, or use external SRAM via GPIO if on-chip BRAM is limited.

4. **Flash Programming:**  
   Implement SPI flash boot loader to initialize ROM from external flash at power-on.

---

## Comparison: Original vs. Compact SoC

| Feature            | Original Design       | Compact SoC       |
|--------------------|-----------------------|-------------------|
| Top-level entity   | `memory_bus`          | `soc`             |
| External pins      | **58 pins**           | **8 pins**        |
| Memory            | External signals      | Internal entities |
| Peripherals        | Exposed I/O           | Memory-mapped     |
| Suitable for       | Large dev boards      | 32-pin FPGAs      |

---

## License

Same as the main 4328 CPU project.
