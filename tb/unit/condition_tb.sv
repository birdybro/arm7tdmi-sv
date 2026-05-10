// Unit test for arm7tdmis_condition (TASKS.md §6). Combinational.
//
// Exhaustive: each of the 16 cond codes tested across multiple flag
// combinations chosen to drive the result both ways.

module condition_tb
    import arm7tdmis_instr_pkg::*;
;

    cond_e cond;
    logic  n_flag, z_flag, c_flag, v_flag;
    logic  condition_pass;
    logic  cond_is_nv;

    arm7tdmis_condition dut (.*);

    int errors;

    task automatic check(string label, logic expected_pass, logic expected_nv);
        #1;
        if (condition_pass !== expected_pass) begin
            $display("FAIL [%s]: pass expected %0b got %0b",
                     label, expected_pass, condition_pass);
            errors = errors + 1;
        end
        if (cond_is_nv !== expected_nv) begin
            $display("FAIL [%s]: cond_is_nv expected %0b got %0b",
                     label, expected_nv, cond_is_nv);
            errors = errors + 1;
        end
    endtask

    task automatic set_flags(logic n, logic z, logic c, logic v);
        n_flag = n; z_flag = z; c_flag = c; v_flag = v;
    endtask

    initial begin
        errors = 0;
        set_flags(0, 0, 0, 0);

        // ---- EQ: Z==1 ----
        cond = COND_EQ; set_flags(0, 1, 0, 0); check("EQ Z=1", 1, 0);
        cond = COND_EQ; set_flags(0, 0, 0, 0); check("EQ Z=0", 0, 0);

        // ---- NE: Z==0 ----
        cond = COND_NE; set_flags(0, 1, 0, 0); check("NE Z=1", 0, 0);
        cond = COND_NE; set_flags(0, 0, 0, 0); check("NE Z=0", 1, 0);

        // ---- CS / CC ----
        cond = COND_CS; set_flags(0, 0, 1, 0); check("CS C=1", 1, 0);
        cond = COND_CS; set_flags(0, 0, 0, 0); check("CS C=0", 0, 0);
        cond = COND_CC; set_flags(0, 0, 1, 0); check("CC C=1", 0, 0);
        cond = COND_CC; set_flags(0, 0, 0, 0); check("CC C=0", 1, 0);

        // ---- MI / PL ----
        cond = COND_MI; set_flags(1, 0, 0, 0); check("MI N=1", 1, 0);
        cond = COND_MI; set_flags(0, 0, 0, 0); check("MI N=0", 0, 0);
        cond = COND_PL; set_flags(1, 0, 0, 0); check("PL N=1", 0, 0);
        cond = COND_PL; set_flags(0, 0, 0, 0); check("PL N=0", 1, 0);

        // ---- VS / VC ----
        cond = COND_VS; set_flags(0, 0, 0, 1); check("VS V=1", 1, 0);
        cond = COND_VS; set_flags(0, 0, 0, 0); check("VS V=0", 0, 0);
        cond = COND_VC; set_flags(0, 0, 0, 1); check("VC V=1", 0, 0);
        cond = COND_VC; set_flags(0, 0, 0, 0); check("VC V=0", 1, 0);

        // ---- HI: C && !Z ----
        cond = COND_HI; set_flags(0, 0, 1, 0); check("HI C=1 Z=0", 1, 0);
        cond = COND_HI; set_flags(0, 1, 1, 0); check("HI C=1 Z=1", 0, 0);
        cond = COND_HI; set_flags(0, 0, 0, 0); check("HI C=0 Z=0", 0, 0);

        // ---- LS: !C || Z ----
        cond = COND_LS; set_flags(0, 0, 0, 0); check("LS C=0 Z=0", 1, 0);
        cond = COND_LS; set_flags(0, 1, 1, 0); check("LS C=1 Z=1", 1, 0);
        cond = COND_LS; set_flags(0, 0, 1, 0); check("LS C=1 Z=0", 0, 0);

        // ---- GE: N==V ----
        cond = COND_GE; set_flags(0, 0, 0, 0); check("GE N=0 V=0", 1, 0);
        cond = COND_GE; set_flags(1, 0, 0, 1); check("GE N=1 V=1", 1, 0);
        cond = COND_GE; set_flags(1, 0, 0, 0); check("GE N=1 V=0", 0, 0);
        cond = COND_GE; set_flags(0, 0, 0, 1); check("GE N=0 V=1", 0, 0);

        // ---- LT: N!=V ----
        cond = COND_LT; set_flags(0, 0, 0, 0); check("LT N=0 V=0", 0, 0);
        cond = COND_LT; set_flags(1, 0, 0, 0); check("LT N=1 V=0", 1, 0);
        cond = COND_LT; set_flags(0, 0, 0, 1); check("LT N=0 V=1", 1, 0);

        // ---- GT: !Z && N==V ----
        cond = COND_GT; set_flags(0, 0, 0, 0); check("GT N=V Z=0", 1, 0);
        cond = COND_GT; set_flags(0, 1, 0, 0); check("GT N=V Z=1", 0, 0);
        cond = COND_GT; set_flags(1, 0, 0, 0); check("GT N!=V Z=0", 0, 0);

        // ---- LE: Z || N!=V ----
        cond = COND_LE; set_flags(0, 1, 0, 0); check("LE Z=1", 1, 0);
        cond = COND_LE; set_flags(1, 0, 0, 0); check("LE N!=V", 1, 0);
        cond = COND_LE; set_flags(0, 0, 0, 0); check("LE N=V Z=0", 0, 0);

        // ---- AL: always pass ----
        cond = COND_AL; set_flags(0, 0, 0, 0); check("AL 0000", 1, 0);
        cond = COND_AL; set_flags(1, 1, 1, 1); check("AL 1111", 1, 0);

        // ---- NV: never pass; cond_is_nv asserts ----
        cond = COND_NV; set_flags(0, 0, 0, 0); check("NV 0000", 0, 1);
        cond = COND_NV; set_flags(1, 1, 1, 1); check("NV 1111", 0, 1);

        if (errors == 0) begin
            $display("condition_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "condition_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "condition_tb: TIMEOUT");
    end

endmodule
