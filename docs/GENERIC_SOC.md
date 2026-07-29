# Generic SoC example

`examples/generic_soc/arm7tdmi_generic_soc.sv` is a synthesizable,
framework-neutral example around the canonical `arm7tdmi_mister` API. It
contains no vendor primitive, generated clock, private hierarchy reference,
runtime firmware loader, or PocketStation-specific behavior.

## Memory map

| Range | Device | Behavior |
|---|---|---|
| `0x0000_0000`–`0x0000_03ff` | ROM | Read-only, asynchronous 32-bit words; writes complete with `MEM_ERROR` |
| `0x1000_0000`–`0x1000_03ff` | RAM | 1 KiB asynchronous-read RAM with byte-enable writes |
| `0x2000_0000` | Timer count | Read-only 32-bit master-clock count |
| `0x2000_0004` | Timer compare | Word-readable/writable comparison value |
| `0x2000_0008` | Timer control | Bit 0 enables counting; bit 1 enables IRQ |
| `0x2000_000c` | Timer status | Bit 0 is pending; writing one clears pending and disables the timer |
| `0x2000_1000` | UART transmit | Word write enters the one-byte transmit holding register |
| `0x2000_1004` | UART status | Bit 0 is `UART_TX_READY`; bit 1 is `UART_TX_VALID` |

Unmapped requests complete with `MEM_ERROR`; they cannot deadlock the CPU.
Timer and UART registers require word writes. The ROM program is listed in
`examples/generic_soc/program.S` and encoded directly in a synthesizable ROM
function, so synthesis never depends on a working directory or external
image.

`UART_TX_VALID` and `UART_TX_DATA` remain stable until a rising `CLK` edge
with `UART_TX_READY`. All UART signals and `CPU_CE` are synchronous to
`CLK`. The timer runs from `CLK`, independently of CPU stalls, and its
active-high level is connected to the wrapper-owned IRQ synchronizer.

## Executable example

The ARMv4T program writes and reads RAM, emits `G`, starts the timer, unmasks
IRQ, clears the interrupt in its handler, and emits `I`. The fail-hard test
holds the first UART byte under backpressure, randomizes `CPU_CE`, requires
both bytes in order, and observes the timer interrupt:

```sh
make -C scripts lint-generic-soc
make -C scripts lint-generic-soc-slang
make -C scripts sim-generic-soc
```

The first compile uses Verilator 5.x. The independent frontend compile uses
Slang 11.0. CI downloads the official `v11.0` Linux archive and verifies
SHA-256
`951a170e10e25e54c91565030acfdfc11c3226714ebf225a18ad4166a898d8a4`
before use. The Slang command enables `--allow-use-before-declare` because
the production core uses legal module-scope forward references accepted by
Quartus and Verilator; the compile otherwise completes with zero warnings.
All three commands are mandatory regression phases.
