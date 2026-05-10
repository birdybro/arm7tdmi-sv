# Build / lint / sim flow for arm7tdmi-sv. Run from this directory:
#   make lint       # Verilator --lint-only -Wall on the RTL filelist
#   make lint-tb    # same, but elaborate the testbench top
#   make sim        # build the testbench binary (Verilator --binary)
#   make run        # build and run; produces cycle.csv + waves.fst
#   make wave       # open the FST in GTKWave
#   make clean      # remove obj_dir + simulation artifacts
# or from the repo root: make -C scripts <target>

VERILATOR ?= verilator
GTKWAVE   ?= gtkwave

SIM_F     := sim.f
TB_F      := tb.f

TOP_RTL   := arm7tdmis_top
TOP_TB    := arm7tdmis_tb_top

# Verilator lint flags. -Wall enables every warning category. UNUSEDPARAM is
# suppressed while package constants have no consumers yet (they exist to be
# referenced by RTL that lands in §3+); re-enable once consumers exist and
# audit anything that still warns.
VFLAGS_COMMON := -Wall -Wno-UNUSEDPARAM --timescale 1ns/1ps
VFLAGS_LINT   := $(VFLAGS_COMMON)
VFLAGS_BUILD  := $(VFLAGS_COMMON) --binary --trace-fst -j 0

OBJ_DIR     := obj_dir
TB_BIN      := $(OBJ_DIR)/V$(TOP_TB)
RUN_ARTIFACTS := cycle.csv waves.fst

.PHONY: all lint lint-tb sim run wave clean help

all: lint

lint:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) --top-module $(TOP_RTL) -f $(SIM_F)

lint-tb:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) --top-module $(TOP_TB) -f $(SIM_F) -f $(TB_F)

sim: $(TB_BIN)

$(TB_BIN): $(SIM_F) $(TB_F)
	$(VERILATOR) $(VFLAGS_BUILD) --top-module $(TOP_TB) -f $(SIM_F) -f $(TB_F)

run: sim
	./$(TB_BIN)

wave: run
	$(GTKWAVE) waves.fst &

clean:
	rm -rf $(OBJ_DIR) $(RUN_ARTIFACTS)

help:
	@echo "Targets:"
	@echo "  lint     Verilator --lint-only on RTL only (default)"
	@echo "  lint-tb  Verilator --lint-only including the testbench"
	@echo "  sim      build the testbench binary"
	@echo "  run      build and run; emits cycle.csv + waves.fst"
	@echo "  wave     open waves.fst in GTKWave (requires \$$DISPLAY)"
	@echo "  clean    remove obj_dir + run artifacts"
