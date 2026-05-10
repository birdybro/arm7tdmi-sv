# Build / lint flow for arm7tdmi-sv. Run from this directory:
#   make lint       # Verilator --lint-only -Wall on the full filelist
#   make clean      # remove obj_dir
# or from the repo root: make -C scripts <target>

VERILATOR ?= verilator
SIM_F     := sim.f

# Verilator lint flags. -Wall enables every warning category; the top module
# is needed so elaboration runs and unused-port / unconnected warnings fire.
# UNUSEDPARAM is suppressed while the package constants have no consumers
# yet (they exist to be referenced by RTL that lands in §3+); re-enable it
# once at least one module uses each constant, then audit anything that
# still warns and either delete it or actually use it.
VFLAGS_LINT := -Wall -Wno-UNUSEDPARAM --top-module arm7tdmis_top

.PHONY: all lint clean help

all: lint

lint:
	$(VERILATOR) --lint-only $(VFLAGS_LINT) -f $(SIM_F)

clean:
	rm -rf obj_dir

help:
	@echo "Targets:"
	@echo "  lint    Verilator --lint-only -Wall on the filelist (default)"
	@echo "  clean   remove obj_dir"
