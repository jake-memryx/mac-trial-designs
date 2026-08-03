SHELL := /bin/bash

XRUN  ?= xrun
GENUS ?= genus

.PHONY: all test sim test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv cln4p-libs synth synth-bf16-mac \
	synth-bf16-mama synth-bf16-multi-mac-tree synth-tree-quarter \
	synth-tree-half synth-tree-full power-tree power-tree-quarter \
	power-tree-half power-tree-full vcd-bf16-mama-gemv \
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

vcd-bf16-multi-mac-tree-gemv: build/vcd/bf16_multi_mac_tree_gemv_p0a0_2667ps.vcd

# One VCD per synthesis point. The testbench clock matches the constrained
# period so the toggle rates Genus reads are at the right frequency.
TREE_VCD_DEPS := rtl/bf16_mac.sv rtl/bf16_mac_tree_core.sv \
	rtl/bf16_multi_mac_tree.sv tb/bf16_multi_mac_tree_gemv_tb.sv

# Arguments: pipeline stages, accumulate stages, period in ps, period in ns.
define tree_vcd_rule
build/vcd/bf16_multi_mac_tree_gemv_p$(1)a$(2)_$(3)ps.vcd: $$(TREE_VCD_DEPS)
	@mkdir -p build/vcd
	$$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_gemv_files.f \
		-top bf16_multi_mac_tree_gemv_tb +dump_vcd -access +r \
		-define PIPELINE_STAGES=$(1) -define ACCUMULATE_STAGES=$(2) \
		+period=$(4) \
		-xmlibdirname build/vcd/xcelium.d.tree_p$(1)a$(2)_$(3) \
		-logfile build/vcd/xrun_tree_gemv_p$(1)a$(2)_$(3).log
endef

# Flat accumulate loop (the original sweep).
$(eval $(call tree_vcd_rule,0,0,2667,2.666667))
$(eval $(call tree_vcd_rule,1,0,1333,1.333333))
$(eval $(call tree_vcd_rule,2,0,667,0.666667))

# Pipelined accumulate loop.
$(eval $(call tree_vcd_rule,2,1,667,0.666667))
$(eval $(call tree_vcd_rule,2,2,667,0.666667))
$(eval $(call tree_vcd_rule,0,2,2667,2.666667))
$(eval $(call tree_vcd_rule,1,2,1333,1.333333))

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

# Tree-MAC synthesis sweep. 1x is the 1.5 GHz target; the slower points reuse
# the same RTL with fewer pipeline stages.
#   quarter: 375 MHz,  0 stages
#   half:    750 MHz,  1 stage
#   full:   1500 MHz,  2 stages
synth-bf16-multi-mac-tree: synth-tree-quarter synth-tree-half synth-tree-full

TREE_POINTS := quarter half full

synth-tree-quarter power-tree-quarter: TREE_PERIOD          := 2.666667
synth-tree-quarter power-tree-quarter: TREE_PIPELINE_STAGES := 0
synth-tree-quarter power-tree-quarter: TREE_PERIOD_PS       := 2667
synth-tree-half    power-tree-half:    TREE_PERIOD          := 1.333333
synth-tree-half    power-tree-half:    TREE_PIPELINE_STAGES := 1
synth-tree-half    power-tree-half:    TREE_PERIOD_PS       := 1333
synth-tree-full    power-tree-full:    TREE_PERIOD          := 0.666667
synth-tree-full    power-tree-full:    TREE_PIPELINE_STAGES := 2
synth-tree-full    power-tree-full:    TREE_PERIOD_PS       := 667

# Accumulate-loop pipeline depth for the sweep. Override on the command line,
# e.g. 'make synth-tree-full TREE_ACC=2'. Results land in a per-depth directory
# so the flat and pipelined variants can be compared side by side.
TREE_ACC ?= 0

TREE_VCD = build/vcd/bf16_multi_mac_tree_gemv_p$(TREE_PIPELINE_STAGES)a$(TREE_ACC)_$(TREE_PERIOD_PS)ps.vcd
TREE_DIR = build/synth_tree_$*_a$(TREE_ACC)

$(addprefix synth-tree-,$(TREE_POINTS)): synth-tree-%: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@mkdir -p $(TREE_DIR)
	cd $(TREE_DIR) && \
		TREE_PERIOD=$(TREE_PERIOD) \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_ACCUMULATE_STAGES=$(TREE_ACC) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/synth_bf16_multi_mac_tree.tcl -log genus.log

# Re-annotate power on an existing netlist. No re-synthesis: activity is read
# after syn_opt and no power-driven optimization is enabled.
power-tree: $(addprefix power-tree-,$(TREE_POINTS))

$(addprefix power-tree-,$(TREE_POINTS)): power-tree-%: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@test -f $(TREE_DIR)/bf16_multi_mac_tree_mapped.sv || \
		{ echo "run 'make synth-tree-$*' first"; exit 1; }
	cd $(TREE_DIR) && \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_ACCUMULATE_STAGES=$(TREE_ACC) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_power_tree.tcl -log genus_power.log

licenses:
	@./scripts/check_licenses.sh

clean:
	rm -rf build
