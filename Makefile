SHELL := /bin/bash

XRUN  ?= xrun
GENUS ?= genus

.PHONY: all test sim synth licenses clean

all: test

# Compile, elaborate, and run the self-checking testbench.
test sim:
	@mkdir -p build/sim
	$(XRUN) -64bit -sv -f sim/files.f \
		-top counter_tb \
		-xmlibdirname build/sim/xcelium.d \
		-logfile build/sim/xrun.log

# Technology-independent synthesis. This checks that the RTL elaborates and
# produces a generic gate-level netlist without requiring a standard-cell kit.
synth:
	@mkdir -p build/synth
	cd build/synth && $(GENUS) -batch -files ../../scripts/synth.tcl \
		-log genus.log

licenses:
	@./scripts/check_licenses.sh

clean:
	rm -rf build
