# Chapter 8 AC timing disposition

This is the complete FPGA disposition of ARM DDI 0234B r4p3 §8.1, §8.2,
Figures 8-1 through 8-5, Table 8-1, and Appendix B.3. The machine-readable
source is `verification/ac_timing.json` (schema
`arm7tdmis-ac-timing-map-v1`).

## Scope of the source numbers

Table 8-1 is titled “Provisional AC parameters.” It expresses target values
as percentages of `CLK` at maximum operating frequency and directs the
integrator to the silicon supplier for details. Appendix B.3 says the timing
constraints balance the synthesized core’s area against its external timing.
The values are therefore provisional synthesized-macrocell/silicon targets,
not immutable timing guarantees at arbitrary FPGA pins.

The raw conformance profile makes one explicit target choice: Cyclone V
`5CSEBA6U23I7`, Quartus Lite 17.0.2, 25 MHz, and a 40 ns `CLK`. For applicable
synchronous inputs it uses:

```text
max input delay = 40 ns - Table 8-1 setup fraction
min input delay = 0 ns for a Table 8-1 0% maximum hold
```

For applicable synchronous outputs it uses:

```text
max output delay = 40 ns - Table 8-1 clock-to-valid fraction
min output delay = 0 ns; the fitted design must report positive hold slack
```

This translation reserves the original fraction for the FPGA’s internal
port-to-register or register-to-port path. It is a checked target constraint,
not a claim that the original percentage applies to every containing MiSTer
core. A containing design must replace the virtual boundary with constraints
for its real clocks, bridges, memories, pins, and receiver requirements.

## Complete Table 8-1 mapping

The source spelling is preserved, including `tohdbctl`.

| Symbol | Source parameter | Min | Max | Figure / raw mapping | 25 MHz SDC disposition |
|---|---|---:|---:|---|---|
| `tcyc` | CLK cycle time | 100% | – | primary `CLK` | 40.000 ns clock |
| `tisclken` | CLKEN setup | 40% | – | Fig. 8-1 `CLKEN` | input max 24 ns |
| `tihclken` | CLKEN hold | – | 0% | Fig. 8-1 `CLKEN` | input min 0 ns |
| `tisabort` | ABORT setup | 15% | – | Fig. 8-1 `ABORT` | input max 34 ns |
| `tihabort` | ABORT hold | – | 0% | Fig. 8-1 `ABORT` | input min 0 ns |
| `tisrdata` | RDATA setup | 10% | – | Fig. 8-1 `RDATA[*]` | input max 36 ns |
| `tihrdata` | RDATA hold | – | 0% | Fig. 8-1 `RDATA[*]` | input min 0 ns |
| `tovaddr` | CLK to ADDR valid | – | 90% | Fig. 8-1 `ADDR[*]` | output max 4 ns |
| `tohaddr` | ADDR hold | >0% | – | Fig. 8-1 `ADDR[*]` | output min 0 ns + positive fitted hold slack |
| `tovctl` | CLK to control valid | – | 90% | Fig. 8-1 / App. B.3 `WRITE`, `SIZE`, `PROT`, `LOCK` | output max 4 ns |
| `tohctl` | Control hold | >0% | – | same control group | output min 0 ns + positive fitted hold slack |
| `tovtrans` | CLK to TRANS valid | – | 50% | Fig. 8-1 `TRANS[*]` | output max 20 ns |
| `tohtrans` | TRANS hold | >0% | – | Fig. 8-1 `TRANS[*]` | output min 0 ns + positive fitted hold slack |
| `tovwdata` | CLK to WDATA valid | – | 40% | Fig. 8-1 `WDATA[*]` | output max 24 ns |
| `tohwdata` | WDATA hold | >0% | – | Fig. 8-1 `WDATA[*]` | output min 0 ns + positive fitted hold slack |
| `tiscpstat` | CPA/CPB setup | 20% | – | Fig. 8-2 `CPA`, `CPB` | input max 32 ns |
| `tihcpstat` | CPA/CPB hold | – | 0% | Fig. 8-2 `CPA`, `CPB` | input min 0 ns |
| `tovcpctl` | CLK to coprocessor control valid | – | 80% | Fig. 8-2 `CPnMREQ`, `CPSEQ`, `CPnOPC`, `CPnTRANS`, `CPTBIT` | output max 8 ns |
| `tohcpctl` | Coprocessor control hold | >0% | – | same coprocessor group | output min 0 ns + positive fitted hold slack |
| `tovcpni` | CLK to CPnI valid | – | 40% | Fig. 8-2 `CPnI` | output max 24 ns |
| `tohcpni` | CPnI hold | >0% | – | Fig. 8-2 `CPnI` | output min 0 ns + positive fitted hold slack |
| `tisexc` | nFIQ/nIRQ/nRESET setup | 10% | – | Fig. 8-3 `nFIQ`, `nIRQ`; reset replacement below | input max 36 ns |
| `tihexc` | nFIQ/nIRQ/nRESET hold | – | 0% | Fig. 8-3 `nFIQ`, `nIRQ`; reset replacement below | input min 0 ns |
| `tiscfg` | CFGBIGEND setup | 10% | – | Fig. 8-3 `CFGBIGEND` | input max 36 ns |
| `tihcfg` | CFGBIGEND hold | – | 0% | Fig. 8-3 `CFGBIGEND` | input min 0 ns |
| `tisdbgstat` | Debug-status inputs setup | 10% | – | Fig. 8-4 `DBGRQ`, `DBGBREAK`, `DBGEXT[*]` | input max 36 ns |
| `tihdbgstat` | Debug-status inputs hold | – | 0% | same debug-input group | input min 0 ns |
| `tovdbgctl` | CLK to debug-control valid | – | 40% | Fig. 8-4 `DBGACK`, `DBGCOMMTX`, `DBGCOMMRX` | output max 24 ns |
| `tohdbctl` | Debug-control hold | >0% | – | same first debug-output group | output min 0 ns + positive fitted hold slack |
| `tistcken` | DBGTCKEN setup | 40% | – | Fig. 8-5 `DBGTCKEN` | input max 24 ns |
| `tihtcken` | DBGTCKEN hold | – | 0% | Fig. 8-5 `DBGTCKEN` | input min 0 ns |
| `tistctl` | DBGTDI/DBGTMS setup | 35% | – | Fig. 8-5 `DBGTDI`, `DBGTMS` | input max 26 ns |
| `tihtctl` | DBGTDI/DBGTMS hold | – | 0% | same scan-control group | input min 0 ns |
| `tovtdo` | CLK to DBGTDO valid | – | 20% | Fig. 8-5 `DBGTDO` | output max 32 ns |
| `tohtdo` | DBGTDO hold | >0% | – | Fig. 8-5 `DBGTDO` | output min 0 ns + positive fitted hold slack |
| `tovdbgstat` | CLK to debug-status valid | – | 40% | Fig. 8-4 `DBGRNG[*]` | output max 24 ns |
| `tohdbgstat` | Debug-status hold | >0% | – | Fig. 8-4 `DBGRNG[*]` | output min 0 ns + positive fitted hold slack |

Table 8-1 says that a displayed 0% includes hold to the active edge plus
maximum internal clock-buffer skew. The FPGA translation therefore does not
advertise “zero physical delay”; it supplies a portable zero external-hold
boundary and relies on fail-hard fitted hold analysis to prove positive slack.

## Figure 8-4 naming conflict

The table calls its input pair `tisdbgstat`/`tihdbgstat`, while Figure 8-4
labels the same input arrows `tisdbgctl`/`tihdbgctl`. The table also contains
`tovdbgctl`/`tohdbctl` and `tovdbgstat`/`tohdbgstat`, while the figure labels
both visible output groups with the latter pair. The contract preserves all
six table symbols and records the figure aliases. The first 40% output pair
maps to `DBGACK`/DCC handshake status and the second to `DBGRNG`; both receive
the same numeric target, so the naming ambiguity cannot silently omit or
weaken either group.

## Integration-owned and non-table boundaries

- Clock: the containing design supplies `CLK`; this profile creates one real
  clock and no generated/gated clock.
- Reset: `nRESET` and `DBGnTRST` assert asynchronously. The architectural
  reset synchronizer owns `nRESET` release; raw debug-reset release belongs to
  the containing integration. They are false-pathed instead of pretending
  that the `tisexc` synchronous percentage describes asynchronous assertion.
- Debug synchronization: the raw profile times `DBGRQ`, `DBGBREAK`,
  `DBGEXT`, `DBGTCKEN`, `DBGTDI`, and `DBGTMS` as synchronous. An external
  pod TCK or asynchronous event needs a containing synchronizer/handshake.
- Test-only: Appendix A’s `SCANENABLE`, `SCANIN`, and `SCANOUT` are ASIC ATPG
  insertion signals. The FPGA profile excludes them and supplies
  `arm7tdmis_no_dft` only as an explicit compatibility tie-off.
- Power: `VDD` and `VSS` are FPGA-device/board rails, not RTL timing ports.
- Non-table raw ports: `DBGEN` retains a target-specific 0–5 ns input window;
  `DBGnEXEC`, `DBGINSTRVALID`, `DBGnTDOEN`, and `DMORE` retain a
  target-specific 0–5 ns output window. No ARM percentage is invented for
  signals absent from Table 8-1.

## Reproducing the contract

Run:

```sh
make -C scripts ac-timing
make -C scripts quartus-conformance-compile
```

The first command validates all 37 rows, all five figures, the exact PDF
identity, every percentage and signal group, the Figure 8-4 ambiguity, the
physical-scope caveat, integration ownership, and the corresponding active
SDC commands. It writes `reports/generated/ac-timing-report.json` with schema
`arm7tdmis-ac-timing-v1`. The second runs fitted TimeQuest analysis; the
existing report checker rejects negative setup/hold slack and unconstrained
paths.
