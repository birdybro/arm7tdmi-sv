# Architectural save states

`arm7tdmi_mister` has an optional, versioned architectural state port for a
containing MiSTer core or other FPGA system. Define `ARM7TDMIS_SAVE_STATE`
for every compilation unit to expose the port. Builds without that macro
retain the original wrapper ports and synthesize no save-state muxes.

The schema is version `1.0` (`STATE_SCHEMA_VERSION = 32'h0001_0000`) and has
exactly 37 32-bit words (`STATE_WORDS = 37`). The version is wrapper metadata,
not an extra state word. A host image must store the schema version alongside
the 37 words and reject an unknown major version.

## Handshake

The interface is synchronous to `CLK`:

| Signal | Direction | Contract |
|---|---|---|
| `STATE_REQUEST` | input | Hold high to request and retain a quiescent CPU. |
| `STATE_READY` | output | High when the CPU is quiescent and state access is allowed. |
| `STATE_WRITE` | input | With `STATE_READY`, writes one word on this rising edge. |
| `STATE_INDEX[5:0]` | input | Selects one of the 37 schema words. |
| `STATE_WDATA[31:0]` | input | Import value for a state write. |
| `STATE_RDATA[31:0]` | output | Combinational export value for the selected word. |

The save sequence is:

1. Assert `STATE_REQUEST` and keep it asserted.
2. Wait for `STATE_READY`. The request may wait indefinitely if `CPU_CE`
   never becomes high or a memory/coprocessor operation never completes.
3. While ready, select each `STATE_INDEX` and sample `STATE_RDATA`. Keep
   `STATE_WRITE` low.
4. Snapshot the containing system at the same boundary, then deassert
   `STATE_REQUEST` to resume.

Restore uses the same entry sequence. While `STATE_READY` is high, present
each index/value and pulse `STATE_WRITE` for one rising edge. Write all 37
words from one schema-compatible image before restoring the containing
system and deasserting `STATE_REQUEST`. Writes outside indices 0 through 36,
or writes without `STATE_READY`, are ignored. `STATE_RDATA` is only
contractual while ready; an out-of-range selection reads zero.

On the edge that raises ready, the current instruction has completed all
architectural writeback and no CPU memory request is live. A pending memory
request must complete first. A speculative next opcode request can be
discarded because it has no architectural effect. Multicycle multiply,
block-transfer, swap, coprocessor, abort, exception, and ordinary instruction
paths all stop only after their final architectural microcycle.

Deasserting `STATE_REQUEST` pulses the internal resume operation. It discards
all pipeline and bus-history microstate and refetches the first unexecuted
instruction recorded in word 30. Architectural register and PSR state is
not reset. Execution advances on a later edge with `CPU_CE` high.

Save-state entry is intentionally unavailable while the CPU is in debug halt
or executing an injected debug instruction. Use the feature with
`ENABLE_DEBUG=0`, or ensure the debugger is detached and the CPU is running
before asserting `STATE_REQUEST`.

## Version 1.0 word map

The map contains all 30 physical r0-r14 storage locations, the restart PC,
CPSR, and every physical SPSR. Shared names describe physical storage, not a
copy per mode.

| Index | Architectural state |
|---:|---|
| 0-7 | Shared `r0` through `r7` |
| 8-12 | Non-FIQ `r8` through `r12` |
| 13-14 | User/System `r13`, `r14` |
| 15-19 | FIQ `r8_fiq` through `r12_fiq` |
| 20-21 | FIQ `r13_fiq`, `r14_fiq` |
| 22-23 | IRQ `r13_irq`, `r14_irq` |
| 24-25 | Supervisor `r13_svc`, `r14_svc` |
| 26-27 | Abort `r13_abt`, `r14_abt` |
| 28-29 | Undefined `r13_und`, `r14_und` |
| 30 | Restart PC: byte address of the first unexecuted instruction |
| 31 | CPSR |
| 32 | SPSR_fiq |
| 33 | SPSR_irq |
| 34 | SPSR_svc |
| 35 | SPSR_abt |
| 36 | SPSR_und |

Word 30 is an execution address, not the architecturally visible r15 value.
It must be word aligned when CPSR.T is zero and halfword aligned when CPSR.T
is one. PSR words use the processor's complete internal 32-bit representation.
A host must restore values previously exported by the same schema; arbitrary
invalid mode/state combinations are not a supported image format.

The Thumb BL pair needs no hidden prefix latch. The prefix architecturally
writes LR, and a snapshot between the halfwords records that physical LR plus
the suffix address in word 30. On restore the suffix reads LR normally,
branches, and replaces LR with its architectural return value.

## Whole-system determinism

This port snapshots CPU architectural state only. A deterministic whole-core
save state must atomically preserve and restore RAM, writable ROM/flash
models, peripheral registers, timers, interrupt-controller state, DMA
ownership, and any other component capable of affecting CPU-visible input.
Keep `MEM_READY`, response data/error, interrupts, coprocessor handshakes, and
debug events inactive or reproduce their containing-system state across
restore. Do not let another bus master mutate CPU-visible memory between the
CPU boundary and the system snapshot.

`tb/integration/arm7tdmis_mister_savestate_tb.sv` is the executable contract.
It requests state behind a stalled store, proves ready has no live request,
reads and independently overwrites every word, restores CPU and RAM twice,
and compares complete accepted-request traces and final memory. It also
imports the precise boundary between Thumb BL halfwords and proves the suffix
target and link value. Run it with:

```sh
make -C scripts integ-mister_savestate
```
