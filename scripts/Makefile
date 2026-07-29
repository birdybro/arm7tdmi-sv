# Build / lint / sim flow for arm7tdmi-sv. Run from this directory:
#   make lint            # Verilator --lint-only -Wall on the RTL filelist
#   make lint-tb         # same, but elaborate the integration testbench top
#   make sim             # build the integration testbench binary
#   make run             # build and run; produces cycle.csv + waves.fst
#   make wave            # open the FST in GTKWave
#   make unit-regfile    # build + run the regfile unit test
#   make unit-psr        # build + run the PSR unit test
#   make unit            # run every unit test
#   make clean           # remove obj_dir + simulation artifacts
# or from the repo root: make -C scripts <target>

VERILATOR ?= verilator
GTKWAVE   ?= gtkwave
PYTHON    ?= python3
QUARTUS_MAP ?= quartus_map
QUARTUS_SH  ?= quartus_sh

SIM_F     := sim.f
TB_F      := tb.f
FPGA_F    := ../fpga/arm7tdmi_mister.f
FPGA_EXAMPLE := ../fpga/example/arm7tdmi_mister_example_top.sv

TOP_RTL   := arm7tdmis_top
TOP_TB    := arm7tdmis_tb_top

# Verilator flags. -Wall enables every warning category. UNUSEDPARAM is
# suppressed while package constants are being introduced ahead of their
# consumers; re-enable once each constant has at least one user.
VFLAGS_COMMON := -Wall -Wno-UNUSEDPARAM --assert --timescale 1ns/1ps
VFLAGS_LINT   := $(VFLAGS_COMMON)
VFLAGS_BUILD  := $(VFLAGS_COMMON) --binary --trace-fst -j 0

OBJ_DIR        := obj_dir
TB_BIN         := $(OBJ_DIR)/V$(TOP_TB)
RUN_ARTIFACTS  := cycle.csv waves.fst

UNIT_TESTS := regfile psr psr_policy reset_sync shifter alu multiplier condition decoder thumb_decoder jtag_tap jtag_idcode_config sync_debug_port ice_rt ice_watchpoint dcc

INTEG_TESTS := umull umlal multiply_matrix cp15_undef cp14_decode cp14_dcc cp14_r15 cp_pipeline_follow cp_cdp_protocol cp_reg_transfer cp_reg_r15 cp_ldc_stc cp_ldc_stc_abort cp_erratum14 cp_erratum15 cp_busy_interrupt cp_busy_dbgrq cpntrans debug_status debug_control_sync debug_reserved_regs debug_software_breakpoint debug_watchpoint_completion debug_watchpoint_priority debug_breakpoint_pabt debug_breakpoint_interrupt debug_dbgrq_exception debug_pc_modify_dbgrq debug_breakpoint_flush debug_breakpoint_execute debug_external_break debug_inject_handshake debug_inject_matrix debug_dbgen_gating debug_dbgen_sources debug_entry_cause debug_system_speed debug_register_scan debug_pc_capture debug_pc_resume debug_monitor_mode mister_wrapper mister_cdc_reset mister_profiles abort_inactive abort_clken endian_data endian_thumb translated_ls cond_suppress reset_clken fetch_sequence bus_burst abort irq fiq exception_priority dabt_fiq thumb_exception_lr ldm_pc pabt pabt_pipeline ldm_abort ldm_abort_base_list stm_abort stm_base_list ls_abort_modes swp_read_abort cycles swi undef thumb bx_interwork swpb_data flags_preserve psr_policy pc_operands pc_write_alignment mull_flags

INTEG_COMMON_SRCS := \
	../tb/integration/arm7tdmis_jtag_tb_pkg.sv \
	../tb/integration/arm7tdmis_memory.sv \
	../tb/integration/arm7tdmis_assertions.sv \
	../tb/integration/arm7tdmis_test_fixture.sv

.PHONY: all lint lint-mister lint-example lint-tb \
        quartus-analysis quartus-compile \
        quartus-conformance-analysis quartus-conformance-compile \
        sim run wave clean help regress regress-quick \
        harness-unit harness-self-test \
        $(addprefix unit-, $(UNIT_TESTS)) unit \
        $(addprefix integ-, $(INTEG_TESTS)) integ

all: lint

lint:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) --top-module $(TOP_RTL) -f $(SIM_F)

lint-mister:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) \
	    --top-module arm7tdmi_mister -f $(SIM_F)

lint-example:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) \
	    --top-module arm7tdmi_mister_example_top \
	    -f $(FPGA_F) $(FPGA_EXAMPLE)

# Exercise the checked QSF/QIP and synthesize/elaborate every public-wrapper
# dependency with the MiSTer-mandated Quartus 17 SystemVerilog frontend.
quartus-analysis:
	cd ../fpga && $(QUARTUS_MAP) --analysis_and_elaboration \
	    --read_settings_files=on --write_settings_files=off \
	    arm7tdmi_mister -c arm7tdmi_mister

# Complete selected-device flow: synthesis, fit, TimeQuest, and assembly.
quartus-compile:
	cd ../fpga && $(QUARTUS_SH) --flow compile arm7tdmi_mister
	PYTHONPATH=. $(PYTHON) quartus_report_check.py ../fpga/output_files

quartus-conformance-analysis:
	cd ../fpga && $(QUARTUS_MAP) --analysis_and_elaboration \
	    --read_settings_files=on --write_settings_files=off \
	    arm7tdmis_conformance -c arm7tdmis_conformance

quartus-conformance-compile:
	cd ../fpga && $(QUARTUS_SH) --flow compile arm7tdmis_conformance
	PYTHONPATH=. $(PYTHON) quartus_report_check.py \
	    --project arm7tdmis_conformance \
	    --top arm7tdmis_top \
	    --max-alm 7500 \
	    --max-register 6000 \
	    --max-dsp 8 \
	    --max-memory-bit 0 \
	    ../fpga/conformance_output_files

lint-tb:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) --top-module $(TOP_TB) -f $(SIM_F) -f $(TB_F)

RTL_SRCS := $(shell find ../rtl -name '*.sv')
TB_SRCS  := $(shell find ../tb/integration -name '*.sv')

sim: $(TB_BIN)

$(TB_BIN): $(SIM_F) $(TB_F) $(RTL_SRCS) $(TB_SRCS)
	$(VERILATOR) $(VFLAGS_BUILD) --top-module $(TOP_TB) -f $(SIM_F) -f $(TB_F)

run: sim
	./$(TB_BIN)

wave: run
	$(GTKWAVE) waves.fst &

# Per-unit-test recipe: each test has its top module named `<name>_tb` in
# tb/unit/<name>_tb.sv, builds into obj_dir/<name>/V<name>_tb, and runs
# from that path. Generated explicitly per test (a `unit-%` pattern rule
# doesn't fire reliably for phony targets).
define UNIT_RULE
unit-$(1):
	mkdir -p $$(OBJ_DIR)
	$$(VERILATOR) $$(VFLAGS_BUILD) --top-module $(1)_tb \
	    --Mdir $$(OBJ_DIR)/$(1) -f $$(SIM_F) ../tb/unit/$(1)_tb.sv
	./$$(OBJ_DIR)/$(1)/V$(1)_tb
endef

$(foreach t,$(UNIT_TESTS),$(eval $(call UNIT_RULE,$(t))))

unit: $(addprefix unit-, $(UNIT_TESTS))

# Per-integration-test recipe. Each test has its top module named
# `arm7tdmis_<name>_tb` in tb/integration/arm7tdmis_<name>_tb.sv and pulls
# the shared integration TB infrastructure (memory model, cycle logger,
# assertions) via tb.f.
define INTEG_RULE
integ-$(1):
	mkdir -p $$(OBJ_DIR)
	$$(VERILATOR) $$(VFLAGS_BUILD) -Wno-SYNCASYNCNET -Wno-UNOPTFLAT \
	    --top-module arm7tdmis_$(1)_tb \
	    --Mdir $$(OBJ_DIR)/integ_$(1) -f $$(SIM_F) \
	    $$(INTEG_COMMON_SRCS) \
	    ../tb/integration/arm7tdmis_$(1)_tb.sv
	./$$(OBJ_DIR)/integ_$(1)/Varm7tdmis_$(1)_tb
endef

$(foreach t,$(INTEG_TESTS),$(eval $(call INTEG_RULE,$(t))))

integ: $(addprefix integ-, $(INTEG_TESTS))

# Release-facing entry point. The runner always starts clean, records the
# complete source/tool/variant/seed manifest, executes every phase separately,
# and atomically updates a machine-readable JSON result with per-phase logs.
regress:
	PYTHONPATH=. $(PYTHON) regression_harness.py \
	    --unit-tests "$(UNIT_TESTS)" \
	    --integration-tests "$(INTEG_TESTS)"

regress-quick:
	PYTHONPATH=. $(PYTHON) regression_harness.py --quick \
	    --unit-tests "$(UNIT_TESTS)" \
	    --integration-tests "$(INTEG_TESTS)"

harness-unit:
	PYTHONPATH=. $(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

harness-self-test:
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) $(VFLAGS_BUILD) --top-module expected_failure_tb \
	    --Mdir $(OBJ_DIR)/harness_expected_failure \
	    ../tb/harness/expected_failure_tb.sv
	@if ./$(OBJ_DIR)/harness_expected_failure/Vexpected_failure_tb; then \
	    echo "[harness-self-test] FAIL: expected simulator failure returned zero"; \
	    exit 1; \
	else \
	    echo "[harness-self-test] PASS: simulator failure propagated nonzero"; \
	fi

clean:
	rm -rf $(OBJ_DIR) $(RUN_ARTIFACTS)

help:
	@echo "Targets:"
	@echo "  lint         Verilator --lint-only on RTL only (default)"
	@echo "  lint-mister  Verilator --lint-only on the canonical FPGA wrapper"
	@echo "  lint-example Verilator --lint-only on the portable FPGA example"
	@echo "  quartus-analysis Quartus analysis/elaboration of the FPGA package"
	@echo "  quartus-compile Full Quartus synth/fit/timing/assembly flow"
	@echo "  quartus-conformance-analysis Quartus analysis of the raw/full profile"
	@echo "  quartus-conformance-compile Full Quartus flow for the raw/full profile"
	@echo "  lint-tb      Verilator --lint-only including the integration TB"
	@echo "  sim          build the integration testbench binary"
	@echo "  run          build and run; emits cycle.csv + waves.fst"
	@echo "  wave         open waves.fst in GTKWave (requires \$$DISPLAY)"
	@echo "  unit-<name>  build + run a unit test (e.g. unit-regfile)"
	@echo "  unit         run every unit test ($(UNIT_TESTS))"
	@echo "  integ        run every directed integration test ($(INTEG_TESTS))"
	@echo "  regress      clean full run with JSON metadata/results under reports/"
	@echo "  regress-quick lint/harness plus one unit/integration test and smoke"
	@echo "  harness-unit unit-test the machine-readable regression harness"
	@echo "  harness-self-test prove an intentional simulator failure stays fatal"
	@echo "  clean        remove obj_dir + run artifacts"
