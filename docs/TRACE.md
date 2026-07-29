# ETM7-Facing Trace Contract

The repository provides the ARM7TDMI-S side of the external ETM7 interface.
It does not implement an Embedded Trace Macrocell, trace encoder, FIFO, or
capture memory. A system that needs instruction trace must instantiate a
licensed or compatible ETM7 implementation beside the raw CPU.

The normative mapping is ARM DDI 0234B Chapter 6, especially Table 6-1.
`rtl/trace/arm7tdmis_etm7_adapter.sv` gives that mapping explicit names so an
FPGA or simulation integration cannot silently omit a tie-off.

## Execute status

`DBGINSTRVALID` is high for one enabled cycle for each instruction committed
to the Execute stage. It is not a bus-valid signal and it does not remain high
through a multicycle instruction's later internal/data/writeback substates.

`DBGnEXEC` is the active-low condition-code result for the Execute-stage
instruction:

| State | `DBGINSTRVALID` | `DBGnEXEC` |
|---|---:|---:|
| instruction reaches Execute and condition passes | 1 | 0 |
| instruction reaches Execute and condition fails | 1 | 1 |
| reset, bubble, CLKEN stop, later multicycle substate, or debug halt | 0 | 1 |

A condition-passing instruction that takes Undefined is still reported as
executed (`1/0`). Decoder implementation status is not a condition-code
result. Conversely, a condition-failed instruction produces `1/1` even
though it retains the documented bus cycle.

Debug-speed scan instructions follow the same rule when the injected
instruction reaches Execute. Instruction acceptance into the scan path is not
itself a trace event; each accepted instruction produces exactly one event
when it actually enters Execute, regardless of later memory or internal
cycles.

`CLKEN=0` suppresses both an event and condition success. An ETM observes the
shared `CLKEN` and must not count a stopped Execute-stage residence as repeated
instructions.

## Table 6-1 adapter

The adapter is combinational and transparent:

- `ADDR`, `ABORT`, `CFGBIGEND`, `CLKEN`, `CPA`, `CPB`, `DBGACK`,
  `CPnMREQ`, `CPSEQ`, `SIZE`, `CPnI`, `DBGnEXEC`, `CPnOPC`, `WRITE`,
  `DBGRNG`, `RDATA`, `CPTBIT`, `DBGTCKEN`, `DBGTDI`, `DBGTDO`,
  `DBGTMS`, `WDATA`, and `DBGINSTRVALID` map directly to their ETM7 names;
- CPU `CLK` drives both ETM `CLK` and `TCK`;
- CPU `DBGnTRST` drives ETM `nTRST`, while processor `nRESET` separately
  drives ETM `nRESET`;
- ETM `DBGRQ` is returned as `CPU_DBGRQ`. If another source also requests
  debug, the containing system must combine the requests as described in
  TRM §6.5;
- both ETM `TDO` and `ARMTDO` see CPU `DBGTDO`;
- `PROCID[31:0]` and `PROCIDWR` are permanently zero because
  ARM7TDMI-S provides no process-ID source.

`RDATA` and `WDATA` are not registered or reconstructed in the adapter. Their
direct visibility is required for the ETM to observe the raw pipelined bus,
including coprocessor-related cycles. Their phase convention remains the one
in [RAW_BUS.md](RAW_BUS.md).

An external ETM's `PWRDOWN`, programming, scan chain 6, trace formatting, and
storage remain properties of that macrocell. TAP reset is propagated so that
macrocell can implement the Chapter 6 reset behavior; this adapter does not
fabricate `PWRDOWN`.

## Evidence

`etm7_adapter_tb` toggles every mapped input, verifies both clock aliases,
direct read/write data, both resets, ETM-to-CPU debug request direction, and
the permanent process-ID tie-offs.

`arm7tdmis_etm_trace_matrix_tb` covers reset, an Execute-stage CLKEN stop,
normal and condition-failed ARM instructions, a multicycle load, branch-flush
cancellation, a condition-passing Undefined trap and vector, ARM-to-Thumb
interworking, a failed Thumb condition, and debug halt.

`arm7tdmis_debug_inject_matrix_tb` independently checks one
`DBGINSTRVALID && !DBGnEXEC` pulse for each of 38 public-JTAG debug-speed
instructions, including memory and internally stalled forms.

Run:

```sh
make -C scripts unit-etm7_adapter
make -C scripts integ-etm_trace_matrix
make -C scripts integ-debug_inject_matrix
```
