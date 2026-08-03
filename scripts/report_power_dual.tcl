# Power-only re-annotation for an already synthesized dual-lane tree MAC point.
#
# The mapped netlists do not depend on switching activity (the VCD is read
# after syn_opt and no power-driven optimization is enabled), so a new activity
# file only requires re-reading the netlist, its constraints and the VCD.
#
# Run from build/synth_dual_<point> with:
#   DUAL_PIPELINE_STAGES  pipeline depth of that netlist
#   DUAL_LANE_CYCLES      lane multi-cycle depth of that netlist
#   DUAL_VCD              path to the matched-frequency VCD
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

source ../../scripts/cln4p_libraries.tcl

set stages      $env(DUAL_PIPELINE_STAGES)
set lane_cycles $env(DUAL_LANE_CYCLES)
set acc_stages  $env(DUAL_ACCUMULATE_STAGES)
set vcd         $env(DUAL_VCD)
set top bf16_dual_mac_tree_MULTIPLIERS8_ACCUMULATORS32_LANES2_REDUCTION_GUARD_BITS4_PIPELINE_STAGES${stages}_LANE_CYCLES${lane_cycles}_ACCUMULATE_STAGES$acc_stages

read_hdl -netlist bf16_dual_mac_tree_mapped.sv
elaborate $top
read_sdc bf16_dual_mac_tree.sdc

read_vcd -static $vcd -vcd_scope bf16_dual_mac_tree_gemv_tb/dut

report power > power_annotated.rpt

puts "BF16 DUAL-MAC TREE POWER ANNOTATION PASSED"
exit
