# FPGA performance and integration budget

This is the checked version `0.9.0-dev` characterization, not a guarantee
for an enclosing MiSTer project. All profiles target Cyclone V
`5CSEBA6U23I7` with Quartus Lite 17.0.2 and the supplied standalone
constraints. A framework build must repeat fit, timing, and power analysis
with its own clocks, placement, I/O, memory, and activity.

## Clock and CPU enable

The checked `CLK` is 25 MHz (40 ns). There is one real clock and no generated
or gated clock. `CPU_CE`/raw `CLKEN` may be high on every rising edge for a
maximum 1:1 master-clock-to-CPU-advance ratio, or may insert any finite number
of disabled edges. One enabled edge can advance at most one CPU cycle; the
effective CPU rate is therefore `CLK frequency * enabled-edge fraction`.

The minimum reported same-clock Fmax across the slow timing models is
28.79 MHz for the trimmed canonical-wrapper profile and 27.24 MHz for the
raw feature-complete profile. These figures have 3.79 MHz and 2.24 MHz
headroom over the checked 25 MHz clock, respectively. They are post-fit
characterization results for virtual boundary pins, not a promise that a
particular board or framework will reach those rates.

## Request latency

The canonical wrapper presents one outstanding request. It captures a raw
address phase on an enabled CPU edge, so the earliest external completion is
a later `CLK` edge with `MEM_VALID && MEM_READY`. `MEM_READY` is independent
of `CPU_CE`: a completion received while CE is low is buffered and consumed
exactly once on a later enabled edge. There is no fixed maximum memory
latency, but a live target must eventually respond.

Back-to-back completions and request capture may share an enabled edge.
`MEM_MORE`, `MEM_SEQUENTIAL`, and `MEM_LOCK` do not combine handshakes; every
beat completes separately. The raw interface instead shares `CLKEN` between
the core and its pipelined response, as specified in
[RAW_BUS.md](RAW_BUS.md).

## Resources and clock enables

| Profile | Fitted ALMs | Registers | Registers with clock enable | M10K / memory bits | DSP blocks | Enforced budget |
|---|---:|---:|---:|---:|---:|---|
| Canonical trimmed wrapper (`ENABLE_DEBUG=0`, `ENABLE_COPROCESSOR=0`) | 3,491 | 2,512 | 2,109 | 0 / 0 | 6 | 5,000 ALMs, 4,096 registers, 8 DSPs, 0 memory bits |
| Raw feature-complete `arm7tdmis_top` | 4,889 | 3,823 | 3,099 | 0 / 0 | 6 | 7,500 ALMs, 6,000 registers, 8 DSPs, 0 memory bits |

The trimmed profile retains 1,509 ALMs, 1,584 registers, and two DSP blocks
of its project budget. The raw profile retains 2,611 ALMs, 2,177 registers,
and two DSP blocks. Neither profile infers MLAB/M10K storage; all
architectural banks are registers. Both infer the six DSP blocks used by the
multiplier. Quartus reports clock-enable inference on 2,109 of 2,130
synthesis registers in the trimmed profile and 3,099 of 3,146 in the raw
profile.

The two rows are different integration surfaces and must not be subtracted
to claim an isolated optional-feature cost.

## Optional-feature costs

Four additional fits select the same `arm7tdmi_mister` top, device, source
manifest, 25 MHz clock constraint, virtual boundary pins, and little-endian
setting. Only `ENABLE_DEBUG` and `ENABLE_COPROCESSOR` vary:

| Profile | Debug | Coprocessor | Fitted ALMs | Registers | CE registers | Memory bits | DSPs | Worst slow-model Fmax | Core dynamic power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `none` | 0 | 0 | 3,565 | 2,501 | 2,109 | 0 | 6 | 27.31 MHz | 26.61 mW |
| `debug` | 1 | 0 | 4,806 | 3,162 | 3,037 | 0 | 6 | 28.32 MHz | 37.04 mW |
| `coprocessor` | 0 | 1 | 3,711 | 2,697 | 2,283 | 0 | 6 | 27.29 MHz | 30.34 mW |
| `both` | 1 | 1 | 4,989 | 3,349 | 3,221 | 0 | 6 | 27.51 MHz | 36.48 mW |

The isolated fitted deltas from `none` are:

| Enabled option set | ALM delta | Register delta | Memory-bit delta | DSP delta | Fmax delta | Core-dynamic-power delta |
|---|---:|---:|---:|---:|---:|---:|
| `debug` | +1,241 | +661 | 0 | 0 | +1.01 MHz | +10.43 mW |
| `coprocessor` | +146 | +196 | 0 | 0 | -0.02 MHz | +3.73 mW |
| `both` | +1,424 | +848 | 0 | 0 | +0.20 MHz | +9.87 mW |

Fitter variation means the combined delta need not equal the sum of the two
single-option deltas, and a positive Fmax delta is not an architectural
speedup. These are like-for-like implementation measurements, not an
additive cost model. The machine-readable source is
`reports/generated/quartus-options.json`.

## Power estimate

PowerPlay vectorless estimation at the checked 25 MHz assumptions reports:

| Profile | Total | Core dynamic | Core static | I/O |
|---|---:|---:|---:|---:|
| Canonical trimmed wrapper | 450.07 mW | 28.96 mW | 412.43 mW | 8.67 mW |
| Raw feature-complete | 457.79 mW | 36.62 mW | 412.50 mW | 8.67 mW |

The PowerPlay confidence is **Low** because no workload VCD/toggle file or
board thermal model is supplied. The selected SoC device also emits Quartus
warning 215050 for absent HPS activity; HPS is disabled in both projects.
The report checker allows only that identified power warning and rejects
other critical warnings. These numbers are useful fabric-characterization
estimates, but this is not a board-power estimate or a thermal sign-off.

## Reset and endian configuration

Assert `RESET_N` low for at least two `CLK` rising edges. Reset assertion is
asynchronous; architectural release is synchronized and takes two rising
edges after deassertion. The raw top uses the corresponding active-low
`nRESET` rule.

`BIG_ENDIAN=0` selects little endian and `BIG_ENDIAN=1` selects big endian at
synthesis. The setting is static for an instance and cannot change while
running. It changes byte/halfword lane placement, not the resource budget or
clocking contract.

## Reproducing characterization

Run both complete checked flows from the repository root:

```sh
make -C scripts quartus-compile
make -C scripts quartus-conformance-compile
make -C scripts quartus-option-characterization
```

Each target runs synthesis, fit, assembly, four-corner TimeQuest, and
vectorless PowerPlay. The first two call `scripts/quartus_report_check.py`
directly; the option target applies the same checker to all four fits through
`scripts/quartus_option_characterization.py`. Each option profile uses Quartus
Auto Fit so a single placement that misses the common 0.25 ns synchronous
input-hold contract is retried without weakening that boundary requirement.
The checks fail on missing
stages or images, unexpected top/device, resource-budget overruns, missing
clock-enable/Fmax/power evidence, negative slack, unconstrained setup/hold
paths, and unapproved critical warnings.
