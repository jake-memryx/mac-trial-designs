SHELL := /bin/bash

XRUN  ?= xrun
GENUS ?= genus

.PHONY: all test sim test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv cln4p-libs synth synth-bf16-mac \
	synth-bf16-mama synth-bf16-multi-mac-tree synth-tree-quarter \
	synth-tree-half synth-tree-full power-tree power-tree-quarter \
	power-tree-half power-tree-full vcd-bf16-mama-gemv \
	vcd-bf16-multi-mac-tree-gemv test-bf16-dual-mac-tree \
	test-bf16-dual-mac-tree-gemv vcd-bf16-dual-mac-tree-gemv \
	synth-bf16-dual-mac-tree synth-dual-quarter synth-dual-half \
	synth-dual-full power-dual power-dual-quarter power-dual-half \
	power-dual-full synth-bf16-dual-mac-tree-pipelined \
	synth-dualp-quarter synth-dualp-half synth-dualp-full power-dualp \
	power-dualp-quarter power-dualp-half power-dualp-full licenses clean

all: test

# Run both self-checking testbenches.
test: test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv test-bf16-dual-mac-tree \
	test-bf16-dual-mac-tree-gemv

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

test-bf16-dual-mac-tree:
	@mkdir -p build/sim_bf16_dual_mac_tree
	$(XRUN) -64bit -sv -f sim/bf16_dual_mac_tree_files.f \
		-top bf16_dual_mac_tree_tb \
		-xmlibdirname build/sim_bf16_dual_mac_tree/xcelium.d \
		-logfile build/sim_bf16_dual_mac_tree/xrun.log

test-bf16-dual-mac-tree-gemv:
	@mkdir -p build/sim_bf16_dual_mac_tree_gemv
	$(XRUN) -64bit -sv -f sim/bf16_dual_mac_tree_gemv_files.f \
		-top bf16_dual_mac_tree_gemv_tb \
		-xmlibdirname build/sim_bf16_dual_mac_tree_gemv/xcelium.d \
		-logfile build/sim_bf16_dual_mac_tree_gemv/xrun.log

# Switching-activity dumps for activity-driven power analysis. The VCD lands
# next to the log so the Genus scripts can find it at ../vcd/<design>.vcd.
vcd-bf16-mama-gemv: build/vcd/bf16_mama_gemv.vcd

build/vcd/bf16_mama_gemv.vcd: rtl/bf16_mac.sv tb/bf16_mama_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_mama_gemv_files.f \
		-top bf16_mama_gemv_tb +dump_vcd -access +r \
		-xmlibdirname build/vcd/xcelium.d.mama \
		-logfile build/vcd/xrun_mama_gemv.log

vcd-bf16-multi-mac-tree-gemv: build/vcd/bf16_multi_mac_tree_gemv_p0_2667ps.vcd

# One VCD per synthesis point. The testbench clock matches the constrained
# period so the toggle rates Genus reads are at the right frequency.
TREE_VCD_DEPS := rtl/bf16_mac.sv rtl/bf16_mac_tree_core.sv \
	rtl/bf16_multi_mac_tree.sv tb/bf16_multi_mac_tree_gemv_tb.sv

define tree_vcd_rule
build/vcd/bf16_multi_mac_tree_gemv_p$(1)_$(2)ps.vcd: $$(TREE_VCD_DEPS)
	@mkdir -p build/vcd
	$$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_gemv_files.f \
		-top bf16_multi_mac_tree_gemv_tb +dump_vcd -access +r \
		-define PIPELINE_STAGES=$(1) +period=$(3) \
		-xmlibdirname build/vcd/xcelium.d.tree_p$(1)_$(2) \
		-logfile build/vcd/xrun_tree_gemv_p$(1)_$(2).log
endef

$(eval $(call tree_vcd_rule,0,2667,2.666667))
$(eval $(call tree_vcd_rule,1,1333,1.333333))
$(eval $(call tree_vcd_rule,2,667,0.666667))

vcd-bf16-dual-mac-tree-gemv: build/vcd/bf16_dual_mac_tree_gemv_p0_2667ps.vcd

DUAL_VCD_DEPS := rtl/bf16_mac.sv rtl/bf16_mac_tree_core.sv \
	rtl/bf16_dual_mac_tree.sv tb/bf16_dual_mac_tree_gemv_tb.sv

# Arguments: pipeline stages, accumulate stages, period in ps, period in ns.
define dual_vcd_rule
build/vcd/bf16_dual_mac_tree_gemv_p$(1)a$(2)_$(3)ps.vcd: $$(DUAL_VCD_DEPS)
	@mkdir -p build/vcd
	$$(XRUN) -64bit -sv -f sim/bf16_dual_mac_tree_gemv_files.f \
		-top bf16_dual_mac_tree_gemv_tb +dump_vcd -access +r \
		-define PIPELINE_STAGES=$(1) -define LANE_CYCLES=2 \
		-define ACCUMULATE_STAGES=$(2) +period=$(4) \
		-xmlibdirname build/vcd/xcelium.d.dual_p$(1)a$(2)_$(3) \
		-logfile build/vcd/xrun_dual_gemv_p$(1)a$(2)_$(3).log
endef

# Single-cycle accumulate loop (original dual-lane experiment).
$(eval $(call dual_vcd_rule,0,0,2667,2.666667))
$(eval $(call dual_vcd_rule,0,0,1333,1.333333))
$(eval $(call dual_vcd_rule,1,0,667,0.666667))

# Pipelined accumulate loop (registered bank read).
$(eval $(call dual_vcd_rule,0,1,2667,2.666667))
$(eval $(call dual_vcd_rule,0,1,1333,1.333333))
$(eval $(call dual_vcd_rule,1,1,667,0.666667))

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

TREE_VCD = build/vcd/bf16_multi_mac_tree_gemv_p$(TREE_PIPELINE_STAGES)_$(TREE_PERIOD_PS)ps.vcd

$(addprefix synth-tree-,$(TREE_POINTS)): synth-tree-%: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@mkdir -p build/synth_tree_$*
	cd build/synth_tree_$* && \
		TREE_PERIOD=$(TREE_PERIOD) \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		$(GENUS) -batch \
		-files ../../scripts/synth_bf16_multi_mac_tree.tcl -log genus.log

# Re-annotate power on an existing netlist. No re-synthesis: activity is read
# after syn_opt and no power-driven optimization is enabled.
power-tree: $(addprefix power-tree-,$(TREE_POINTS))

$(addprefix power-tree-,$(TREE_POINTS)): power-tree-%: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@test -f build/synth_tree_$*/bf16_multi_mac_tree_mapped.sv || \
		{ echo "run 'make synth-tree-$*' first"; exit 1; }
	cd build/synth_tree_$* && \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_power_tree.tcl -log genus_power.log

# Dual-lane tree-MAC synthesis sweep. Each lane is a 2-cycle path, so a point
# needs fewer pipeline stages than the single-tree design at the same period.
#   quarter: 375 MHz,  0 stages (tree + accumulate in 5.333 ns)
#   half:    750 MHz,  0 stages (tree + accumulate in 2.667 ns)
#   full:   1500 MHz,  1 stage  (tree in 1.333 ns, accumulate in 1.333 ns)
synth-bf16-dual-mac-tree: synth-dual-quarter synth-dual-half synth-dual-full

# synth-dualp-* repeats the sweep with the accumulate read-modify-write split
# into a registered bank read plus the add and write-back, which turns the one
# long single-cycle accumulate loop into two short ones at no latency cost.
synth-bf16-dual-mac-tree-pipelined: synth-dualp-quarter synth-dualp-half \
	synth-dualp-full

DUAL_POINTS      := quarter half full
DUAL_LANE_CYCLES := 2

# Point definitions are shared by both families; only the accumulate depth and
# the build directory differ.
DUAL_ALL_TARGETS = $(addprefix synth-dual-,$(DUAL_POINTS)) \
	$(addprefix power-dual-,$(DUAL_POINTS)) \
	$(addprefix synth-dualp-,$(DUAL_POINTS)) \
	$(addprefix power-dualp-,$(DUAL_POINTS))

$(filter %-quarter,$(DUAL_ALL_TARGETS)): DUAL_PERIOD          := 2.666667
$(filter %-quarter,$(DUAL_ALL_TARGETS)): DUAL_PIPELINE_STAGES := 0
$(filter %-quarter,$(DUAL_ALL_TARGETS)): DUAL_PERIOD_PS       := 2667
$(filter %-half,$(DUAL_ALL_TARGETS)):    DUAL_PERIOD          := 1.333333
$(filter %-half,$(DUAL_ALL_TARGETS)):    DUAL_PIPELINE_STAGES := 0
$(filter %-half,$(DUAL_ALL_TARGETS)):    DUAL_PERIOD_PS       := 1333
$(filter %-full,$(DUAL_ALL_TARGETS)):    DUAL_PERIOD          := 0.666667
$(filter %-full,$(DUAL_ALL_TARGETS)):    DUAL_PIPELINE_STAGES := 1
$(filter %-full,$(DUAL_ALL_TARGETS)):    DUAL_PERIOD_PS       := 667

$(addprefix synth-dual-,$(DUAL_POINTS)):  DUAL_ACCUMULATE_STAGES := 0
$(addprefix power-dual-,$(DUAL_POINTS)):  DUAL_ACCUMULATE_STAGES := 0
$(addprefix synth-dualp-,$(DUAL_POINTS)): DUAL_ACCUMULATE_STAGES := 1
$(addprefix power-dualp-,$(DUAL_POINTS)): DUAL_ACCUMULATE_STAGES := 1

DUAL_VCD = build/vcd/bf16_dual_mac_tree_gemv_p$(DUAL_PIPELINE_STAGES)a$(DUAL_ACCUMULATE_STAGES)_$(DUAL_PERIOD_PS)ps.vcd

$(addprefix synth-dual-,$(DUAL_POINTS)): synth-dual-%: cln4p-libs
	$(MAKE) $(DUAL_VCD)
	@mkdir -p build/synth_dual_$*
	cd build/synth_dual_$* && \
		DUAL_PERIOD=$(DUAL_PERIOD) \
		DUAL_PIPELINE_STAGES=$(DUAL_PIPELINE_STAGES) \
		DUAL_LANE_CYCLES=$(DUAL_LANE_CYCLES) \
		DUAL_ACCUMULATE_STAGES=$(DUAL_ACCUMULATE_STAGES) \
		DUAL_VCD=../../$(DUAL_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/synth_bf16_dual_mac_tree.tcl -log genus.log

$(addprefix synth-dualp-,$(DUAL_POINTS)): synth-dualp-%: cln4p-libs
	$(MAKE) $(DUAL_VCD)
	@mkdir -p build/synth_dualp_$*
	cd build/synth_dualp_$* && \
		DUAL_PERIOD=$(DUAL_PERIOD) \
		DUAL_PIPELINE_STAGES=$(DUAL_PIPELINE_STAGES) \
		DUAL_LANE_CYCLES=$(DUAL_LANE_CYCLES) \
		DUAL_ACCUMULATE_STAGES=$(DUAL_ACCUMULATE_STAGES) \
		DUAL_VCD=../../$(DUAL_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/synth_bf16_dual_mac_tree.tcl -log genus.log

power-dual: $(addprefix power-dual-,$(DUAL_POINTS))
power-dualp: $(addprefix power-dualp-,$(DUAL_POINTS))

$(addprefix power-dual-,$(DUAL_POINTS)): power-dual-%: cln4p-libs
	$(MAKE) $(DUAL_VCD)
	@test -f build/synth_dual_$*/bf16_dual_mac_tree_mapped.sv || \
		{ echo "run 'make synth-dual-$*' first"; exit 1; }
	cd build/synth_dual_$* && \
		DUAL_PIPELINE_STAGES=$(DUAL_PIPELINE_STAGES) \
		DUAL_LANE_CYCLES=$(DUAL_LANE_CYCLES) \
		DUAL_ACCUMULATE_STAGES=$(DUAL_ACCUMULATE_STAGES) \
		DUAL_VCD=../../$(DUAL_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_power_dual.tcl -log genus_power.log

$(addprefix power-dualp-,$(DUAL_POINTS)): power-dualp-%: cln4p-libs
	$(MAKE) $(DUAL_VCD)
	@test -f build/synth_dualp_$*/bf16_dual_mac_tree_mapped.sv || \
		{ echo "run 'make synth-dualp-$*' first"; exit 1; }
	cd build/synth_dualp_$* && \
		DUAL_PIPELINE_STAGES=$(DUAL_PIPELINE_STAGES) \
		DUAL_LANE_CYCLES=$(DUAL_LANE_CYCLES) \
		DUAL_ACCUMULATE_STAGES=$(DUAL_ACCUMULATE_STAGES) \
		DUAL_VCD=../../$(DUAL_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_power_dual.tcl -log genus_power.log

licenses:
	@./scripts/check_licenses.sh

clean:
	rm -rf build
