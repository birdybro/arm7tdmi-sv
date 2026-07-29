# FPGA Integration Contract

This document defines version 1 of the canonical `arm7tdmi_mister` interface.
The wrapper is synthesizable and independent of any particular MiSTer memory
controller. `TASKS.md` §31.9 remains the audited status ledger; save states,
framework builds, PocketStation integration, bus adapters, and hardware
evidence remain separate requirements.

## Clock and reset

Every interface except the inputs explicitly suffixed `_ASYNC` is synchronous
to the rising edge of `CLK`. `CPU_CE` is a clock enable, not a clock. The
wrapper and core never generate or gate a clock.

`RESET_N` asserts asynchronously. Hold it low for at least two `CLK` cycles.
The raw core contains a two-flop reset-release synchronizer, so architectural
execution remains reset for two rising edges after deassertion. Reset clears
the memory request/response slots, event synchronizers, debug transport, TAP,
and core; `MEM_VALID` and all debug response-valid signals are low.

## Memory request

The wrapper permits one outstanding request. These signals form one payload:

| Signal | Meaning |
|---|---|
| `MEM_VALID` | The request and every payload field are valid. |
| `MEM_READY` | The target accepts/completes the request on this rising edge. |
| `MEM_ADDR[31:0]` | Byte address. |
| `MEM_WRITE` | High for a write, low for a read. |
| `MEM_WDATA[31:0]` | Lane-aligned write data. |
| `MEM_BYTE_ENABLE[3:0]` | Active byte lanes for reads and writes. |
| `MEM_CODE` | High for an opcode fetch, low for data. |
| `MEM_PRIVILEGED` | High outside User mode. |
| `MEM_LOCK` | High for both transfers of SWP/SWPB. |
| `MEM_SEQUENTIAL` | High when the raw transfer is an S continuation. |
| `MEM_MORE` | High only when another block-transfer beat is guaranteed. |
| `MEM_RDATA[31:0]` | Read response, valid with `MEM_READY`. |
| `MEM_ERROR` | Failed completion, valid with `MEM_READY`. |

The target may apply any finite wait by leaving `MEM_READY` low. From the
first cycle of `MEM_VALID` through the accepting edge, address, direction,
write data, byte enables, and all metadata remain stable. On the accepting
edge a write commits selected lanes; a read returns `MEM_RDATA`. When
`MEM_ERROR` is high, the access instead supplies the raw ARM `ABORT` response
and the target must not commit a write side effect.

`MEM_READY` is independent of `CPU_CE`. If a target completes while CPU CE is
low, the wrapper removes `MEM_VALID`, stores `MEM_RDATA/MEM_ERROR`, and waits.
The core consumes that stored response exactly once on a later rising edge
with CPU CE high.

The minimum externally visible latency is one `CLK` edge: a raw address phase
is captured into the request slot on one enabled edge and can be accepted on
a later edge. There is no combinational raw-core-to-ready path.

```text
CLK edge       A            B ...          C             D
CPU_CE         1            x              0             1
raw core       presents X   held           held          consumes response
MEM_VALID      0 -> 1       1              1 -> 0        0 / next request
MEM_READY      0            0              1             x
action         capture X    wait           buffer reply  advance once
```

A completing response and the already-present next raw address phase may be
consumed/captured on the same CPU-enabled edge. This permits back-to-back
requests without duplicating either transaction.

### Byte lanes

`MEM_WDATA` uses the same lane placement as the raw ARM bus. The byte enables
for byte address `A[1:0]` are:

| Size | Little endian | Big endian |
|---|---|---|
| word | `1111` | `1111` |
| halfword at `A[1]=0` | `0011` | `1100` |
| halfword at `A[1]=1` | `1100` | `0011` |
| byte | `0001 << A[1:0]` | `0001 << ~A[1:0]` |

The active lanes select the corresponding eight-bit slices of `MEM_WDATA` or
`MEM_RDATA`. The `BIG_ENDIAN` synthesis parameter is frozen for an instance;
changing it requires reset and a different build.

`MEM_SEQUENTIAL` and `MEM_MORE` are optimization hints, not permission to
merge handshakes. Every beat still has its own `MEM_VALID && MEM_READY`
completion. `MEM_LOCK` is an arbitration exclusion request; an adapter must
retain bus ownership across the complete locked pair.

## Event CDC

`IRQ_ASYNC` and `FIQ_ASYNC` use active-high board/framework polarity. The
wrapper passes each through two rising-edge synchronizer flops and converts it
to the raw core's active-low synchronous pin. The debug policy/event inputs
`DEBUG_ENABLE_ASYNC`, `DBGRQ_ASYNC`, `DBGBREAK_ASYNC`, and both
`DBGEXT_ASYNC` bits use the same two-flop boundary.

These are level synchronizers. An asynchronous source must hold a request long
enough to be observed for two `CLK` edges; pulses shorter than that require a
toggle/pulse-capture bridge in the producer. The memory interface, `CPU_CE`,
coprocessor handshake, and `DBG_STEP_*` transport are already synchronous and
must not cross clock domains without an external bridge.

## Optional interfaces

The synthesis parameters are:

| Parameter | Default | Contract |
|---|---:|---|
| `BIG_ENDIAN` | 0 | Selects architectural data/fetch lane mapping. |
| `ENABLE_DEBUG` | 0 | Enables synchronized debug events and the same-clock step transport. False ties every internal debug request off. |
| `ENABLE_COPROCESSOR` | 0 | Enables external `CPA/CPB` claiming. False forces the internal handshake absent; non-CP14 instructions enter Undefined. |
| `JTAG_VERSION`, `JTAG_PART_NUMBER`, `JTAG_MANUFACTURER_ID` | r4p3 compatibility values | Product-owned IDCODE fields when debug is enabled. |

The coprocessor output pins remain observable in either profile. With
`ENABLE_COPROCESSOR=1`, `CPA` and `CPB` must be produced synchronously in the
same `CLK` domain and follow [COPROCESSOR.md](COPROCESSOR.md). With it false,
those inputs are ignored and no internal port floats.

The `DBG_STEP_*` interface is the explicitly synchronous transport specified
in [DEBUG.md](DEBUG.md). It remains isolated when debug is disabled. It is not
an asynchronous TCK/RTCK interface.

## Portable FPGA package

`fpga/arm7tdmi_mister.f` is the simulator/tool-neutral ordered source list.
Paths are relative to the file, so a consumer can pass it directly to a tool
that supports Verilog file lists. `fpga/arm7tdmi_mister.qip` contains the same
source set using Quartus's QIP-relative path anchor. A MiSTer project can add
that one QIP and instantiate `arm7tdmi_mister`; it does not need private
include paths or generated source edits.

`fpga/arm7tdmi_mister.qsf` is a standalone Cyclone V/DE10-Nano elaboration
example, not a complete MiSTer framework project. It selects
`5CSEBA6U23I7`, imports the QIP, the example SDC, and
`fpga/example/arm7tdmi_mister_example_top.sv`. The example top exposes only
the canonical memory and event boundary and trims debug/coprocessor features.
It contains no hierarchy-dependent integration.

From the repository root, run:

```sh
make -C scripts harness-unit
make -C scripts lint-example
make -C scripts quartus-analysis
```

The first command proves that the plain file list and QIP contain exactly the
public wrapper dependencies and that all package paths are portable. The
second elaborates the package and example through the public wrapper only.
The third reads the checked QSF/QIP with the MiSTer Quartus 17 frontend and
runs analysis/elaboration for `5CSEBA6U23I7`.
The supplied SDC assumes a 50 MHz standalone `CLK`; a containing MiSTer
project must replace boundary delays and the clock period with its selected
framework constraints while retaining equivalent reset/CDC treatment.

## Evidence and current limits

`make -C scripts lint-mister` elaborates this wrapper as the synthesis top.
`make -C scripts quartus-analysis` additionally proves that Quartus 17.0.2
accepts and elaborates the complete public package for the selected Cyclone V.
This is not a fit or timing-closure claim.
`make -C scripts integ-mister_wrapper` runs a real ARM program through this
interface with deterministic randomized CPU enables and memory waits. The
test checks request stability and exact handshake count, accepts a response
while CE is stopped, verifies code/data and N/S metadata, and performs
word/byte/halfword writes plus readback.

`make -C scripts integ-mister_cdc_reset` delivers asynchronous IRQ/FIQ levels
during normal execution, a held request, and a buffered response, then checks
the architectural handlers. It also asserts reset in the middle of an
outstanding request, requires immediate cancellation, and proves a clean
reset-vector restart.

`make -C scripts integ-mister_profiles` elaborates all eight combinations of
`BIG_ENDIAN`, `ENABLE_DEBUG`, and `ENABLE_COPROCESSOR` concurrently. Every
profile executes the same program. The test distinguishes both byte-lane
maps, proves disabled/live coprocessor claiming, and shifts the default
IDCODE through every debug-enabled instance while requiring complete
isolation from every trimmed instance.

The following are intentionally not claimed by this version of the wrapper:

- save-state export/import or quiescent snapshot;
- a PocketStation subsystem or BIOS/software bundle;
- MiSTer framework integration, fitted/timed, or on-board evidence;
- DMA/arbitration behavior beyond the exposed lock/more hints; or
- Avalon-MM, Wishbone, or MiSTer `enable/done` thin adapters.

Those remain visible release blockers in `TASKS.md` rather than implicit
features of the canonical memory handshake.
