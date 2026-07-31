SHELL := /bin/bash

XRUN  ?= xrun
GENUS ?= genus

.PHONY: all test sim test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv cln4p-libs synth synth-bf16-mac \
	synth-bf16-mama synth-bf16-multi-mac-tree vcd-bf16-mama-gemv \
	vcd-bf16-multi-mac-tree-gemv licenses clean

all: test

# Run both self-checking testbenches.
test: test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv

sim test-counter:
	@mkdir -p build/sim
	$(XRUN) -64bit -sv -f sim/files.f \
		-top counter_tb \
		-xmlibdirname build/sim/xcelium.d \
		-logfile build/sim/xrun.log

test-bf16-mac:
	@mkdir -p build/sim_bf16_mac
	$(XRUN) -64bit -sv -f sim/bf16_mac_files.f \
		-top bf16_mac_tb \
		-xmlibdirname build/sim_bf16_mac/xcelium.d \
		-logfile build/sim_bf16_mac/xrun.log

test-bf16-mam:
	@mkdir -p build/sim_bf16_mam
	$(XRUN) -64bit -sv -f sim/bf16_mam_files.f \
		-top bf16_mam_tb \
		-xmlibdirname build/sim_bf16_mam/xcelium.d \
		-logfile build/sim_bf16_mam/xrun.log

test-bf16-mama:
	@mkdir -p build/sim_bf16_mama
	$(XRUN) -64bit -sv -f sim/bf16_mama_files.f \
		-top bf16_mama_tb \
		-xmlibdirname build/sim_bf16_mama/xcelium.d \
		-logfile build/sim_bf16_mama/xrun.log

test-bf16-multi-mac-tree:
	@mkdir -p build/sim_bf16_multi_mac_tree
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_files.f \
		-top bf16_multi_mac_tree_tb \
		-xmlibdirname build/sim_bf16_multi_mac_tree/xcelium.d \
		-logfile build/sim_bf16_multi_mac_tree/xrun.log

test-bf16-mama-gemv:
	@mkdir -p build/sim_bf16_mama_gemv
	$(XRUN) -64bit -sv -f sim/bf16_mama_gemv_files.f \
		-top bf16_mama_gemv_tb \
		-xmlibdirname build/sim_bf16_mama_gemv/xcelium.d \
		-logfile build/sim_bf16_mama_gemv/xrun.log

test-bf16-multi-mac-tree-gemv:
	@mkdir -p build/sim_bf16_multi_mac_tree_gemv
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_gemv_files.f \
		-top bf16_multi_mac_tree_gemv_tb \
		-xmlibdirname build/sim_bf16_multi_mac_tree_gemv/xcelium.d \
		-logfile build/sim_bf16_multi_mac_tree_gemv/xrun.log

# Switching-activity dumps for activity-driven power analysis. The VCD lands
# next to the log so the Genus scripts can find it at ../vcd/<design>.vcd.
vcd-bf16-mama-gemv: build/vcd/bf16_mama_gemv.vcd

build/vcd/bf16_mama_gemv.vcd: rtl/bf16_mac.sv tb/bf16_mama_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_mama_gemv_files.f \
		-top bf16_mama_gemv_tb +dump_vcd -access +r \
		-xmlibdirname build/vcd/xcelium.d.mama \
		-logfile build/vcd/xrun_mama_gemv.log

vcd-bf16-multi-mac-tree-gemv: build/vcd/bf16_multi_mac_tree_gemv.vcd

build/vcd/bf16_multi_mac_tree_gemv.vcd: rtl/bf16_mac.sv \
		rtl/bf16_multi_mac_tree.sv tb/bf16_multi_mac_tree_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_gemv_files.f \
		-top bf16_multi_mac_tree_gemv_tb +dump_vcd -access +r \
		-xmlibdirname build/vcd/xcelium.d.tree \
		-logfile build/vcd/xrun_multi_mac_tree_gemv.log

cln4p-libs:
	@./scripts/prepare_cln4p_libs.sh build/cln4p_libs

synth: cln4p-libs
	@mkdir -p build/synth
	cd build/synth && $(GENUS) -batch -files ../../scripts/synth.tcl \
		-log genus.log

synth-bf16-mac: cln4p-libs
	@mkdir -p build/synth_bf16_mac
	cd build/synth_bf16_mac && $(GENUS) -batch \
		-files ../../scripts/synth_bf16_mac.tcl -log genus.log

synth-bf16-mama: cln4p-libs vcd-bf16-mama-gemv
	@mkdir -p build/synth_bf16_mama
	cd build/synth_bf16_mama && $(GENUS) -batch \
		-files ../../scripts/synth_bf16_mama.tcl -log genus.log

synth-bf16-multi-mac-tree: cln4p-libs vcd-bf16-multi-mac-tree-gemv
	@mkdir -p build/synth_bf16_multi_mac_tree
	cd build/synth_bf16_multi_mac_tree && $(GENUS) -batch \
		-files ../../scripts/synth_bf16_multi_mac_tree.tcl -log genus.log

licenses:
	@./scripts/check_licenses.sh

clean:
	rm -rf build
