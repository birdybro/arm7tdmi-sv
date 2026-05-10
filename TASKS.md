# 0. Define the target

Your final target should be a synthesizable SystemVerilog implementation with these major blocks:

```text
arm7tdmis_top
├── clock/reset/clock-enable control
├── programmer-visible CPU core
│   ├── register bank: 31 x 32-bit GPRs + 6 status registers
│   ├── CPSR/SPSR logic
│   ├── ARM decoder
│   ├── Thumb decoder/decompressor
│   ├── barrel shifter
│   ├── ALU
│   ├── multiplier / multiply-accumulate unit
│   ├── address generator
│   ├── load/store unit
│   ├── exception/interrupt controller
│   └── 3-stage pipeline control
├── ARM7TDMI-S memory interface
├── coprocessor interface
├── internal CP14 debug communications channel
├── internal CP15/system-control-facing behavior, as applicable to your target
├── EmbeddedICE-RT debug macrocell
├── JTAG/TAP scan interface
├── ETM7-facing trace interface
└── synthesis/scan/timing wrapper
```

The TRM’s Figure 1-3 is the best architectural starting point: it shows the address register/incrementer, register bank, 32x8 multiplier, barrel shifter, 32-bit ALU, instruction pipeline, read/write data registers, Thumb decoder, instruction decoder/control logic, memory signals, debug signals, and coprocessor handshake signals. 

---

# 1. Build the project skeleton

Implement these first:

1. Create the repo structure:

```text
rtl/
  core/
  decode/
  datapath/
  memory/
  coproc/
  debug/
  jtag/
  etm/
  top/
tb/
  unit/
  integration/
  formal/
  programs/
docs/
scripts/
```

2. Define common SystemVerilog packages:

```text
arm7tdmis_types_pkg.sv
arm7tdmis_instr_pkg.sv
arm7tdmis_psr_pkg.sv
arm7tdmis_bus_pkg.sv
arm7tdmis_debug_pkg.sv
```

3. Define enums for:

```text
ARM/Thumb state
processor modes
exception types
memory transfer size
memory transfer type
ALU operation
shifter operation
pipeline stage state
coprocessor handshake state
debug state
```

4. Define your top-level pin list directly from the TRM:

```text
CLK
CLKEN
nRESET
CFGBIGEND
nIRQ
nFIQ
ABORT

ADDR[31:0]
WRITE
SIZE[1:0]
PROT[1:0]
LOCK
TRANS[1:0]
WDATA[31:0]
RDATA[31:0]

CPnMREQ
CPSEQ
CPnTRANS
CPnOPC
CPTBIT
CPnI
CPA
CPB

DBGEN
DBGRQ
DBGBREAK
DBGACK
DBGnEXEC
DBGINSTRVALID
DBGEXT[1:0]
DBGRNG[1:0]
DBGCOMMTX
DBGCOMMRX

DBGTCKEN
DBGTMS
DBGTDI
DBGTDO
DBGnTRST
DBGnTDOEN
DMORE
```

The memory bus is grouped into clock/control, address-class, memory request, and data-timed signals; the TRM lists `CLK`, `CLKEN`, `nRESET`, `ADDR`, `WRITE`, `SIZE`, `PROT`, `LOCK`, `TRANS`, `WDATA`, `RDATA`, and `ABORT` as the main memory-interface signals. 

---

# 2. Build the verification framework before the CPU

Before writing the full core, build the test environment.

Tasks:

1. Create a simple behavioral memory model.

2. Support byte, halfword, and word accesses.

3. Support little-endian and big-endian modes using `CFGBIGEND`.

4. Support `ABORT` injection.

5. Support wait states using `CLKEN`.

6. Create a simple program loader for assembled ARM/Thumb binaries.

7. Create a cycle logger that records:

```text
cycle
PC
CPSR
mode
ARM/Thumb state
fetched instruction
decoded instruction
executed instruction
ADDR
WRITE
SIZE
PROT
LOCK
TRANS
WDATA
RDATA
exception state
debug state
```

8. Create assertion checks for:

```text
no register write when instruction condition fails
correct PC value visible to instructions
correct CPSR flag updates
correct exception vectoring
correct memory transaction type
correct byte-lane extraction
correct pipeline flush on branch/exception
```

9. Build directed tests first, then random instruction tests later.

10. Build a reference model path. This can be a small non-synthesizable interpreter in Python/C++/SystemVerilog testbench code, or comparison against another trusted ARMv4T emulator.

---

# 3. Implement the programmer-visible state

Implement the architectural state before the pipeline.

Tasks:

1. Implement the full register bank.

2. Implement User/System registers:

```text
r0-r15
CPSR
```

3. Implement banked FIQ registers:

```text
r8_fiq-r14_fiq
SPSR_fiq
```

4. Implement banked IRQ registers:

```text
r13_irq
r14_irq
SPSR_irq
```

5. Implement banked Supervisor registers:

```text
r13_svc
r14_svc
SPSR_svc
```

6. Implement banked Abort registers:

```text
r13_abt
r14_abt
SPSR_abt
```

7. Implement banked Undefined registers:

```text
r13_und
r14_und
SPSR_und
```

8. Implement CPSR fields:

```text
N Z C V
I
F
T
M[4:0]
reserved bits
```

9. Implement mode decode:

```text
User       10000
FIQ        10001
IRQ        10010
Supervisor 10011
Abort      10111
Undefined  11011
System     11111
```

10. Implement register-read mapping for every mode.

11. Implement register-write mapping for every mode.

12. Implement SPSR access rules.

13. Implement PC read behavior for ARM state.

14. Implement PC read behavior for Thumb state.

15. Implement PC write behavior and pipeline flush request.

The ARM7TDMI-S has 37 total registers: 31 general-purpose 32-bit registers and 6 status registers. Which registers are visible depends on current processor mode and ARM/Thumb state. 

---

# 4. Implement reset and basic mode control

Tasks:

1. Implement asynchronous or externally synchronized `nRESET` behavior according to your top-level choice.

2. On reset:

```text
mode = Supervisor
I = 1
F = 1
T = 0
PC = 0x00000000
ARM state
```

3. Treat other registers as architecturally indeterminate after reset.

4. Flush pipeline on reset.

5. Start fetching from vector address `0x00000000`.

The TRM states that when `nRESET` is released, the core enters Supervisor mode, sets the I and F bits, clears T, forces the PC to fetch from address `0x00`, and resumes in ARM state. 

---

# 5. Implement the core datapath primitives

Build these modules independently and unit-test each one.

## 5.1 Barrel shifter

Implement:

```text
LSL immediate
LSL register
LSR immediate
LSR register
ASR immediate
ASR register
ROR immediate
ROR register
RRX
```

Tasks:

1. Produce shifted result.

2. Produce shifter carry-out.

3. Handle special shift amounts.

4. Handle immediate rotate encoding for ARM data-processing immediates.

5. Support register-controlled shifts using the bottom 8 bits of the shift register.

## 5.2 ALU

Implement:

```text
AND
EOR
SUB
RSB
ADD
ADC
SBC
RSC
TST
TEQ
CMP
CMN
ORR
MOV
BIC
MVN
```

Tasks:

1. Generate result.

2. Generate N/Z flags.

3. Generate carry/borrow flag.

4. Generate signed overflow flag.

5. Support flag write enable.

6. Support compare/test instructions that update flags but do not write a destination register.

## 5.3 Multiplier

Implement:

```text
MUL
MLA
UMULL
UMLAL
SMULL
SMLAL
```

Tasks:

1. Implement 32x32 multiply.

2. Implement signed and unsigned long results.

3. Implement accumulate variants.

4. Implement flag updates for `S` variants.

5. Add cycle-control hooks for ARM7TDMI-S multiply timing.

The TRM’s core diagram includes a `32 x 8` multiplier, and Chapter 7 states that multiply instructions use special hardware with early termination.  

---

# 6. Implement condition-code evaluation

Every ARM instruction is conditional.

Tasks:

1. Decode `cond[31:28]`.

2. Implement:

```text
EQ NE CS CC MI PL VS VC HI LS GE LT GT LE AL
```

3. Generate `condition_pass`.

4. Suppress register writes when the condition fails.

5. Suppress memory writes when the condition fails.

6. Suppress CPSR writes when the condition fails.

7. Generate `DBGnEXEC` correctly for instructions that reach execute but fail the condition.

8. Confirm that unexecuted instructions still consume correct cycles.

The TRM notes that ARM-state instructions can execute conditionally, while in Thumb state only branch instructions are conditional. 

---

# 7. Implement a simple non-pipelined ARM execution model

This is a temporary milestone, not the final core.

Tasks:

1. Fetch one 32-bit instruction.

2. Decode it.

3. Execute it.

4. Update architectural state.

5. Ignore exact cycle timing for now.

6. Run small assembly programs.

7. Verify ALU, flags, branches, loads, stores, and exceptions at an architectural level.

This gives you a known-good core before adding pipeline timing.

---

# 8. Implement ARM instruction decode

Build a clean decoder that produces a normalized internal micro-operation.

## ARM decode groups

Implement decode for:

1. Branch:

```text
B
BL
BX
```

2. Data processing:

```text
AND EOR SUB RSB ADD ADC SBC RSC
TST TEQ CMP CMN
ORR MOV BIC MVN
```

3. PSR transfer:

```text
MRS CPSR
MRS SPSR
MSR CPSR
MSR SPSR
```

4. Multiply:

```text
MUL
MLA
UMULL
UMLAL
SMULL
SMLAL
```

5. Single data transfer:

```text
LDR
STR
LDRB
STRB
LDRT
STRT
LDRBT
STRBT
```

6. Halfword and signed transfer:

```text
LDRH
STRH
LDRSB
LDRSH
```

7. Block transfer:

```text
LDM
STM
all IA/IB/DA/DB addressing forms
writeback
user-register transfer
PC-in-list behavior
S-bit behavior
```

8. Swap:

```text
SWP
SWPB
```

9. Coprocessor instructions:

```text
CDP
MCR
MRC
LDC
STC
```

10. Software interrupt:

```text
SWI
```

11. Undefined instructions.

The TRM summarizes the ARM instruction set groups as move/PSR transfer, arithmetic, multiply, compare/test, logical, branch, load/store, block transfer, swap, coprocessor, and software interrupt instructions. 

---

# 9. Implement ARM data-processing execution

Tasks:

1. Decode operand 2:

```text
immediate rotated right
register
register shifted by immediate
register shifted by register
RRX
```

2. Read `Rn`.

3. Read `Rm`.

4. Read `Rs` when needed.

5. Run barrel shifter.

6. Run ALU.

7. Write `Rd` when applicable.

8. Update flags when `S = 1`.

9. Handle `Rd = PC`.

10. Handle `S = 1` and `Rd = PC` restoring CPSR from SPSR where architecturally required.

11. Handle `PC` as operand.

12. Verify every opcode with directed tests.

Chapter 7 says data operations normally execute in one datapath cycle, except register-specified shifts, and that writing the PC invalidates the current pipeline and forces a pipeline refill. 

---

# 10. Implement ARM branch instructions

Tasks:

1. Implement `B`.

2. Implement `BL`.

3. Implement `BX`.

4. Implement sign-extension of branch offset.

5. Implement link register update.

6. Implement ARM-to-Thumb transition through `BX`.

7. Implement Thumb-to-ARM transition through `BX`.

8. Flush/refill pipeline after branch.

9. Verify PC and LR values.

10. Verify branch timing later against Chapter 7.

The TRM states that ARM/Thumb branches and ARM `BL` take three cycles, and that `BX` takes three cycles while extracting both the destination address and new core state from the register source.  

---

# 11. Implement ARM load/store address generation

Tasks:

1. Implement Addressing Mode 2:

```text
immediate offset
register offset
scaled register offset
pre-indexed
post-indexed
up/down
writeback
byte/word transfer
T/user-mode transfer variants
```

2. Implement Addressing Mode 3:

```text
halfword
signed halfword
signed byte
immediate offset
register offset
pre-indexed
post-indexed
writeback
```

3. Implement effective address generation.

4. Implement base register writeback.

5. Implement PC-relative loads.

6. Implement byte extraction.

7. Implement halfword extraction.

8. Implement sign extension for `LDRSB` and `LDRSH`.

9. Implement unaligned behavior according to ARMv4T rules.

10. Implement data abort suppression rules.

11. Implement destination `PC` load pipeline refill.

The memory system must support byte, halfword, and word quantities; words are aligned to 4-byte boundaries, halfwords to 2-byte boundaries, and byte accesses can occur on any byte boundary. 

---

# 12. Implement ARM block data transfer

Tasks:

1. Implement `LDM`.

2. Implement `STM`.

3. Support all addressing modes:

```text
IA
IB
DA
DB
FD
ED
FA
EA aliases at assembly level, if you build assembler-facing tests
```

4. Implement register-list iteration order.

5. Implement base writeback.

6. Implement empty register-list behavior according to architecture rules.

7. Implement `^` user-register transfer behavior.

8. Implement `LDM ... PC` behavior.

9. Implement `LDM ... PC^` CPSR restore behavior.

10. Implement abort behavior.

11. Implement `DMORE` for Rev 4 multiple transfers.

12. Verify all register-list combinations.

13. Verify cycle timing for 1-register and n-register transfers.

Chapter 7 describes `LDM` as calculating the first address, fetching words sequentially, latching the modified base for abort recovery, preventing register writes after abort, and invalidating the pipeline if PC is loaded. 

---

# 13. Implement ARM swap

Tasks:

1. Implement `SWP`.

2. Implement `SWPB`.

3. Generate locked bus access using `LOCK`.

4. Perform read cycle.

5. Perform write cycle.

6. Update destination register only after successful read/write sequence.

7. Handle aborts.

8. Verify atomic read/write bus behavior.

The TRM states that `LOCK` is asserted for `SWP`/`SWPB`, and Chapter 7 shows `LOCK` high for both load and store data cycles of the swap operation.  

---

# 14. Implement exceptions and interrupts

Implement exceptions only after ARM instruction execution mostly works.

Tasks:

1. Implement exception types:

```text
Reset
Undefined instruction
Software interrupt
Prefetch abort
Data abort
IRQ
FIQ
```

2. Implement exception vectors:

```text
0x00000000 Reset
0x00000004 Undefined
0x00000008 SWI
0x0000000C Prefetch Abort
0x00000010 Data Abort
0x00000014 Reserved
0x00000018 IRQ
0x0000001C FIQ
```

3. Implement exception priority:

```text
Reset
Data Abort
FIQ
IRQ
Prefetch Abort
Undefined instruction
SWI
```

4. On exception entry:

```text
save return address into mode-specific LR
copy CPSR to mode-specific SPSR
change mode bits
set interrupt disable bits as required
clear T bit
force ARM state
load PC with vector address
flush/refill pipeline
```

5. Implement exception return behavior.

6. Implement `MOVS PC, LR` and `SUBS PC, LR, #imm` return paths.

7. Implement `FIQ` banked registers.

8. Implement `IRQ` masking through CPSR.I.

9. Implement `FIQ` masking through CPSR.F.

10. Implement `nIRQ` and `nFIQ` sampling.

11. Implement data abort behavior for:

```text
single load/store
swap
LDM/STM
```

12. Implement prefetch abort tracking through the pipeline.

13. Verify exception entry from ARM state.

14. Verify exception entry from Thumb state.

15. Verify exception return to ARM state.

16. Verify exception return to Thumb state.

The TRM gives the exception entry/exit behavior, including saving return addresses in the appropriate LR, copying CPSR to SPSR, changing mode, forcing vector fetch, and handling exceptions in ARM state even when the exception occurred in Thumb state. 

---

# 15. Implement Thumb instruction support

Thumb is not just a smaller decoder; it changes fetch width, PC behavior, available registers, and branch behavior.

Tasks:

1. Implement Thumb fetch alignment.

2. Implement Thumb PC behavior.

3. Implement Thumb decoder.

4. Decode Thumb instructions into the same internal micro-op format used by ARM where possible.

5. Implement Thumb low-register ALU operations:

```text
MOV
ADD
SUB
ADC
SBC
NEG
CMP
CMN
MUL
AND
EOR
ORR
BIC
MVN
TST
```

6. Implement Thumb shifts:

```text
LSL
LSR
ASR
ROR
```

7. Implement high-register operations:

```text
MOV high/low
ADD high/low
CMP high/low
BX
```

8. Implement immediate operations:

```text
MOV immediate
CMP immediate
ADD immediate
SUB immediate
```

9. Implement PC-relative load.

10. Implement SP-relative load/store.

11. Implement register-offset load/store:

```text
LDR
STR
LDRB
STRB
LDRH
STRH
LDRSB
LDRSH
```

12. Implement immediate-offset load/store.

13. Implement address-generation pseudo-ops:

```text
ADD Rd, PC, #imm
ADD Rd, SP, #imm
ADD/SUB SP, #imm
```

14. Implement multiple transfer:

```text
LDMIA
STMIA
PUSH
POP
PUSH {..., LR}
POP {..., PC}
```

15. Implement conditional branches.

16. Implement unconditional branch.

17. Implement Thumb long branch with link.

18. Implement Thumb `SWI`.

19. Implement Thumb-to-ARM exception entry.

20. Verify every Thumb encoding group.

The TRM states that ARM7TDMI-S has two states: ARM state executes 32-bit word-aligned ARM instructions, and Thumb state executes 16-bit halfword-aligned Thumb instructions. It also states that exceptions are handled in ARM state and that Thumb exceptions automatically switch to ARM state. 

---

# 16. Replace the simple execution model with the 3-stage pipeline

Now make the implementation structurally match ARM7TDMI-S.

Tasks:

1. Implement pipeline stages:

```text
Fetch
Decode
Execute
```

2. Implement instruction fetch stage.

3. Implement decode stage.

4. Implement execute stage.

5. Implement pipeline valid bits.

6. Implement pipeline flush on:

```text
branch
PC write
exception
debug entry
reset
state switch
```

7. Implement pipeline refill.

8. Implement ARM PC offset behavior:

```text
execute-stage instruction sees PC ahead due to pipeline
```

9. Implement Thumb PC offset behavior.

10. Implement interlocks for multi-cycle instructions.

11. Implement multi-cycle sequencing for:

```text
register-controlled shifts
multiply
load/store
LDM/STM
SWP
coprocessor transfers
exceptions
debug state
```

12. Implement instruction prefetch during execute when allowed.

13. Implement internal cycles when no useful memory access is possible.

14. Verify that branches, exceptions, and loads to PC refill the pipeline correctly.

The ARM7TDMI-S uses a three-stage Fetch/Decode/Execute pipeline, and the PC points to the instruction being fetched rather than the instruction being executed. 

---

# 17. Implement the ARM7TDMI-S memory interface

This is where your core becomes ARM7TDMI-S-like rather than just ARMv4T-compatible.

Tasks:

1. Implement the pipelined bus interface.

2. Generate address-class signals one bus cycle ahead of data transfer:

```text
ADDR[31:0]
WRITE
SIZE[1:0]
PROT[1:0]
LOCK
```

3. Generate transaction type:

```text
TRANS[1:0]
00 I-cycle
01 C-cycle
10 N-cycle
11 S-cycle
```

4. Implement N-cycle generation.

5. Implement S-cycle generation.

6. Implement I-cycle generation.

7. Implement C-cycle generation.

8. Implement merged I-S cycle behavior.

9. Implement sequential bursts:

```text
word read burst
word write burst
halfword read burst
```

10. Implement `CLKEN` bus-cycle extension.

11. Hold/update internal bus state only when `CLKEN` allows the bus cycle to complete.

12. Implement `RDATA` sampling.

13. Implement `WDATA` drive timing.

14. Implement `ABORT` sampling.

15. Implement `SIZE` encoding:

```text
00 byte
01 halfword
10 word
11 reserved
```

16. Implement `PROT` encoding:

```text
user/privileged
opcode/data
```

17. Implement `LOCK`.

18. Implement `DMORE` for LDM/STM sequential data access indication.

19. Implement little-endian byte/halfword extraction.

20. Implement big-endian byte/halfword extraction.

21. Implement byte/halfword write-data replication.

The TRM states that the bus interface is pipelined, with address-class and memory-request signals broadcast one bus cycle ahead of the bus cycle they refer to. It also defines the four `TRANS[1:0]` cycle types: internal, coprocessor register transfer, nonsequential, and sequential. 

---

# 18. Make the core cycle-accurate

Once architectural execution works, match the timing tables.

Tasks:

1. Create a cycle-count test suite from Chapter 7.

2. Verify normal data-processing timing.

3. Verify register-controlled shift timing.

4. Verify data-processing with destination PC timing.

5. Verify branch timing.

6. Verify ARM `BL` timing.

7. Verify Thumb `BL` timing.

8. Verify `BX` timing.

9. Verify multiply timing.

10. Verify multiply-accumulate timing.

11. Verify long multiply timing.

12. Verify load timing.

13. Verify store timing.

14. Verify `LDM` timing.

15. Verify `STM` timing.

16. Verify `SWP` timing.

17. Verify `SWI` and exception-entry timing.

18. Verify coprocessor timing.

19. Verify undefined instruction timing.

20. Verify unexecuted instruction timing.

21. Verify bus `TRANS`, `PROT`, `SIZE`, `WRITE`, and `LOCK` values cycle by cycle.

The TRM’s Chapter 7 explicitly gives instruction cycle timings for branches, data operations, multiply, load/store, block transfer, swap, SWI/exception entry, coprocessor operations, undefined instructions, and unexecuted instructions. 

---

# 19. Implement coprocessor instruction handling

Tasks:

1. Decode ARM coprocessor instructions:

```text
CDP
MRC
MCR
LDC
STC
```

2. Generate coprocessor pipeline-following signals:

```text
CPnMREQ
CPSEQ
CPnTRANS
CPnOPC
CPTBIT
```

3. Generate `CPnI`.

4. Sample `CPA`.

5. Sample `CPB`.

6. Implement coprocessor absent behavior.

7. Implement coprocessor busy-wait behavior.

8. Implement coprocessor ready behavior.

9. Implement abandonment of busy-waiting coprocessor instruction on interrupt/debug request.

10. Implement C-cycle bus usage.

11. Implement data transfer from ARM register to coprocessor for `MCR`.

12. Implement data transfer from coprocessor to ARM register for `MRC`.

13. Implement memory-to-coprocessor transfer for `LDC`.

14. Implement coprocessor-to-memory transfer for `STC`.

15. Implement undefined instruction trap when no coprocessor accepts the instruction.

16. Implement privileged coprocessor behavior using `CPnTRANS`.

17. Tie off external coprocessor inputs correctly when no external coprocessor is present.

The TRM says each coprocessor tracks the ARM pipeline, uses `CPnI`, `CPA`, and `CPB` for handshaking, and that unaccepted coprocessor instructions take the undefined instruction trap. 

---

# 20. Implement internal coprocessor 14: Debug Communications Channel

Tasks:

1. Implement CP14 decode for DCC instructions.

2. Implement DCC control register.

3. Implement DCC data write register.

4. Implement DCC data read register.

5. Implement processor-to-debugger transfer.

6. Implement debugger-to-processor transfer.

7. Implement `DBGCOMMTX`.

8. Implement `DBGCOMMRX`.

9. Implement JTAG access to DCC through scan chain 2.

10. Implement DCC status bits.

11. Verify polling sequences from processor side.

12. Verify polling sequences from debugger side.

The TRM states that the EmbeddedICE-RT DCC is implemented as coprocessor 14, has a 32-bit control register and 32-bit data register, and is accessed by the processor using `MCR`/`MRC` instructions to CP14. 

---

# 21. Implement CP15/system-control-facing behavior

Tasks:

1. Decode CP15 instructions.

2. Decide which CP15 behavior your target will support.

3. Implement required system-control register behavior for compatibility with ARM7TDMI-S expectations.

4. Return undefined for unsupported CP15 operations.

5. Verify privileged-only behavior.

6. Verify user-mode CP15 access traps as undefined where required.

The TRM reserves coprocessor 15 for system control and coprocessor 14 for debug, so external coprocessors must not use those IDs. 

---

# 22. Implement EmbeddedICE-RT debug macrocell

This is a large subsystem. Do it after the CPU core is stable.

Tasks:

1. Implement `DBGEN`.

2. Implement permanent debug disable behavior when `DBGEN` is low.

3. Implement debug request input `DBGRQ`.

4. Implement breakpoint/watchpoint input `DBGBREAK`.

5. Implement debug acknowledge `DBGACK`.

6. Implement debug state machine.

7. Implement halt-mode debugging.

8. Implement monitor-mode debugging.

9. Implement debug entry on breakpoint.

10. Implement debug entry on watchpoint.

11. Implement debug entry on debug request.

12. Implement debug exit sequence.

13. Implement debug interaction with exceptions.

14. Implement debug PC behavior.

15. Implement interrupt masking during debug state.

16. Implement system-speed access during debug.

17. Implement internal-cycle forcing while in debug state.

18. Implement two watchpoint units.

19. For each watchpoint unit, implement:

```text
address value register
address mask register
data value register
data mask register
control value register
control mask register
```

20. Implement breakpoint mode using instruction fetch matching.

21. Implement watchpoint mode using data access matching.

22. Implement data-dependent breakpoints/watchpoints.

23. Implement range matching.

24. Implement chained watchpoints.

25. Implement `DBGRNG[1:0]`.

26. Implement `DBGEXT[1:0]`.

27. Implement debug abort status register.

28. Implement debug control register.

29. Implement debug status register.

30. Implement EmbeddedICE-RT disable bit.

31. Implement programming sequence for breakpoint/watchpoint registers.

32. Verify breakpoint behavior with conditional instructions.

33. Verify watchpoint behavior with LDM/STM.

34. Verify watchpoint behavior with abort.

35. Verify monitor-mode abort exception entry.

36. Verify halt-mode debug entry.

The TRM describes EmbeddedICE-RT as including two real-time watchpoint units, an abort status register, the DCC, and debug control/status registers. The watchpoint units can be configured as watchpoints or breakpoints and can mask address/data/control bits. 

---

# 23. Implement JTAG TAP and scan chains

Tasks:

1. Implement TAP controller state machine.

2. Implement `DBGnTRST`.

3. Implement `DBGTCKEN`.

4. Implement `DBGTMS`.

5. Implement `DBGTDI`.

6. Implement `DBGTDO`.

7. Implement `DBGnTDOEN`.

8. Implement public JTAG instructions.

9. Implement instruction register.

10. Implement IDCODE register.

11. Implement TAP ID value `0x7F1F0F0F`.

12. Implement scan chain 1.

13. Implement scan chain 2.

14. Implement scan chain selection.

15. Implement DCC access through scan chain 2.

16. Implement EmbeddedICE-RT register access through scan chain 2.

17. Implement scan timing behavior.

18. Verify TAP reset.

19. Verify every TAP state transition.

20. Verify shifting/capturing/updating data registers.

The TRM states that ARM7TDMI-S has JTAG-style scan chains controlled by a TAP controller, and that Rev 4 has TAP ID register value `0x7F1F0F0F`.  

---

# 24. Implement ETM7-facing interface

You do not need to implement the whole ETM7 trace macrocell unless that is part of your project. But a complete ARM7TDMI-S-compatible macrocell should provide the ETM-facing signals.

Tasks:

1. Implement `DBGINSTRVALID`.

2. Implement `DBGnEXEC`.

3. Implement `CPTBIT`.

4. Expose `ADDR`.

5. Expose `RDATA`.

6. Expose `WDATA`.

7. Expose `ABORT`.

8. Expose `CPA`.

9. Expose `CPB`.

10. Expose `CPnMREQ`.

11. Expose `CPSEQ`.

12. Expose `CPnI`.

13. Expose `CPnOPC`.

14. Expose `SIZE`.

15. Expose `WRITE`.

16. Expose `PROT`.

17. Wire debug request compatibility for ETM.

18. Tie unsupported ETM processor-ID inputs low if you build an ETM wrapper.

19. Verify trace-visible instruction valid behavior.

20. Verify trace behavior across branches, exceptions, debug entry, and Thumb/ARM state changes.

The TRM’s ETM chapter says an external ETM can be connected for real-time tracing, generally with little or no glue logic, and gives the ETM7-to-ARM7TDMI-S signal mapping.  

---

# 25. Implement scan/test wrapper behavior

Tasks:

1. Implement normal-operation scan-test controls if your target includes ATPG-facing pins.

2. Implement:

```text
SCANENABLE
SCANIN
SCANOUT
```

3. Keep scan logic outside the core functional path where possible.

4. Make scan wrapper optional through parameters or synthesis defines.

5. Verify normal mode when `SCANENABLE = 0`.

6. Verify scan shift mode if you are targeting ASIC-style test insertion.

Appendix B describes an ATPG scan interface with `SCANENABLE`, `SCANIN`, and `SCANOUT`. 

---

# 26. Implement AC/timing-conscious RTL structure

Tasks:

1. Ensure all architectural state updates occur on `posedge CLK`.

2. Ensure `CLKEN` gates core/bus progress correctly.

3. Ensure debug clock-enable behavior uses `DBGTCKEN`.

4. Keep asynchronous reset handling consistent across modules.

5. Register long decode paths where necessary.

6. Avoid combinational loops in pipeline control.

7. Avoid inferred latches.

8. Split large decoders into staged decode where timing requires it.

9. Add synthesis constraints for clock, reset, and I/O timing.

10. Run lint.

11. Run CDC/reset checks if your debug clocking wrapper has asynchronous inputs.

12. Run synthesis after every major milestone.

13. Track maximum frequency, area, and critical path.

The TRM notes that all inputs are sampled on the rising edge of `CLK`, with clock enables sampled on every rising edge and other inputs sampled when the relevant clock enable is active. 

---

# 27. Build the conformance test suite

You need several layers of tests.

## Unit tests

1. Register bank mode mapping.

2. CPSR/SPSR writes.

3. ALU flags.

4. Barrel shifter carry-out.

5. Multiply results.

6. Decode tables.

7. Address generation.

8. Byte/halfword extraction.

9. Endianness.

10. Exception priority encoder.

11. TAP controller state transitions.

12. Watchpoint comparator.

## Instruction tests

1. Every ARM data-processing opcode.

2. Every ARM shifter mode.

3. Every ARM condition code.

4. Every branch type.

5. Every load/store addressing mode.

6. Every block transfer addressing mode.

7. Every multiply instruction.

8. Every swap instruction.

9. Every PSR instruction.

10. Every SWI/undefined path.

11. Every Thumb instruction group.

12. ARM/Thumb interworking.

## System tests

1. Reset boot from address `0x00000000`.

2. IRQ handling.

3. FIQ handling.

4. Nested exceptions.

5. Data abort retry.

6. Prefetch abort retry.

7. Undefined instruction trap.

8. SWI handler.

9. Thumb exception and return.

10. Debug halt entry/exit.

11. Monitor-mode debug.

12. JTAG DCC communication.

13. Coprocessor absent trap.

14. Coprocessor busy-wait and interrupt abandonment.

15. ETM-visible trace signal sanity.

## Cycle tests

1. Compare every instruction class against Chapter 7.

2. Compare bus transactions cycle by cycle.

3. Test with `CLKEN` always high.

4. Test with random `CLKEN` stalls.

5. Test with random memory aborts.

6. Test with random IRQ/FIQ arrival.

7. Test with random debug requests.

---

# 28. Recommended build order

This is the practical sequence I would follow.

## Milestone 1 — Minimal ARM core

1. Register bank.

2. CPSR.

3. ALU.

4. Barrel shifter.

5. ARM data-processing instructions.

6. Simple fetch/decode/execute loop.

7. Simple memory model.

8. Basic `B`, `BL`.

9. Basic `LDR`, `STR`.

10. Run simple ARM assembly programs.

## Milestone 2 — Full ARM architectural correctness

1. All ARM data-processing forms.

2. All ARM condition codes.

3. PSR transfers.

4. Multiply instructions.

5. All single data transfers.

6. Halfword/signed transfers.

7. Block transfers.

8. Swap.

9. SWI.

10. Undefined instruction.

11. Exceptions.

12. IRQ/FIQ.

13. Abort handling.

## Milestone 3 — Thumb support

1. Thumb decoder.

2. Thumb ALU instructions.

3. Thumb load/store instructions.

4. Thumb branches.

5. Thumb `BL`.

6. Thumb `BX`.

7. Thumb stack operations.

8. Thumb SWI.

9. ARM/Thumb interworking.

10. Thumb exception return.

## Milestone 4 — Real ARM7TDMI-S pipeline

1. Fetch/decode/execute pipeline.

2. PC-visible behavior.

3. Pipeline flush/refill.

4. Multi-cycle execute control.

5. Instruction prefetch behavior.

6. Cycle timing for branches/data operations.

7. Cycle timing for loads/stores.

8. Cycle timing for LDM/STM/SWP.

## Milestone 5 — ARM7TDMI-S bus accuracy

1. Full memory interface.

2. `TRANS` cycle generation.

3. `PROT`, `SIZE`, `WRITE`, `LOCK`.

4. Pipelined address/data timing.

5. `CLKEN` stalls.

6. Endianness.

7. Abort sampling.

8. Merged I-S cycles.

9. `DMORE`.

## Milestone 6 — Coprocessor interface

1. Coprocessor decode.

2. `CPnI`, `CPA`, `CPB`.

3. Busy-wait.

4. Absent coprocessor trap.

5. `MRC`, `MCR`.

6. `LDC`, `STC`.

7. `CDP`.

8. CP14 DCC.

9. CP15/system-control-facing behavior.

## Milestone 7 — Debug

1. Debug state machine.

2. `DBGEN`.

3. `DBGRQ`.

4. `DBGBREAK`.

5. `DBGACK`.

6. Breakpoint entry.

7. Watchpoint entry.

8. Monitor mode.

9. EmbeddedICE-RT registers.

10. Watchpoint units.

11. DCC through JTAG.

12. Debug PC behavior.

## Milestone 8 — JTAG/TAP

1. TAP controller.

2. Public JTAG instructions.

3. IDCODE.

4. Scan chain 1.

5. Scan chain 2.

6. EmbeddedICE programming through scan chain.

7. DCC through scan chain.

## Milestone 9 — ETM-facing interface

1. Trace-visible signals.

2. `DBGINSTRVALID`.

3. `DBGnEXEC`.

4. ETM pin mapping wrapper.

5. Trace tests.

## Milestone 10 — Cleanup and signoff

1. Full regression.

2. Random instruction testing.

3. Random interrupt/abort/debug testing.

4. Lint.

5. Synthesis.

6. Timing closure.

7. FPGA bring-up or ASIC-style synthesis.

8. Documentation.

---

# 29. Final “complete chip” checklist

A complete implementation should pass this checklist:

```text
[ ] ARMv4T programmer model implemented
[ ] ARM state implemented
[ ] Thumb state implemented
[ ] ARM/Thumb interworking implemented
[ ] All ARM instruction groups implemented
[ ] All Thumb instruction groups implemented
[ ] All processor modes implemented
[ ] All banked registers implemented
[ ] CPSR/SPSR behavior implemented
[ ] Reset behavior implemented
[ ] Exception vectors implemented
[ ] Exception priority implemented
[ ] IRQ/FIQ implemented
[ ] Data abort implemented
[ ] Prefetch abort implemented
[ ] SWI implemented
[ ] Undefined instruction trap implemented
[ ] 3-stage pipeline implemented
[ ] PC pipeline semantics correct
[ ] Pipeline flush/refill correct
[ ] Memory interface pins implemented
[ ] N/S/I/C cycles implemented
[ ] CLKEN wait-state support implemented
[ ] Endianness implemented
[ ] Byte/halfword/word access implemented
[ ] LOCK/SWP behavior implemented
[ ] DMORE implemented
[ ] Cycle timing matches Chapter 7
[ ] Coprocessor interface implemented
[ ] Coprocessor busy-wait implemented
[ ] Coprocessor absent trap implemented
[ ] CP14 DCC implemented
[ ] CP15/system-control-facing behavior handled
[ ] EmbeddedICE-RT implemented
[ ] Breakpoints implemented
[ ] Watchpoints implemented
[ ] Monitor mode implemented
[ ] Debug halt mode implemented
[ ] Debug status/control/abort registers implemented
[ ] JTAG TAP implemented
[ ] Scan chains implemented
[ ] TAP IDCODE implemented
[ ] ETM-facing interface implemented
[ ] ATPG/scan wrapper implemented if required
[ ] Full architectural tests pass
[ ] Full cycle tests pass
[ ] Synthesis passes
[ ] Timing constraints pass
```

The hardest parts will be **PC/pipeline semantics**, **LDM/STM abort behavior**, **Thumb interworking**, **cycle-accurate memory bus timing**, and **EmbeddedICE-RT/JTAG debug**. A good learning path is to treat the first working CPU as a stepping stone, then iteratively replace simplified behavior with the exact ARM7TDMI-S behavior from the TRM.

---

# 30. TRM gap-fill addenda (post-roadmap audit)

These items tighten or extend the §1–§29 roadmap to match TRM (`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`, 242 pages) at the level of detail any conformant implementation must hit. Numbering: **§30.N amends §N**. Page numbers refer to the PDF page (the document's printed page numbers differ).

## 30.0 ARMv4T scope guard — features NOT in r4p3

Do not implement; remove if mistakenly introduced:

1. `BKPT` instruction — ARMv5+ only. Software breakpoints on r4p3 are pattern-matched via EmbeddedICE-RT, not via a `BKPT` opcode (TRM §1.2 / §B.1).
2. `BLX` (immediate or register) — ARMv5+. ARM↔Thumb exchange on r4p3 is `BX` only.
3. `CLZ` — ARMv5+.
4. Q (saturation) flag in CPSR — ARMv5E+.
5. ARM7TDMI hard-macrocell pin names absent from r4p3: `MAS[1:0]` (replaced by `SIZE[1:0]`), `ABE/DBE/TBE`, `ALE/APE`, `BL`, bidirectional `D`, `nM`, `BUSDIS/BUSEN/NnENIN/nNENOUT/nENOUTI` (TRM §B.4.6 Table B-2).
6. Plausible-sounding pins that do not exist: `DBGRESTART`, `DBGINSTR`. `RESTART` is a JTAG TAP *instruction* (`4'b0100`); debug-state instruction injection is via scan chain 1 with bit 33 selecting debug-speed vs system-speed (§30.23.6). `DBGINSTRVALID` is real and distinct.

## 30.3 Programmer-visible state (amends §3)

1. **CPSR/SPSR explicit bit map** (TRM §2.8 Fig. 2-6, p. 48):
   - `[31]=N`, `[30]=Z`, `[29]=C`, `[28]=V` — flags.
   - `[27:8]` reserved — preserve under read-modify-write; never assume a value (TRM §2.8.3, p. 50).
   - `[7]=I` (IRQ disable), `[6]=F` (FIQ disable), `[5]=T` (state), `[4:0]=M[4:0]` (mode).
   - SPSRs share the layout. **No Q flag** (ARMv4T).
2. FIQ banks **7** registers (`r8_fiq…r14_fiq` + `SPSR_fiq`); other exception modes bank only `r13_xxx, r14_xxx, SPSR_xxx` (TRM §2.7.1, p. 56).
3. System mode (`M[4:0]=11111`): privileged, shares User register set, no SPSR (TRM §2.6 / Table 2-2).

## 30.4 Reset (amends §4)

1. `nRESET` must be held LOW for ≥ 2 `CLK` cycles. While LOW, the bus is forced into I-cycles; any in-flight instruction abandons on the next non-wait cycle. On rising `nRESET`, fetching restarts at `0x00000000` (TRM Appendix A `nRESET`, p. 222).
2. `CFGBIGEND` is *static*. Tie or hold stable; must not change during debug. To reconfigure endianness, hold `nRESET` LOW (TRM §5.3.4 Note, p. 121).

## 30.5 Datapath primitives (amends §5)

1. **Multiplier early-termination `m` parameter** drives every multiply's cycle count:
   - `m=1` if `Rs[31:8]` are all 0 or all 1.
   - `m=2` if `Rs[31:16]` are all 0 or all 1.
   - `m=3` if `Rs[31:24]` are all 0 or all 1.
   - `m=4` otherwise.
   - `MUL`: `m·I + S`. `MLA`: `(m+1)·I + S`. `MULL/SMULL`: `(m+1)·I + S`. `MLAL/SMLAL`: `(m+2)·I + S` (TRM §7.7 Tables 7-7..7-10, pp. 194–195).
   - `MULL/MLAL` are ARM-state-only; `MUL` is the only Thumb multiply.

## 30.8 PSR transfer (amends §8 / §9)

1. `MSR` field-mask bits (per Table 1-10): `_c`=bit 16 (control), `_x`=bit 17 (extension, RAZ/SBZP), `_s`=bit 18 (status, RAZ/SBZP), `_f`=bit 19 (flags).
2. User mode may write only `_f` of `CPSR`; privileged modes write any field.
3. **`MSR` and the T bit**: TRM §2.8.2 (p. 49) says programs *must not* alter the T bit via `MSR` — behavior is UNPREDICTABLE. Pick a hardware policy (drop the T-bit write, or honor it and let the architectural UNPREDICTABLE bite); document the choice and exercise with a cycle test.

## 30.10 Branch (amends §10)

1. `B`/`BL` cycle order (TRM §7.3 Table 7-3):
   - Cycle 1: prefetch from current PC continues + destination computed (the prefetch already issued — too late to cancel).
   - Cycle 2: N-cycle fetch from branch destination; if `BL`, save `(PC+i)` to `r14`.
   - Cycle 3: S-cycle fetch from `dest+i`; if `BL`, post-decrement `r14` by 4 so `MOV PC, R14` returns to instruction *after* the BL.
2. Thumb `BL` is two halfwords (TRM §7.4 Table 7-4): first executes as a data-op accumulating `PC + upper_offset` into `r14`; second performs the branch with `r14` fix-up of −2.
3. `BX` cycle order (TRM §7.5 Table 7-5):
   - Cycle 1: `ADDR=PC+2i`, T = current state.
   - Cycle 2: `ADDR=pc'`, T = new state. `CPTBIT` reflects the new state from this cycle on.
   - Cycle 3: `ADDR=pc'+i'`. ARM→Thumb: `i=4, i'=2`; Thumb→ARM: `i=2, i'=4`.

## 30.12 Block data transfer (amends §12)

1. **LDM data abort** (TRM §2.9.6, p. 54; §7.10, p. 199):
   - Complete the instruction but suppress all destination-register writes that follow the abort.
   - If the writeback bit is set, the modified base register *is* written (handler sees post-modified base — restore manually if it must be undone).
   - r15 is always last in the list, so any abort prevents PC overwrite.
2. **STM** writeback completes normally on abort; handler must be aware base is updated.
3. **Empty register list** in LDM/STM is architecturally UNPREDICTABLE; pick a behavior (TRM is silent), document it, and lock it in a cycle test.

## 30.13 SWP (amends §13)

1. `LOCK` HIGH for both data cycles of `SWP/SWPB`. Sequence (TRM §7.12 Table 7-15): `N(prefetch) → N(read, LOCK=1) → I(write, LOCK=1) → S(continue prefetch, LOCK=0)`.
2. SWP is **ARM-state only**.
3. On data abort, `SWP` behaves as if it had not executed; the abort must occur on the read access.

## 30.14 Exceptions (amends §14)

1. **Return-address offsets per exception** (TRM §2.9.1 Table 2-3, p. 51):
   - `BL`/`SWI`/`Undef` from ARM ⇒ save `PC+4` to LR; from Thumb ⇒ save `PC+2`.
   - Prefetch Abort ⇒ save `PC+4`; return via `SUBS PC, R14_abt, #4`.
   - Data Abort ⇒ save `PC+8`; return via `SUBS PC, R14_abt, #8`.
   - IRQ/FIQ ⇒ save `PC+4`; return via `SUBS PC, R14_xxx, #4`.
   - Reset: `r14_svc` is UNPREDICTABLE.
2. **Data Abort + FIQ coincidence**: enter the Data Abort handler first, then immediately vector to FIQ at `0x1C`. A naive priority encoder that fires only the highest-priority exception loses the abort (TRM §2.9.10, p. 60).
3. `nFIQ` and `nIRQ` are **synchronous, level-sensitive**, sampled on rising `CLK`. Hold LOW until handler clears the source. Async sources need an external synchronizer — r4p3 has no `ISYNC` pin (TRM Appendix A; §B.4.4).
4. **Worst-case FIQ latency** = `T_syncmax + T_ldm + T_exc + T_fiq = 2 + 20 + 3 + 2 = 27 cycles` (zero-wait-state, longest LDM including PC). Min FIQ/IRQ latency = 4 cycles. Verify in §27 (TRM §2.10, p. 60).

## 30.17 Memory interface (amends §17)

1. **Von Neumann bus** — instruction and data share `ADDR/RDATA/WDATA`. The pipeline arbitrates one bus cycle for either fetch or data, never both (TRM §1.1.2, p. 19).
2. **Burst rules** (TRM §3.3, pp. 77–79):
   - Bursts are word (+4 per S) or halfword (+2 per S) only. **Byte bursts do not exist.**
   - Within a burst, `WRITE/SIZE/PROT/LOCK` hold constant; only `ADDR` advances.
   - A burst opens with N (or merged I-S); subsequent beats are S.
   - During an I cycle the address of the next sequential access is broadcast for early decode, but the memory controller must not commit during the I cycle (an I may be followed by an N to an unrelated address on PC writes/exceptions).
3. **`SIZE` encoding** (TRM §3.4.3 Table 3-3): `00=byte`, `01=halfword`, `10=word`, `11=reserved` (never generated; assert).
4. **Significant-address-bit rule** (TRM §3.5.4 Table 3-6): word — use `ADDR[31:2]`; halfword — `ADDR[31:1]`; byte — `ADDR[31:0]`.
5. **`ABORT` sampling** (TRM §3.5.3, p. 87): sampled on rising `CLK` *only during S/N memory cycles*; ignored in I/C. On data access, traps immediately. On opcode fetch, marks the prefetched instruction invalid; trap fires only when (and if) it reaches Execute.
6. **`DMORE`** (TRM §1.5.5, p. 40 / Appendix A): HIGH during the current data access ⇒ next data access *will* be sequential (mid-LDM/STM). LOW ⇒ last beat or no immediate further data access. Distinct from `TRANS[1:0]`, which describes the next *transaction's* type.
7. During `nRESET` LOW the bus is forced into I-cycles; existing memory cycles abandon. No spurious access on the way to `0x00000000`.

## 30.18 Cycle accuracy (amends §18)

Anchor each cycle test to an explicit TRM table:

1. **Data-op** (Table 7-6, p. 194): `+S` (1S); shifted-by-register form adds an I.
2. **MSR/MRS** (Table 7-6).
3. **LDR** (Table 7-11, p. 196): `+N+I+S`; if `Rd=PC`, add `+N+S`.
4. **STR** (Table 7-12, p. 196): `+N+N`.
5. **LDM** (Table 7-13, p. 196):
   - 1 reg, dest≠PC: `+N+I+S`.
   - 1 reg, dest=PC: `+N+I+N+2S`.
   - n>1, dest≠PC: `+N+(n−1)S+I+S`.
   - n>1, dest=PC: `+N+(n−1)S+I+N+2S`.
6. **STM** (Table 7-14, p. 197):
   - 1 reg: `+N+N`.
   - n>1: `+N+(n−1)S+N`.
7. **SWP** (Table 7-15): per §30.13.
8. **Exception entry** (Table 7-16, p. 201): `+N+2S` total (cycle 1 N to `PC+2i` in old mode; cycle 2 S to vector `Xn` in new mode/Tbit; cycle 3 S to `Xn+4`).
9. **B/BL** (Table 7-3): `+N+2S`.
10. **BX** (Table 7-5): `+N+2S` with Tbit transitions per §30.10.3.
11. **MUL/MLA/MULL/MLAL** (Tables 7-7..7-10): per §30.5.1.
12. **CDP** (Table 7-17, p. 201): `+S` plus busy-wait I cycles if `CPB` HIGH.
13. **LDC/STC** (Tables 7-18 / 7-19): `+N+(n−1)S+I` per word with leading busy-wait I.
14. **MCR/MRC** (Tables 7-20 / 7-21): `+N+I+S` (`MRC`), `+N+I` (`MCR`).
15. **Undef / coprocessor-absent trap** (Table 7-22): same path as exception entry.
16. **Unexecuted instruction** (Table 7-23, p. 204): exactly `+S` at `PC+2i`. All side effects suppressed except the bus cycle and `DBGnEXEC` HIGH. Easy smoke test.

## 30.19 Coprocessor interface (amends §19)

1. **Reserved CP IDs** (TRM §4.1.1 Table 4-1): CP15=system control, CP14=DCC + Abort Status Register, CP13:8=ARM-reserved, CP7:4=user-available, CP3:0=ARM-reserved. External coprocessors must use CP4–CP7.
2. **Pipeline-following** (TRM §4.3, p. 93): coprocessors mirror the core. Load into pipeline on rising `CLK` only when `CPnOPC=0 ∧ CPnMREQ=0 ∧ CPTBIT=0` were *all* LOW in the *previous* bus cycle (= ARM-state opcode fetch). Advance pipeline when the same triple is LOW in the *current* cycle. Coprocessor state changes only when `CLKEN` HIGH (except reset).
3. **Privilege via `CPnTRANS`** (TRM §4.8 Table 4-4): `CPnTRANS=0`=User, `=1`=privileged. Coprocessor checks at decode; User-mode access to a privileged-only operation is rejected with `CPA=1, CPB=1` (absent), forcing the undef trap.
4. **Busy-wait abandonment** (TRM §4.4.4, p. 96; §5.3.3, p. 121): on a non-masked IRQ/FIQ or `DBGRQ`, the core takes `CPnI` HIGH. Coprocessor monitors `CPnI` and abandons. Coprocessor actions during busy-wait must be *idempotent* — must not corrupt state and must repeat with identical results.
5. **No-coprocessor tie-off** (TRM §4.6, p. 102; Table 4-3): tie `CPA=1, CPB=1`; leave outputs `CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPnI, CPTBIT` unconnected. All coprocessor instructions then take the undef trap. For multiple coprocessors: AND each one's `CPA` together, AND each one's `CPB` together; common `CPnI` fans out.
6. **`CPn`-prefix polarity reminder**: active-LOW (`CPnOPC=0` ⇒ opcode fetch). `CPSEQ`, `CPA`, `CPB` are active-HIGH.
7. LDC/STC may transfer >16 words; this stretches worst-case interrupt latency past 27 cycles. Recommend a 16-word software cap.

## 30.20 CP14 / DCC (amends §20)

1. **CP14 register set**:
   - DCC control register (32-bit): `[31:28]=4'b0001` (EmbeddedICE-RT version constant), `[27:2]` reserved, `[1]=W` (W=1 ⇒ tx buffer empty, processor may write; debugger-readable, processor-writable), `[0]=R` (R=1 ⇒ rx buffer full, processor may read; debugger-writable, processor-readable).
   - DCC data-read / data-write register.
   - **Abort Status Register (1 bit `DbgAbt`)** — accessed via `MRC/MCR CP14`. Set when monitor mode causes a Prefetch/Data Abort due to a breakpoint or watchpoint; if both an external `ABORT` and a debug abort coincide, external `ABORT` wins and `DbgAbt` stays 0. Sticky; cleared by software write (TRM §5.23, p. 161).
2. **DCC instructions**:
   - `MRC CP14,0,Rd,C0,C0` — read DCC control.
   - `MRC CP14,0,Rd,C1,C0` — read DCC data-read.
   - `MCR CP14,0,Rn,C1,C0` — write DCC data-write.
3. **Rev 4 single-access optimization** (TRM §5.10.2, pp. 134–135): DCC data and status fit in one scan-chain-2 access; status bit is the LSB of the address field returned. DCC control bit 0 preserved for backward compatibility.
4. **`DBGCOMMRX/TX` polarity** (Appendix A): `DBGCOMMRX=1` ⇒ rx buffer full; `DBGCOMMTX=1` ⇒ tx buffer empty. Both gated by `DBGEN=1`.
5. Coprocessor instructions, **including DCC `MCR/MRC` to CP14, do not exist in Thumb**. Monitor-mode debugger code reaching DCC from Thumb must switch to ARM first.

## 30.22 EmbeddedICE-RT (amends §22)

1. **`DBGEN=0`**: `DBGBREAK/DBGRQ` ignored; `DBGACK` forced LOW; interrupts pass through; macrocell enters low-power. **Caution from TRM**: tying `DBGEN` LOW is not a security mechanism — implement security elsewhere if required (TRM §5.7, p. 124).
2. **Watchpoint mask is XNOR, not AND** (TRM §5.20.2 / §5.26):
   - `match = ((value XNOR input) OR mask) == all-1s`.
   - Mask bit = 1 ⇒ that position always matches; mask bit = 0 ⇒ exact equality required. Common implementation bug is to AND.
3. **Watchpoint coupling** (TRM §5.20.3 / §5.26.1, pp. 169–170):
   - `CHAIN`: WP1's `CHAINOUT` feeds WP0's `CHAIN`. WP1 has no CHAIN input; WP0 has no CHAINOUT.
   - `CHAINOUT` is a latch: write-enable from WP1's address/control comparator, D-input from WP1's data comparator. Cleared on control-value-register write or `DBGnTRST=0`.
   - `RANGE`: WP1's `RANGEOUT` feeds WP0's `RANGE`. Power-of-2 ranges only.
   - `DBGRNG[1:0]` external pins reflect each watchpoint's address/control + data-mask match **independent of the ENABLE bit** (so trace can see range hits without breaking).
   - ENABLE = bit 8 of the 9-bit control-value register; **unmaskable** (no mask-register equivalent for bit 8).
4. **Debug Control Register — 6 bits** (TRM §5.24 Table 5-7, p. 161):
   - `[5]` EmbeddedICE-RT disable (Rev 4).
   - `[4]` Monitor-mode enable (Rev 4 — abort vs halt).
   - `[3]` SBZ/RAZ.
   - `[2]` `INTDIS` (force `IFEN` LOW; mask interrupts even outside debug).
   - `[1]` force-`DBGRQ`.
   - `[0]` force-`DBGACK`.
5. **Debug Status Register — 5 bits, read-only** (TRM §5.25, p. 164):
   - `[4]=TBIT, [3]=TRANS[1], [2]=IFEN, [1]=synced DBGRQ, [0]=synced DBGACK`.
6. **Interrupt-mask logic** (TRM Fig. 5-17, p. 165): `IFEN_to_core = !((bit2 OR DBGACKI) | INTDIS)`. `DBGACK_pin = bit0 OR DBGACKI`. `DBGRQI_to_core = bit1 OR sync(DBGRQ_input)`.
7. **Reprogramming sequence under monitor mode** (TRM §5.9.2, p. 130):
   1. Set debug-control bit 5 (disable).
   2. **Poll** bit 5 read-back until set.
   3. Modify watchpoint registers and/or bit 4.
   4. Clear bit 5.
   - Poll step is mandatory — propagation is async; skipping it causes false matches.
8. **Software breakpoints** (TRM §5.21.2, p. 150):
   - Program a watchpoint with a magic data-value pattern and `0xFFFFFFFF` address mask.
   - For Thumb, **replicate** the 16-bit pattern in both halves of the 32-bit data-value register (a `LDR` may return either halfword on the 32-bit bus).
   - Architectural reservations for breakpoint encodings: ARM `0xE7Fxxxxx`, Thumb `0xDExx/0xBExx`. (No `BKPT` opcode on r4p3 — see §30.0.)
9. **Breakpoint flushed by branch/exception** (TRM §5.3.1, p. 120): if the instruction is flushed (preceding branch / exception / PC write), debug entry is canceled. On exception return + refetch, the breakpoint reflags. Comparator's ENABLE qualification must combine with a pipeline-valid signal.
10. **Watchpoint completion** (TRM §5.3.2 / §5.18.3): fires *after* the access completes (data writeback / base writeback finished). For LDM/STM, many cycles can elapse between match and entry. Watchpointed access that also Data Aborts ⇒ debug state entered in abort mode (vector fetch first). Watchpointed access coincident with another exception ⇒ debug state entered in that exception's mode; debugger disambiguates via CPSR/SPSR/PC.
11. **Monitor-mode restrictions** (TRM §5.9.2): in monitor mode, breakpoints/watchpoints **cannot** be data-dependent, range-coupled, or externally-conditioned via `DBGEXT`. External `DBGBREAK` not supported. Halt and monitor modes cannot mix.
12. **IFEN auto-disable in debug state** (TRM §5.19.2, p. 147): on debug-state entry, IRQ and FIQ are forced disabled internally regardless of `CPSR.I/F`. Pending interrupts at entry are remembered.
13. **Debug-exit return-PC offsets** (TRM §5.18.6, p. 146):
   - Normal break/watch exit: `−(4 + N + 3S)`, with N = debug-speed, S = system-speed.
   - DBGRQ-entry / watchpoint-with-exception: `−(3 + N + 3S)`.
   - System-speed access drops `DBGACK` temporarily; force via control-bit 0 if peripherals must be held inhibited.
14. **Allowable debug-state instructions** (TRM §5.16.1, p. 162): only data-processing, all loads/stores including LDM/STM, and MSR/MRS may be scanned in. STM is the standard register-file dump path. Mode changes between any two modes are allowed in debug state.

## 30.23 JTAG TAP and scan chains (amends §23)

1. **Public JTAG instructions — exactly five** (TRM §5.13 Table 5-3, p. 153):
   `SCAN_N=4'b0010`, `INTEST=4'b1100`, `IDCODE=4'b1110`, `BYPASS=4'b1111`, `RESTART=4'b0100`. Other 4-bit encodings default to `BYPASS`.
2. **Do NOT implement** `EXTEST/SAMPLE/PRELOAD/CLAMP/HIGHZ/CLAMPZ` — there is no boundary-scan chain on r4p3. Selecting them while scan chain 1 or 2 is active yields UNPREDICTABLE behavior (TRM §B.4.3, p. 233).
3. **IR width = 4 bits**, no parity. CAPTURE-IR loads fixed pattern `4'b0001` (LSB-first). SHIFT-IR shifts in LSB-first. UPDATE-IR latches. Reset value = `IDCODE` (TRM §5.14.3, p. 156).
4. **IDCODE** (TRM §5.14.2, p. 155):
   - 32-bit format `[31:28]=Version, [27:12]=PartNumber, [11:1]=ManufacturerID, [0]=1` (LSB always 1 per IEEE 1149.1; do not tie LOW).
   - r4p3 default value `0x7F1F0F0F` (matches CLAUDE.md).
   - No parallel write. CAPTURE-DR loads the constant; SHIFT-DR clocks LSB-first; UPDATE-DR is a no-op for IDCODE.
5. **Scan chain map**:
   - 0: reserved (returns zeros if selected).
   - 1: debug, **33 bits** = `[31:0]` data + bit 33 (= `[32]`) `DBGBREAK` cell.
   - 2: EmbeddedICE-RT, **38 bits** = `[37]` R/W + `[36:32]` 5-bit reg-addr + `[31:0]` data; commit on UPDATE-DR.
   - 3, 4, 8: reserved.
6. **Scan chain 1 bit-33 dual semantics** (TRM §5.14.5 / §5.16):
   - During INTEST: scans a known value into the `DBGBREAK` input.
   - During debug-state instruction injection: bit 33 = 0 ⇒ run at debug speed; bit 33 = 1 ⇒ run at system speed (sync to `CLKEN`).
   - On debug-state entry capture: bit 33 = 0 ⇒ entered from breakpoint; bit 33 = 1 ⇒ from watchpoint.
   - For a system-speed access: bit 33 HIGH on the penultimate scanned instruction; the final branch has bit 33 LOW. After RESTART, the core executes at full speed via `CLKEN` then re-enters debug state.
7. **TAP reset via `DBGnTRST=0`** (TRM §5.3.5 Fig. 5-4, p. 117; §5.12.1, p. 152):
   - TAP state machine → Test-Logic-Reset.
   - Current instruction → `IDCODE`.
   - Active scan chain → 0.
   - All EmbeddedICE-RT D-types in Fig. 5-4 cleared (TCK synchronizer, TMS/TDI sample-hold).
   - `CHAINOUT` cleared.
   - No `CLK`/`DBGTCKEN` pulse needed.
   - For JTAG use, `DBGnTRST` must pulse LOW then HIGH at power-on; tie LOW permanently if JTAG unused.
8. **`DBGnTDOEN` polarity** (Appendix A): LOW = TDO actively driven; HIGH = HiZ. Gated by `DBGEN`.
9. **3-stage TCK synchronizer** to `CLK` for off-chip Multi-ICE-style debug (TRM Fig. 5-4); off-chip device must wait on `RTCK` before the next TCK edge. TMS/TDI on-chip latches gated by `DBGTCKEN`. All synchronizer flops reset by `DBGnTRST`.
10. **Scan-path-select register**: 4 bits; CAPTURE-DR loads `4'b1000`; UPDATE-DR latches selection. Default chain 0 on TAP reset.

## 30.24 ETM-facing interface (amends §24)

1. **`DBGINSTRVALID`** = HIGH for exactly one cycle per instruction *committed* to Execute. Used by ETM7 to count executed instructions, **not** bus accesses (Appendix A).
2. **Combination rule**: instruction committed = `DBGINSTRVALID && !DBGnEXEC`. `DBGnEXEC` HIGH means an instruction reached Execute but failed its condition codes (no commit).
3. **PROCID tie-off**: r4p3 has no OS context-ID source. When wrapping ETM7, tie `PROCID[31:0]=0` and `PROCIDWR=0` at the ETM input (TRM §6.3 Table 6-1 footnotes, p. 175).
4. **Direct RDATA/WDATA exposure**: connect `RDATA[31:0]` and `WDATA[31:0]` straight to the ETM so coprocessor cycles can be traced (TRM §4.5.1 Note, p. 100).
5. **Reset propagation**: connect system `nTRST`→`DBGnTRST` so `PWRDOWN` and ETM state reset in lockstep with the macrocell (TRM §6.4, p. 176).

## 30.26 AC / timing (amends §26)

1. Bake the TRM Table 8-1 percentage-of-`CLK` budgets into SDC once a toolchain is chosen (TRM §8.2, pp. 216–217). Sample budgets:
   - **Setup**: `CLKEN` 40%, `ABORT` 15%, `RDATA` 10%, `CPA/CPB` 20%, `nFIQ/nIRQ/nRESET` 10%, `CFGBIGEND` 10%, `DBGTCKEN` 40%, `DBGTDI/DBGTMS` 35%.
   - **Hold**: 0% on most inputs (clock-skew budget only).
   - **Output valid (max % of t_cyc)**: `ADDR` 90%, control (`WRITE/SIZE/PROT/LOCK`) 90%, `TRANS` 50%, `WDATA` 40%, `DBGTDO` 20%, debug control 40%, debug status 40%, coprocessor control 80%.
2. Off-chip JTAG path needs the 3-stage TCK synchronizer (§30.23.9) and the `RTCK`-handshake convention.

## 30.27 Conformance tests (amends §27)

1. Each cycle test cites a specific TRM table (§30.18). Regressions stay traceable.
2. Worst-case-FIQ-latency cycle test targeting 27 cycles (§30.14.4).
3. CHAIN/RANGE coupling reference cases (TRM §5.26):
   - "Break on address Y only when process X is running" (CHAIN: WP1 matches process-ID location with `data=X` ⇒ `CHAINOUT` enables WP0).
   - "Break on first 256 bytes but not first 32" (RANGE: WP1 disabled, mask `0x1F`; WP0 enabled, mask `0xFF`, RANGE bit cleared).
4. `MSR` T-bit-write policy test — verify the implementation matches its documented choice (drop vs honor; §30.8.3).
5. Software-breakpoint replication test for Thumb — verify both halfwords of the 32-bit data-value register match.
6. `ABORT`-during-I-cycle ignored — explicit negative test.
7. Unexecuted-instruction `+S` cycle (§30.18.16) as a smoke test.

## 30.29 Final checklist additions (amends §29)

```text
[ ] Exception-entry return-address offsets per Table 2-3 verified
[ ] LDM abort writeback + r15-protect verified
[ ] SWP LOCK held across both data cycles
[ ] FIQ-after-Data-Abort interlock verified
[ ] Worst-case 27-cycle FIQ latency verified
[ ] CFGBIGEND tied static; not changed mid-debug
[ ] nRESET ≥ 2 cycle hold modeled in TB
[ ] CPSR/SPSR explicit bit map (no Q flag) implemented
[ ] MSR T-bit-write policy chosen, documented, and tested
[ ] Multiplier early-termination m parameter verified per Tables 7-7..7-10
[ ] ABORT sampled only on S/N cycles
[ ] Burst rules (constant control, +4/+2 ADDR, no byte burst) verified
[ ] DMORE distinct from TRANS verified
[ ] CP14 Abort Status Register implemented and DbgAbt sticky
[ ] DCC Rev-4 single-access optimization in scan chain 2
[ ] Watchpoint mask is XNOR (not AND)
[ ] CHAINOUT latch + clear on CV-write / DBGnTRST
[ ] DBGRNG independent of ENABLE bit
[ ] Debug control register = 6 bits per Table 5-7
[ ] Debug status register = 5 bits per §5.25
[ ] Reprogramming poll sequence (set bit5 → poll → modify → clear) implemented
[ ] Scan chain 1 = 33 bits with bit-33 dual semantics
[ ] Scan chain 2 = 38 bits committed on UPDATE-DR
[ ] Public JTAG instruction set = exactly 5 (others default to BYPASS)
[ ] EXTEST/SAMPLE/PRELOAD/CLAMP/HIGHZ not implemented
[ ] IDCODE LSB tied 1, value 0x7F1F0F0F
[ ] DBGnTRST resets TAP / instruction / chain-select / CHAINOUT / sync flops
[ ] DBGINSTRVALID + !DBGnEXEC = committed instruction (ETM)
[ ] PROCID/PROCIDWR tied LOW at ETM wrapper
[ ] No BKPT / BLX / CLZ / Q / MAS / DBGRESTART / DBGINSTR introduced
```
