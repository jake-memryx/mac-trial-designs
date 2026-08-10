# Run from build/synth_bf16_multi_mac_tree (the Makefile handles this
# directory). Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true

# Insert integrated clock gates for enable-guarded registers. The dual-format
# build depends on this: each reduction path's pipeline registers are enabled by
# the mode, so gating leaves the idle path's flops unclocked instead of merely
# holding their data.
set_db lp_insert_clock_gating true

source ../../scripts/cln4p_libraries.tcl

# Clock period (ns) and pipeline depth come from the Makefile.
set period [expr {[info exists env(TREE_PERIOD)] ? $env(TREE_PERIOD) : 8.0}]
set stages [expr {[info exists env(TREE_PIPELINE_STAGES)] ?
                  $env(TREE_PIPELINE_STAGES) : 0}]
set acc_stages [expr {[info exists env(TREE_ACCUMULATE_STAGES)] ?
                      $env(TREE_ACCUMULATE_STAGES) : 0}]
set fp8 [expr {[info exists env(TREE_FP8)] ? $env(TREE_FP8) : 0}]
set ext [expr {[info exists env(TREE_EXT)] ? $env(TREE_EXT) : 0}]
set vcd_scope [expr {[info exists env(TREE_VCD_SCOPE)] ?
                     $env(TREE_VCD_SCOPE) : "bf16_multi_mac_tree_gemv_tb/dut"}]

read_hdl -sv ../../rtl/bf16_mac.sv ../../rtl/fp8_mac.sv \
             ../../rtl/bf16_mac_tree_core.sv \
             ../../rtl/bf16_multi_mac_tree.sv
elaborate bf16_multi_mac_tree \
    -parameters [list {MULTIPLIERS 8} {ACCUMULATORS 32} \
                      {REDUCTION_GUARD_BITS 4} \
                      [list FP8_ENABLE $fp8] \
                      [list EXTERNAL_ACCUMULATE $ext] \
                      [list PIPELINE_STAGES $stages] \
                      [list ACCUMULATE_STAGES $acc_stages]]
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

syn_generic
syn_map
syn_opt

# Annotate switching activity from the GEMV testbench so report power is
# activity driven instead of vectorless. TREE_VCD carries the full path of the
# dump taken at this point's clock period.
if {[info exists env(TREE_VCD)]} {
    read_vcd -static $env(TREE_VCD) -vcd_scope $vcd_scope
}

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
report power  > power.rpt
write_hdl     > bf16_multi_mac_tree_mapped.sv
write_sdc     > bf16_multi_mac_tree.sdc

puts "BF16 MULTI-MAC TREE SYNTHESIS PASSED"
exit
