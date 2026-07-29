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

SIM_F     := sim.f
TB_F      := tb.f

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

UNIT_TESTS := regfile psr reset_sync shifter alu multiplier condition decoder thumb_decoder jtag_tap jtag_idcode_config ice_rt ice_watchpoint dcc

INTEG_TESTS := umull umlal cp15_undef cp14_decode cp14_dcc cp14_r15 cp_pipeline_follow cp_cdp_protocol cp_reg_transfer cp_reg_r15 cp_ldc_stc cp_ldc_stc_abort cp_erratum14 cp_erratum15 cp_busy_interrupt cp_busy_dbgrq cpntrans debug_status debug_watchpoint_completion debug_breakpoint_flush debug_breakpoint_execute debug_inject_handshake debug_dbgen_gating debug_entry_cause debug_system_speed abort_inactive abort_clken endian_data endian_thumb translated_ls cond_suppress reset_clken fetch_sequence bus_burst vector_catch abort irq fiq exception_priority dabt_fiq thumb_exception_lr ldm_pc pabt pabt_pipeline ldm_abort ldm_abort_base_list stm_abort stm_base_list ls_abort_modes swp_read_abort cycles swi undef thumb bx_interwork swpb_data flags_preserve mull_flags

INTEG_COMMON_SRCS := \
	../tb/integration/arm7tdmis_jtag_tb_pkg.sv \
	../tb/integration/arm7tdmis_memory.sv \
	../tb/integration/arm7tdmis_assertions.sv \
	../tb/integration/arm7tdmis_test_fixture.sv

.PHONY: all lint lint-tb sim run wave clean help regress \
        $(addprefix unit-, $(UNIT_TESTS)) unit \
        $(addprefix integ-, $(INTEG_TESTS)) integ

all: lint

lint:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) --top-module $(TOP_RTL) -f $(SIM_F)

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

# Release-facing entry point. Recursive invocations make the ordering explicit:
# a regression always starts clean, then lints RTL/TB sources before executing
# every unit, directed integration, and smoke test.
regress:
	$(MAKE) clean
	$(MAKE) lint
	$(MAKE) lint-tb
	$(MAKE) unit
	$(MAKE) integ
	$(MAKE) run

clean:
	rm -rf $(OBJ_DIR) $(RUN_ARTIFACTS)

help:
	@echo "Targets:"
	@echo "  lint         Verilator --lint-only on RTL only (default)"
	@echo "  lint-tb      Verilator --lint-only including the integration TB"
	@echo "  sim          build the integration testbench binary"
	@echo "  run          build and run; emits cycle.csv + waves.fst"
	@echo "  wave         open waves.fst in GTKWave (requires \$$DISPLAY)"
	@echo "  unit-<name>  build + run a unit test (e.g. unit-regfile)"
	@echo "  unit         run every unit test ($(UNIT_TESTS))"
	@echo "  integ        run every directed integration test ($(INTEG_TESTS))"
	@echo "  regress      clean, lint, and run every unit/integration/smoke test"
	@echo "  clean        remove obj_dir + run artifacts"
