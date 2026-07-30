# FPGA Integration Contract

This document defines version 1 of the canonical `arm7tdmi_mister` interface.
The wrapper is synthesizable and independent of any particular MiSTer memory
controller. `TASKS.md` §31.9 remains the audited status ledger; framework
builds, PocketStation integration, and hardware evidence remain separate
requirements.

## Clock and reset

Every interface except the inputs explicitly suffixed `_ASYNC` is synchronous
to the rising edge of `CLK`. `CPU_CE` is a clock enable, not a clock. The
wrapper and core never generate or gate a clock.

`RESET_N` asserts asynchronously. Hold it low for at least two `CLK` cycles.
The wrapper and raw core contain parallel two-flop reset-release
synchronizers. Wrapper-owned memory slots, event synchronizers, debug
transport, and the TAP therefore remain reset through the first rising edge
after an arbitrarily timed deassertion and release together with the raw
architectural domain on the second. Reset assertion still cancels them
immediately. `MEM_VALID` and all debug response-valid signals are low.

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
| `MEM_PRIVILEGED` | High for privileged-mode accesses. A translated `LDRT/STRT/LDRBT/STRBT` data access is low while the processor remains privileged. |
| `MEM_LOCK` | High for both transfers of SWP/SWPB. |
| `MEM_SEQUENTIAL` | High when the raw transfer is an S continuation. |
| `MEM_MORE` | Address-phase hint: the data request currently presented has a guaranteed sequential data request after it. High on beats 1..n-1 of an n-word LDM/STM and low on beat n. |
| `MEM_RDATA[31:0]` | Read response, valid with `MEM_READY`. |
| `MEM_ERROR` | Failed completion, valid with `MEM_READY`. |

The target may apply any finite wait by leaving `MEM_READY` low. From the
first cycle of `MEM_VALID` through the accepting edge, address, direction,
write data, byte enables, and all metadata remain stable. On the accepting
edge a write commits selected lanes; a read returns `MEM_RDATA`. When
`MEM_ERROR` is high, the access instead supplies the raw ARM `ABORT` response
and the target must not commit a write side effect.

Translated T-form accesses exist only in ARM Addressing Mode 2: post-indexed
word or unsigned-byte transfers with `P=0,W=1`. They use User memory
permission (`MEM_PRIVILEGED=0`) without changing CPSR mode. ARMv4T
halfword/signed Addressing Mode 3 has no translated form; its `P=0,W=1`
combination is UNPREDICTABLE.

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

## Error behavior

`MEM_ERROR` is meaningful only on an edge with both `MEM_VALID` and
`MEM_READY`. It replaces a successful completion; a target must not commit
selected write lanes on that edge. An error on a code request supplies the
raw Prefetch Abort response, which becomes an architectural exception only
if that fetched instruction reaches Execute. An error on a data request
follows the Data Abort completion and restart rules in
[EXCEPTIONS.md](EXCEPTIONS.md), including the remaining beats of an aborted
LDM/STM.

`MEM_ERROR` while no request is valid, or while `MEM_READY=0`, has no effect.
Reset cancels an outstanding request and any buffered response; a target
must not send a delayed completion from the canceled transaction into the
new reset epoch. Adapters map Wishbone `ERR` or the selected host error
directly to this qualified response and do not retry internally.

### Unified-memory and self-modifying-code contract

The CPU has no instruction or data cache and presents one unified request
stream, but it does have prefetched instructions in its three-stage pipeline.
An accepted store updates external memory according to the handshake above;
it does not snoop or rewrite an opcode that was fetched before that store
completed. Software that modifies code must execute a PC-changing instruction
after the store and before relying on the modified location. The redirect
flushes all younger pipeline entries and refetches the destination. The
memory target must then return the bytes written by the completed store.

No extra cache-maintenance operation is required because this core has no
cache. Conversely, ordinary sequential fall-through is not a coherence
barrier and integrators must not promise that an already-prefetched opcode
changes retroactively. `arm7tdmis_sequence_dependencies_tb` patches such an
opcode with STR, branches to force a refill, and requires execution of the
new word while rejecting the stale one.

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

### Legacy unaligned accesses

The raw r4p3 address remains the calculated byte address even when its low bits
are nonzero. A target must use `MEM_ADDR & ~3` as the physical base of a word
request and ignore `MEM_ADDR[0]` for a halfword request. It must not turn either
request into a cross-boundary modern unaligned transfer:

- `LDR` and the read half of `SWP` receive the naturally aligned 32-bit word;
  the core rotates it right by `8 * MEM_ADDR[1:0]`.
- `STR` and the write half of `SWP` replace the naturally aligned word and are
  otherwise unaffected by `MEM_ADDR[1:0]`.
- Byte requests use the complete address and endian-selected byte lane.
- Odd-address `LDRH`, `LDRSH`, and `STRH` are architecturally
  UNPREDICTABLE. This project deliberately freezes the r4p3 pin-level result:
  the target ignores bit 0 and the core selects the endian halfword lane from
  bit 1. That is a compatibility policy, not an ARM architectural guarantee.

Opcode requests are never unaligned: ARM fetches have `MEM_ADDR[1:0]=0` and
Thumb fetches have `MEM_ADDR[0]=0`. A target can therefore use the same
word/halfword lane contract for instruction memory without guessing discarded
PC bits.

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

Define `ARM7TDMIS_SAVE_STATE` for an additive six-signal architectural
save-state port. It quiesces at a completed-instruction boundary with no live
memory request, exports/imports a versioned 37-word state image, and refetches
the first unexecuted instruction on resume. The exact handshake, physical
register map, Thumb BL boundary behavior, and containing-system snapshot
responsibilities are in [SAVESTATE.md](SAVESTATE.md). The default build omits
the ports and their muxing.

## Public memory-bus adapters

The canonical valid/ready interface remains the versioned CPU boundary. Two
optional stateless adapters are included in the public file list and QIP:

- `arm7tdmi_mister_enable_done_adapter` maps `MEM_VALID` to a selected
  active-high `HOST_ENABLE` convention and qualifies completion with
  `HOST_DONE`. Address, direction, write data, byte enables, code/data,
  privilege, lock, sequential, and more fields are preserved with `HOST_*`
  names. `HOST_DONE`, `HOST_RDATA`, and `HOST_ERROR` may arrive while
  `CPU_CE` is low because the canonical wrapper buffers the response.
- `arm7tdmi_wishbone_adapter` emits one Wishbone B4 classic cycle per
  canonical request. `WB_ADR` is a byte address, `WB_SEL` is the canonical
  lane mask, `WB_LOCK` preserves SWP ownership, and `WB_ERR` becomes
  `MEM_ERROR`. `WB_CTI=000` and `WB_BTE=00`: the adapter deliberately does
  not claim a Wishbone incrementing burst. Optional `WB_CODE`,
  `WB_PRIVILEGED`, `WB_SEQUENTIAL`, and `WB_MORE` sidebands preserve metadata
  for interconnects that can use it.

Neither adapter contains storage, CPU hierarchy, or a clock. The canonical
wrapper guarantees payload stability through completion and owns the
one-response holding register. A bus fabric must return exactly one done,
acknowledge, or error for each enabled request; for a locked SWP/SWPB pair it
must not grant the protected target to another master between the two
`WB_LOCK`/`HOST_LOCK` transfers.

## DFT and scan policy

The FPGA source package does not provide a scan-insertion flow and makes no
ASIC production-test claim. `rtl/top/arm7tdmis_no_dft.sv` is only an explicitly
named compatibility facade: it ties `SO` low, does not consume `SE` or `SI`,
and is excluded from the simulation and FPGA source manifests. There is no
misleading `arm7tdmis_chip` wrapper.

An ASIC consumer that requires scan stitching, ATPG, pad cells, or foundry
test modes must provide and verify that separate technology-owned integration.
Those functions are not implied by the working JTAG debug scan chains.

## Portable FPGA package

`fpga/arm7tdmi_mister.f` is the simulator/tool-neutral ordered source list.
Paths are relative to the file, so a consumer can pass it directly to a tool
that supports Verilog file lists. `fpga/arm7tdmi_mister.qip` contains the same
source set using Quartus's QIP-relative path anchor. A MiSTer project can add
that one QIP and instantiate `arm7tdmi_mister`; it does not need private
include paths or generated source edits.

`fpga/arm7tdmi_mister.qsf` is a standalone Cyclone V part-characterization
example, not a complete MiSTer framework or board project. It selects
`5CSEBA6U23I7`, imports the QIP, the example SDC, and
`fpga/example/arm7tdmi_mister_example_top.sv`. The example top exposes only
the canonical memory and event boundary and trims debug/coprocessor features.
It contains no hierarchy-dependent integration.

`fpga/arm7tdmis_conformance.qsf` and
`fpga/arm7tdmis_conformance.sdc` form a second characterization project whose
top is the raw `arm7tdmis_top`. Every optional debug, JTAG, coprocessor, trace,
endian, and bus signal remains a virtual boundary pin, so synthesis cannot
prove an option constant and trim it. This profile is for feature-complete
synthesis evidence; integrators should continue to consume the canonical
wrapper unless they intentionally need the raw pin-level contract.

From the repository root, run:

```sh
make -C scripts harness-unit
make -C scripts lint-example
make -C scripts quartus-analysis
make -C scripts quartus-compile
make -C scripts quartus-conformance-analysis
make -C scripts quartus-conformance-compile
```

The first command proves that the plain file list and QIP contain exactly the
public wrapper dependencies and that all package paths are portable. The
second elaborates the package and example through the public wrapper only.
The third reads the checked QSF/QIP with the MiSTer Quartus 17 frontend and
runs analysis/elaboration for `5CSEBA6U23I7`.
The fourth performs synthesis, fit, assembly, and four-corner TimeQuest, then
fails on critical warnings, ignored constraints, unconstrained endpoints,
negative slack, a missing image, or a resource-budget overrun. For the
trimmed profile characterized on Quartus Lite 17.0.2, the checked result is
3,500 ALMs, 2,537 registers, six DSPs, no memory bits, +4.025 ns minimum setup
slack, and +0.163 ns minimum hold slack. Fmax, clock-enable, and qualified
PowerPlay figures are in [PERFORMANCE.md](PERFORMANCE.md), with the exact
input-hashed snapshot in `verification/fpga_characterization.json`.
The fifth and sixth commands perform the corresponding analysis-only and full
checked flows for the raw, feature-complete conformance profile.
The supplied SDC assumes a timing-verified 25 MHz standalone `CLK` and a
0.25-to-5 ns synchronous input arrival window. A containing MiSTer project
must replace boundary delays and the clock period with its selected framework
constraints while retaining equivalent reset/CDC treatment.
The raw conformance profile uses a conservative 16 MHz clock and maps the
applicable Table 8-1 capture-edge percentages into its synchronous boundary
delays, with a 0.25 ns target-skew hold margin on nominal zero-hold inputs.
Its checked Quartus Lite 17.0.2 result is 5,038 ALMs, 3,313 registers, six
DSPs, no memory bits, +1.904 ns minimum setup slack, and +0.161 ns minimum
hold slack.

`make -C scripts mister-framework` additionally checks the package in the
official `MiSTer-devel/Template_MiSTer` project pinned at commit
`69b8a2acc6d84dd313b5abcba6a17155287ed3d8`. It injects the public package,
the repository's `emu` integration, and the real-boundary SDC without
modifying the cached upstream checkout, then compiles `sys_top` for
`5CSEBA6U23I7`. The report gate requires the exact 12.500 MHz CPU PLL clock
and fitter seed 4, complete timing coverage, positive four-corner slack,
reviewed upstream-only optional constraint diagnostics, and a nonempty RBF.
The machine-readable report records all report and bitstream hashes for
release archiving.

That `emu` runs the checked generic-SoC ARMv4T smoke ROM. It exposes a
blue/running, green/pass, or red/fail display, a 32-cell MSB-first signature
barcode, and distinct running/pass/fail `LED_USER` behavior. The program,
seven test groups, status/signature values, source-to-ROM equivalence gate,
RBF location, and physical interpretation are specified in
[GENERIC_SOC.md](GENERIC_SOC.md).

## Evidence and current limits

`make -C scripts lint-mister` elaborates this wrapper as the synthesis top.
`make -C scripts quartus-analysis` additionally proves that Quartus 17.0.2
accepts and elaborates the complete public package for the selected Cyclone V.
`make -C scripts quartus-compile` proves fit and timing only for the supplied
trimmed characterization top and its stated 25 MHz boundary assumptions. It
is not evidence for a containing framework's clocks, placement, or board I/O.
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

`make -C scripts integ-mister_dma_arbitration` runs STM, LDM, SWP, and an
aborted LDR while a synthetic DMA master permanently contends for the same
memory. The checked arbiter retains CPU ownership across each DMORE promise
and the complete locked pair, inserts independent CPU/memory stalls, accepts
a response while CPU CE is low, maps one error into Data Abort, and still
proves DMA forward progress in unreserved gaps.

`make -C scripts integ-mister_savestate` enables the optional state port,
quiesces behind a stalled store, mutates and restores all 37 words, compares
two complete post-restore request traces and RAM results, and restores the
architectural boundary between the two Thumb BL halfwords.

The following are intentionally not claimed by this version of the wrapper:

- a PocketStation subsystem or BIOS/software bundle;
- execution/capture of the supplied smoke RBF on physical MiSTer hardware;
- physical MiSTer/PocketStation board evidence.

Those remain visible release blockers in `TASKS.md` rather than implicit
features of the canonical memory handshake.

## Version and compatibility

This document defines canonical wrapper API version 1. The repository
prerelease version is in [`VERSION`](../VERSION), and user-visible changes are
recorded in [`CHANGELOG.md`](../CHANGELOG.md).

Within API version 1, existing ports, polarities, handshake meaning, default
parameter behavior, byte lanes, reset sequencing, and error mapping will not
change incompatibly. Additive optional outputs or parameters must have safe
defaults and receive a project minor-version change. A required port,
polarity change, handshake change, or changed default architectural behavior
requires a new API version and is called out as breaking in the changelog.
Internal hierarchy and verification-only ports are not compatibility
surfaces.
