# Power-only re-annotation for an already synthesized tree MAC point.
#
# The mapped netlists do not depend on switching activity (the VCD is read
# after syn_opt and no power-driven optimization is enabled), so a new activity
# file only requires re-reading the netlist, its constraints and the VCD.
#
# Run from build/synth_tree_<point> with:
#   TREE_PIPELINE_STAGES  pipeline depth of that netlist
#   TREE_VCD              path to the matched-frequency VCD
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

source ../../scripts/cln4p_libraries.tcl

set stages     $env(TREE_PIPELINE_STAGES)
set acc_stages [expr {[info exists env(TREE_ACCUMULATE_STAGES)] ?
                      $env(TREE_ACCUMULATE_STAGES) : 0}]
set vcd        $env(TREE_VCD)
set top bf16_multi_mac_tree_MULTIPLIERS8_ACCUMULATORS32_REDUCTION_GUARD_BITS4_PIPELINE_STAGES${stages}_ACCUMULATE_STAGES$acc_stages

read_hdl -netlist bf16_multi_mac_tree_mapped.sv
elaborate $top
read_sdc bf16_multi_mac_tree.sdc

read_vcd -static $vcd -vcd_scope bf16_multi_mac_tree_gemv_tb/dut

report power > power_annotated.rpt

puts "BF16 MULTI-MAC TREE POWER ANNOTATION PASSED"
exit
