SHELL := /bin/bash

XRUN  ?= xrun
GENUS ?= genus

.PHONY: all test sim test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv test-fp8-mac \
	test-bf16-multi-mac-tree-mode test-bf16-multi-mac-tree-fp8-gemv \
	cln4p-libs synth synth-bf16-mac \
	synth-bf16-mama synth-bf16-multi-mac-tree power-bf16-multi-mac-tree \
	breakdown-bf16-multi-mac-tree vcd-bf16-mama-gemv \
	vcd-bf16-multi-mac-tree-gemv licenses clean

all: test

# Run both self-checking testbenches.
test: test-counter test-bf16-mac test-bf16-mam test-bf16-mama \
	test-bf16-multi-mac-tree test-bf16-mama-gemv \
	test-bf16-multi-mac-tree-gemv test-fp8-mac \
	test-bf16-multi-mac-tree-mode test-bf16-multi-mac-tree-fp8-gemv

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

# Exhaustive check of the dual-format multiplier: all 65536 E4M3 input pairs
# plus BF16 bit-equivalence against the original bf16_multiplier.
test-fp8-mac:
	@mkdir -p build/sim_fp8_mac
	$(XRUN) -64bit -sv -f sim/fp8_mac_files.f \
		-top fp8_mac_tb \
		-xmlibdirname build/sim_fp8_mac/xcelium.d \
		-logfile build/sim_fp8_mac/xrun.log

test-bf16-multi-mac-tree-mode:
	@mkdir -p build/sim_mode
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_mode_files.f \
		-top bf16_multi_mac_tree_mode_tb \
		-xmlibdirname build/sim_mode/xcelium.d \
		-logfile build/sim_mode/xrun.log

test-bf16-multi-mac-tree-fp8-gemv:
	@mkdir -p build/sim_fp8_gemv
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_fp8_gemv_files.f \
		-top bf16_multi_mac_tree_fp8_gemv_tb \
		-xmlibdirname build/sim_fp8_gemv/xcelium.d \
		-logfile build/sim_fp8_gemv/xrun.log

# Switching-activity dumps for activity-driven power analysis. The VCD lands
# next to the log so the Genus scripts can find it at ../vcd/<design>.vcd.
vcd-bf16-mama-gemv: build/vcd/bf16_mama_gemv.vcd

build/vcd/bf16_mama_gemv.vcd: rtl/bf16_mac.sv tb/bf16_mama_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_mama_gemv_files.f \
		-top bf16_mama_gemv_tb +dump_vcd -access +r \
		-xmlibdirname build/vcd/xcelium.d.mama \
		-logfile build/vcd/xrun_mama_gemv.log

vcd-bf16-multi-mac-tree-gemv: build/vcd/bf16_multi_mac_tree_gemv_p2a2_667ps.vcd

# The testbench clock matches the constrained period so the toggle rates Genus
# reads are at the right frequency.
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

# Pipelined accumulate loop (the shipping configuration) and the flat
# accumulate loop kept as a reference build.
$(eval $(call tree_vcd_rule,2,2,667,0.666667))
$(eval $(call tree_vcd_rule,2,0,667,0.666667))

# Dual-format build. Two dumps: BF16 mode and E4M3 mode, so power can be
# reported per mode from the same netlist.
DUAL_VCD_DEPS := rtl/bf16_mac.sv rtl/fp8_mac.sv rtl/bf16_mac_tree_core.sv \
	rtl/bf16_multi_mac_tree.sv

build/vcd/bf16_multi_mac_tree_gemv_dual_p2a2_667ps.vcd: $(DUAL_VCD_DEPS) \
		tb/bf16_multi_mac_tree_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_gemv_files.f \
		-top bf16_multi_mac_tree_gemv_tb +dump_vcd -access +r \
		-define PIPELINE_STAGES=2 -define ACCUMULATE_STAGES=2 \
		-define FP8_ENABLE=1 +period=0.666667 \
		-xmlibdirname build/vcd/xcelium.d.tree_dual_p2a2_667 \
		-logfile build/vcd/xrun_tree_gemv_dual_p2a2_667.log

build/vcd/bf16_multi_mac_tree_fp8_gemv_p2a2_667ps.vcd: $(DUAL_VCD_DEPS) \
		tb/bf16_multi_mac_tree_fp8_gemv_tb.sv
	@mkdir -p build/vcd
	$(XRUN) -64bit -sv -f sim/bf16_multi_mac_tree_fp8_gemv_files.f \
		-top bf16_multi_mac_tree_fp8_gemv_tb +dump_vcd -access +r \
		-define PIPELINE_STAGES=2 -define ACCUMULATE_STAGES=2 \
		+period=0.666667 \
		-xmlibdirname build/vcd/xcelium.d.tree_fp8_p2a2_667 \
		-logfile build/vcd/xrun_tree_fp8_gemv_p2a2_667.log

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

# Tree-MAC synthesis at the 1.5 GHz target.
#
# TREE_ACC selects the accumulate-loop pipeline depth. 2 is the shipping
# configuration; build the flat reference with 'TREE_ACC=0'. Results land in a
# per-depth directory so the two can be compared side by side.
TREE_PERIOD          := 0.666667
TREE_PIPELINE_STAGES := 2
TREE_PERIOD_PS       := 667
TREE_ACC             ?= 2

# TREE_FP8=1 builds the dual-format BF16/E4M3 variant. TREE_MODE then selects
# which activity dump drives the power report: fp8 (16 MACs/cycle) or bf16.
TREE_FP8             ?= 0
TREE_MODE            ?= fp8

ifeq ($(TREE_FP8),1)
TREE_DIR       = build/synth_tree_a$(TREE_ACC)_fp8
ifeq ($(TREE_MODE),bf16)
TREE_VCD       = build/vcd/bf16_multi_mac_tree_gemv_dual_p$(TREE_PIPELINE_STAGES)a$(TREE_ACC)_$(TREE_PERIOD_PS)ps.vcd
TREE_VCD_SCOPE = bf16_multi_mac_tree_gemv_tb/dut
else
TREE_VCD       = build/vcd/bf16_multi_mac_tree_fp8_gemv_p$(TREE_PIPELINE_STAGES)a$(TREE_ACC)_$(TREE_PERIOD_PS)ps.vcd
TREE_VCD_SCOPE = bf16_multi_mac_tree_fp8_gemv_tb/dut
endif
else
TREE_DIR       = build/synth_tree_a$(TREE_ACC)
TREE_VCD       = build/vcd/bf16_multi_mac_tree_gemv_p$(TREE_PIPELINE_STAGES)a$(TREE_ACC)_$(TREE_PERIOD_PS)ps.vcd
TREE_VCD_SCOPE = bf16_multi_mac_tree_gemv_tb/dut
endif

synth-bf16-multi-mac-tree: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@mkdir -p $(TREE_DIR)
	cd $(TREE_DIR) && \
		TREE_PERIOD=$(TREE_PERIOD) \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_ACCUMULATE_STAGES=$(TREE_ACC) \
		TREE_FP8=$(TREE_FP8) \
		TREE_VCD_SCOPE=$(TREE_VCD_SCOPE) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/synth_bf16_multi_mac_tree.tcl -log genus.log

# Re-annotate power on an existing netlist. No re-synthesis: activity is read
# after syn_opt and no power-driven optimization is enabled.
power-bf16-multi-mac-tree: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@test -f $(TREE_DIR)/bf16_multi_mac_tree_mapped.sv || \
		{ echo "run 'make synth-bf16-multi-mac-tree' first"; exit 1; }
	cd $(TREE_DIR) && \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_ACCUMULATE_STAGES=$(TREE_ACC) \
		TREE_FP8=$(TREE_FP8) \
		TREE_VCD_SCOPE=$(TREE_VCD_SCOPE) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_power_tree.tcl -log genus_power.log

# Per-stage area and power breakdown. Separate run because it holds every module
# boundary so each stage stays attributable, which costs some QoR.
BREAKDOWN_DIR = build/breakdown_tree_a$(TREE_ACC)_f$(TREE_FP8)_$(TREE_MODE)

breakdown-bf16-multi-mac-tree: cln4p-libs
	$(MAKE) $(TREE_VCD)
	@mkdir -p $(BREAKDOWN_DIR)
	cd $(BREAKDOWN_DIR) && \
		TREE_PERIOD=$(TREE_PERIOD) \
		TREE_PIPELINE_STAGES=$(TREE_PIPELINE_STAGES) \
		TREE_ACCUMULATE_STAGES=$(TREE_ACC) \
		TREE_FP8=$(TREE_FP8) \
		TREE_VCD_SCOPE=$(TREE_VCD_SCOPE) \
		TREE_VCD=../../$(TREE_VCD) \
		$(GENUS) -batch \
		-files ../../scripts/report_breakdown_tree.tcl -log genus.log

licenses:
	@./scripts/check_licenses.sh

clean:
	rm -rf build
