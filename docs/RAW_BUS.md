# Raw ARM7TDMI-S Bus Contract

This document defines the pin-level memory contract of `arm7tdmis_top`. It is
for integrations that intentionally use the ARM7TDMI-S-style raw interface.
Most FPGA systems should instantiate `arm7tdmi_mister` and use the
valid/ready interface documented in [INTEGRATION.md](INTEGRATION.md).

The normative source is ARM DDI 0234B, principally Chapters 3 and 7. This
document fixes the edge convention and integration policy where the raw ARM
interface otherwise invites an off-by-one-cycle implementation.

## Edge and phase model

All raw inputs and outputs are synchronous to the rising edge of `CLK`.
`CLKEN` is a clock enable, not a separate clock and not a ready signal.

An enabled address phase is accepted on a rising edge when `CLKEN=1`.
`ADDR`, `WRITE`, `SIZE`, `PROT`, `LOCK`, `TRANS`, and `DMORE` describe that
phase. `TRANS=N` or `TRANS=S` accepts a main-memory request; `I` and `C` do
not.

The response belongs to the most recently accepted active address phase:

```text
interval             before edge A       A -> B                 at edge B
address-class pins   request X            request Y              Y accepted
memory action         X accepted          respond to X           X completes
read response         previous            RDATA for X            core samples
write response        previous            WDATA for X            memory samples
abort response        previous            ABORT for X            core samples
```

Therefore:

- latch an active address and its controls at edge A;
- for a read, drive lane-aligned `RDATA` with setup to the next enabled edge;
- for a write, sample lane-aligned `WDATA` at the next enabled edge;
- drive `ABORT` with the response, not with a later address that happens to
  share the pins;
- do not interpret current `PROT`, `SIZE`, or `WRITE` as metadata for current
  `RDATA`/`WDATA`. Retain those fields from the accepted address phase.

`tb/integration/arm7tdmis_memory.sv` is the executable zero-wait reference for
this convention.

## Clock enable and wait states

When `CLKEN=0`, no address is accepted and no response completes. Hold the
response for the pending phase until an enabled rising edge. Do not count an
active `TRANS` value repeatedly while the clock is stopped.

`nRESET` asserts asynchronously. Hold it low for at least two `CLK` cycles.
The top-level reset-release synchronizer keeps the core in reset for two
rising edges after deassertion. Reset does not depend on `CLKEN`; it cancels
the active processor transaction and returns the bus controls to idle.
`nIRQ`, `nFIQ`, raw debug controls, memory response, coprocessor handshake,
and JTAG clock-enable inputs are synchronous unless a containing wrapper
explicitly synchronizes them.

The core holds its architectural state and bus outputs stable across a
continued stop. Appendix B permits outputs to settle in the first cycle in
which `CLKEN` becomes low; consumers must take their reference after that
first disabled edge. `arm7tdmis_raw_bus_checker` enforces stability on
subsequent stopped cycles.

To insert a raw-bus wait state, deassert `CLKEN` for the processor and the
attached raw memory pipeline together. If a target has an independent
valid/ready interface, use `arm7tdmi_mister`; its bridge buffers a response
that arrives while `CPU_CE=0` and presents it exactly once when the core can
advance.

## TRANS and burst history

`TRANS[1:0]` uses Table 3-1/Table 7-1 encodings:

| Value | Name | Main-memory meaning |
|---|---|---|
| `00` | I | Internal/idle; no request |
| `01` | C | Coprocessor transfer; no main-memory request |
| `10` | N | Nonsequential request; starts a memory stream |
| `11` | S | Sequential request; continues a specified stream |

An S address is legal only in one of these histories:

1. the previous enabled active phase has identical direction, size, protection,
   and lock controls, and the address advances by four for a word or two for
   a halfword;
2. an I phase is merged into an S phase at the identical address with
   identical controls, as shown by the Chapter 7 instruction timings;
3. the first word of a multiword LDC/STC follows its accepted coprocessor
   phase (`CPnI=0`) and uses the special S-cycle start specified by Tables
   7-18 and 7-19.

Byte requests are isolated N cycles. `SIZE=2'b11` is reserved. Address
arithmetic wraps modulo 32 bits.

Reset, a redirect, an exception vector, and a first access without qualifying
history use N. A fetch is not automatically sequential merely because the
previous request was also a fetch.

## Address, size, and lanes

`ADDR` is a byte address. `SIZE` is byte `00`, halfword `01`, or word `10`.
The r4p3 compatibility policy for legacy unaligned accesses is:

- a word target uses `ADDR & 32'hffff_fffc` as its physical word address;
- a halfword target ignores `ADDR[0]`;
- byte requests use the complete address;
- the raw address pins still retain the calculated low bits.

`WDATA` and `RDATA` are lane-aligned:

| Transfer | Little endian (`CFGBIGEND=0`) | Big endian (`CFGBIGEND=1`) |
|---|---|---|
| word | bits `[31:0]` | bits `[31:0]` |
| halfword, `ADDR[1]=0` | bits `[15:0]` | bits `[31:16]` |
| halfword, `ADDR[1]=1` | bits `[31:16]` | bits `[15:0]` |
| byte | lane `ADDR[1:0]` | lane `~ADDR[1:0]` |

Inactive `RDATA` is don't-care to the processor. This project drives zero in
its behavioral memory to keep simulations deterministic.

`CFGBIGEND` is static configuration. It may be selected during reset but must
not change while `nRESET=1`. A raw integrator violation is a fatal protocol
error in verification; hardware behavior after such a change is not defined.

## Protection and direction

`WRITE=0` is a read and `WRITE=1` is a write.

`PROT[0]=0` identifies an opcode access and `PROT[0]=1` a data access.
`PROT[1]=0` identifies User permission and `PROT[1]=1` privileged permission.
A translated ARM T-form data transfer uses User permission even while CPSR
remains in a privileged mode.

The pipeline can advertise a data-class I phase or a data-class merged fetch.
`PROT[0]=1` alone does not make an I/C phase a memory request.

## ABORT

`ABORT` is meaningful only as the response to an accepted N/S address. The
core samples it only on an enabled response edge:

- an aborted opcode response is tagged and becomes Prefetch Abort only if the
  instruction survives to Execute;
- an aborted data response follows the instruction-specific Data Abort rules;
- an assertion associated with I/C, or one wholly contained in a `CLKEN=0`
  interval, is ignored.

Keep `ABORT` and `RDATA` stable together until the enabled completion edge.
An attached memory must not commit a write for a response on which it asserts
`ABORT`.

## LOCK and DMORE

`LOCK=1` requests uninterrupted ownership across both data transfers of
SWP/SWPB. It is asserted on the locked read and write address phases and
released on normal completion, abort, reset, or the architecturally permitted
debug boundary.

`DMORE=1` is an address-phase promise, not a response indication. It is legal
only on an unlocked active word data address. The next enabled phase must be
an S word data access at `ADDR+4` with the same direction and controls. LDM
and STM assert it on every beat that has a guaranteed follower, including
when an earlier response aborts but the block instruction must continue.

Every beat remains an independent request. Neither signal permits a memory
adapter to collapse completions or lose write ordering.

## Coprocessor mirrors

The raw coprocessor-follow outputs mirror the current address class:

- `CPnMREQ = !(TRANS inside {N,S})`;
- `CPSEQ = TRANS[0]`;
- `CPnOPC = PROT[0]`.

`CPnI`, `CPnTRANS`, and `CPTBIT` have the instruction-pipeline semantics in
[COPROCESSOR.md](COPROCESSOR.md); they are not aliases for the memory bus.

## Chapter 7 interpretation

Chapter 7 tables are pipelined. In each detailed row, the Data column is the
response in that numbered processor cycle while `ADDR` and `TRANS` already
describe the next address-class phase. A scoreboard must not compare the
current data response against the current address without retaining the prior
phase.

Table 7-2 summarizes Execute-stage occupancy; the detailed Tables 7-3 through
7-23 control the externally visible phase ordering. The apparent STM
discrepancy is the important example: Table 7-2 writes
`+N +(n-1)S +I +N`, while Table 7-14 exposes an `n+1`-cycle stream whose data
addresses are the first N, intermediate S phases, and final N phase. The
internal store bookkeeping overlaps the pipelined address/data work and is
not emitted as an additional raw `TRANS=I` row. This implementation therefore
uses the Table 7-14 pin sequence and does not add a bus-visible idle cycle.

The same rule resolves the other apparent summary/detail differences:
summary notation counts the instruction's processor cycles; detailed rows,
including their final unnumbered next-address line, define pin values. No
extra pin phase is synthesized from a summary token when doing so would add a
row absent from the detailed table. `arm7tdmis_table7_core_phase_matrix_tb`
locks the base-family interpretation; the multiply, redirect, exception,
coprocessor, block-transfer, and condition-fail matrices cover their
specialized rows.

## Integration example

The raw surface exposes every ARM-side optional interface. An integration
that does not use external coprocessors or debug must tie inputs explicitly:

| Input | Required inactive/static value |
|---|---|
| `CFGBIGEND` | Static `0` for little endian or `1` for big endian |
| `nIRQ`, `nFIQ` | `1` when no interrupt is pending |
| `ABORT` | `0` unless completing an accepted N/S phase with an error |
| `CPA`, `CPB` | `1`, external coprocessor absent |
| `DBGEN`, `DBGRQ`, `DBGBREAK`, `DBGEXT` | `0`, debug disabled/no event |
| `DBGTCKEN`, `DBGTMS`, `DBGTDI` | `0` when no scan transport is active |
| `DBGnTRST` | `0` to hold the unused TAP in reset |

The following excerpt shows the ownership pattern; normal named connections
are used for every output so no hierarchy is required:

```systemverilog
arm7tdmis_top u_cpu (
    .CLK(CLK), .CLKEN(cpu_advance), .nRESET(reset_n),
    .CFGBIGEND(BIG_ENDIAN),
    .nIRQ(irq_n), .nFIQ(fiq_n), .ABORT(mem_abort),
    .ADDR(mem_addr), .WRITE(mem_write), .SIZE(mem_size),
    .PROT(mem_prot), .LOCK(mem_lock), .TRANS(mem_trans),
    .WDATA(mem_wdata), .RDATA(mem_rdata),
    .CPA(1'b1), .CPB(1'b1),
    .CPnMREQ(), .CPSEQ(), .CPnTRANS(), .CPnOPC(),
    .CPTBIT(), .CPnI(),
    .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
    .DBGEXT(2'b00), .DBGACK(), .DBGnEXEC(),
    .DBGINSTRVALID(), .DBGRNG(), .DBGCOMMTX(), .DBGCOMMRX(),
    .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
    .DBGnTRST(1'b0), .DBGTDO(), .DBGnTDOEN(),
    .DMORE(mem_more)
);
```

The memory pipeline must latch address metadata on each enabled N/S edge and
return the corresponding response on the next enabled edge, as shown in the
edge diagram above. To synthesize and characterize the complete raw
interface for the selected Cyclone V device, run:

```sh
make -C scripts lint
make -C scripts quartus-conformance-analysis
make -C scripts quartus-conformance-compile
```

Most new FPGA systems should use the canonical wrapper instead; it converts
independent memory backpressure to the shared raw `CLKEN` contract.

## Reusable checker

Instantiate `verification/arm7tdmis_raw_bus_checker.sv` beside the raw core in
simulation or a formal harness and connect the same pins. It verifies:

- reset-idle controls and static `CFGBIGEND`;
- reserved size and all coprocessor mirrors;
- legal S history, increments, and control stability;
- no byte bursts;
- DMORE legality and its promised follower;
- stable outputs during continued `CLKEN=0`.

It deliberately does not constrain `RDATA` or `ABORT`; those are environment
responses whose values depend on the attached system. The integration tests
separately verify their phase and architectural sampling.

Run the checker's positive and mutation tests with:

```sh
make -C scripts raw-checker-self-test
```

The target runs one legal mixed sequence and eleven expected-failure
mutations, requires every mutation to exit nonzero, and verifies the exact
assertion class that rejected it.

## Version and compatibility

This document defines raw bus API version 1 against ARM DDI 0234B r4p3.
The repository prerelease version is in [`VERSION`](../VERSION), and
user-visible changes are recorded in [`CHANGELOG.md`](../CHANGELOG.md).

Within raw API version 1, pin names, widths, polarities, phase ownership,
CLKEN sampling, lane mapping, reset behavior, and r4p3 compatibility policies
will not change incompatibly. New optional integration helpers must not alter
these pins. A pin or semantic change requires a new raw API version and an
explicit breaking changelog entry. Verification-only ports selected by
`ARM7TDMIS_VERIFICATION` and internal hierarchy are outside the production
compatibility contract.
