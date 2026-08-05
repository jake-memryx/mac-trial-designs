# Hierarchical power re-report for the hierarchy-preserved breakdown netlist.
# Reads the saved netlist so no re-synthesis is needed.
#
# Run from build/breakdown_tree with TREE_VCD set.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

source ../../scripts/cln4p_libraries.tcl

set stages     [expr {[info exists env(TREE_PIPELINE_STAGES)] ?
                      $env(TREE_PIPELINE_STAGES) : 2}]
set acc_stages [expr {[info exists env(TREE_ACCUMULATE_STAGES)] ?
                      $env(TREE_ACCUMULATE_STAGES) : 2}]
set fp8 [expr {[info exists env(TREE_FP8)] ? $env(TREE_FP8) : 0}]
set vcd_scope [expr {[info exists env(TREE_VCD_SCOPE)] ?
                     $env(TREE_VCD_SCOPE) : "bf16_multi_mac_tree_gemv_tb/dut"}]
set top bf16_multi_mac_tree_MULTIPLIERS8_ACCUMULATORS32_REDUCTION_GUARD_BITS4_FP8_ENABLE${fp8}_PIPELINE_STAGES${stages}_ACCUMULATE_STAGES$acc_stages

read_hdl -netlist breakdown_mapped.sv
elaborate $top
read_sdc breakdown.sdc

read_vcd -static $env(TREE_VCD) -vcd_scope $vcd_scope

redirect power_hier.rpt {report power -by_hierarchy -levels all -unit mW}

puts "BF16 MULTI-MAC TREE HIERARCHICAL POWER PASSED"
exit
