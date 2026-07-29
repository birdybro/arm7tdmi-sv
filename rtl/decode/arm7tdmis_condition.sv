// Condition-code evaluator (TASKS.md §6).
//
// Every ARM-state instruction has a 4-bit cond field at instr[31:28]; this
// module maps that field to a single pass/fail bit using the current CPSR
// flags. In Thumb state only branches carry a condition field (the other
// instructions are unconditional), but the same evaluator applies.
//
// Suppression on condition failure (tasks 4–6) and DBGnEXEC generation
// (task 7) are control-unit responsibilities, not this module's:
//   - The execute stage gates register/memory/CPSR writes on
//     `condition_pass`.
//   - DBGnEXEC is HIGH whenever an instruction reaches Execute but
//     `condition_pass=0` (TRM §30.18.16 / §3.5).
//   - Cycle accounting is independent of `condition_pass`: an instruction
//     that fails its condition still consumes the same number of cycles
//     it would have on success (TRM §7.20 Table 7-23 — "+S" at PC+2i).
//
// COND_NV is UNPREDICTABLE in ARMv4. ARMv5+ repurposed the encoding for
// unconditional instructions (BLX-imm, PLD); this ARM7TDMI-S implementation
// applies its stable policy of taking a precise Undefined Instruction trap.
// We expose `cond_is_nv` as a defense-in-depth route to that trap;
// `condition_pass` is forced 0 so no ordinary instruction side effect can
// occur even if the classification is changed accidentally.

module arm7tdmis_condition
    import arm7tdmis_instr_pkg::*;
(
    input  cond_e cond,
    input  logic  n_flag,
    input  logic  z_flag,
    input  logic  c_flag,
    input  logic  v_flag,
    output logic  condition_pass,
    output logic  cond_is_nv
);

    always_comb begin
        unique case (cond)
            COND_EQ: condition_pass =  z_flag;
            COND_NE: condition_pass = !z_flag;
            COND_CS: condition_pass =  c_flag;            // also HS
            COND_CC: condition_pass = !c_flag;            // also LO
            COND_MI: condition_pass =  n_flag;
            COND_PL: condition_pass = !n_flag;
            COND_VS: condition_pass =  v_flag;
            COND_VC: condition_pass = !v_flag;
            COND_HI: condition_pass =  c_flag && !z_flag;
            COND_LS: condition_pass = !c_flag ||  z_flag;
            COND_GE: condition_pass = (n_flag == v_flag);
            COND_LT: condition_pass = (n_flag != v_flag);
            COND_GT: condition_pass = !z_flag && (n_flag == v_flag);
            COND_LE: condition_pass =  z_flag || (n_flag != v_flag);
            COND_AL: condition_pass = 1'b1;
            COND_NV: condition_pass = 1'b0;               // ARMv4 policy: trap
            default: condition_pass = 1'b0;
        endcase
    end

    assign cond_is_nv = (cond == COND_NV);

endmodule
