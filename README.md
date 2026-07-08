# Full-Duplex SPI Master/Slave in SystemVerilog

This project implements and verifies a configurable **SPI (Serial Peripheral Interface) master and slave** in SystemVerilog. The design supports full-duplex transfer, 12-bit default data words, configurable clock polarity and phase, and a self-checking class-based testbench that runs all four standard SPI modes.

The SPI theory used in this project follows the standard 4-wire SPI model described by Analog Devices in [Introduction to SPI Interface](https://www.analog.com/en/resources/analog-dialogue/articles/introduction-to-spi-interface.html).

## Project Highlights

- Full-duplex SPI communication over `MOSI` and `MISO`
- Parameterized data width through `DW`
- Configurable SPI mode using `CPOL` and `CPHA`
- Master-generated `SCLK` with configurable divider
- Active-low chip select `cs`
- Synthesizable single-edge slave implementation
- Self-checking testbench with generator, driver, monitor, scoreboard, and environment classes
- Verification across all four SPI modes:

| SPI Mode | CPOL | CPHA | Clock Idle | Sampling Edge | Shifting Edge |
|---|---:|---:|---|---|---|
| Mode 0 | 0 | 0 | Low | Rising | Falling |
| Mode 1 | 0 | 1 | Low | Falling | Rising |
| Mode 2 | 1 | 0 | High | Falling | Rising |
| Mode 3 | 1 | 1 | High | Rising | Falling |

## Repository Structure

```text
.
+-- design.sv              # SPI master, SPI slave, and top-level wrapper
+-- tb.sv                  # Self-checking SystemVerilog testbench
+-- README.md              # Project overview and quick-start guide
+-- DOCUMENTATION.md       # Detailed design and verification documentation
+-- console/               # Console-result screenshots
+-- waveforms/             # Waveform screenshots for all SPI modes
```

## Design Overview

The top-level design connects one SPI master to one SPI slave:

```text
master mosi ---> slave
master miso <--- slave
master sclk ---> slave
master cs   ---> slave
```

Both devices transmit and receive at the same time. During each transaction:

- `m_din` is shifted from the master to the slave and appears as `s_dout`.
- `s_din` is shifted from the slave to the master and appears as `m_dout`.
- `master_done` pulses when the transfer is complete.
- `slave_done` pulses when the slave has received a full word.

The default data width is 12 bits, but the RTL is parameterized.

## Files

### `design.sv`

Contains three modules:

- `spi_master`: Generates `SCLK`, controls `CS`, transmits on `MOSI`, receives on `MISO`, and produces `done`.
- `spi_slave`: Uses the master's `SCLK` and `CS`, receives `MOSI`, transmits `MISO`, and supports all CPOL/CPHA modes.
- `top`: Instantiates and connects the master and slave for verification.

### `tb.sv`

Contains:

- `spi_if` interface
- `transaction` class
- `generator`
- `driver`
- `monitor`
- `scoreboard`
- `environment`
- `tb_spi #(CPOL, CPHA)` parameterized testbench
- `tb_top` that runs modes 0, 1, 2, and 3 sequentially

## How To Simulate

Use a SystemVerilog simulator with class/interface support, such as QuestaSim, Xcelium, VCS, Riviera-PRO, or Vivado xsim.

Example flow:

```sh
vlog design.sv tb.sv
vsim tb_top
run -all
```

For Vivado xsim, add both files to a simulation project, set `tb_top` as the simulation top, and run behavioral simulation.

The testbench writes a waveform dump:

```text
dump.vcd
```

## Expected Verification Result

The testbench runs 5 random transactions for each SPI mode, for a total of 20 full-duplex transfers. A passing run ends with:

```text
ALL 4 CPOL/CPHA COMBINATIONS COMPLETE
TOTAL TRANSACTIONS : 20
TOTAL ERROR COUNT  : 0
```

Saved result screenshots are available in:

- `console/Overall.png`
- `console/cpol_cpha_00.png`
- `console/cpol_cpha_01.png`
- `console/cpol_cpha_10.png`
- `console/cpol_cpha_11.png`

Waveform screenshots for master and slave behavior are stored under `waveforms/`.

## Documentation

For a detailed explanation of SPI theory, RTL architecture, timing behavior, CPOL/CPHA handling, and testbench methodology, see [DOCUMENTATION.md](DOCUMENTATION.md).

## Reference

- Piyu Dhaker, Analog Devices, [Introduction to SPI Interface](https://www.analog.com/en/resources/analog-dialogue/articles/introduction-to-spi-interface.html)
