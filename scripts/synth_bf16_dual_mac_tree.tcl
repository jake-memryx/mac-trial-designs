# Run from build/synth_dual_<point> (the Makefile handles this directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

# Clock period (ns), pipeline depth and lane multi-cycle depth come from the
# Makefile.
set period [expr {[info exists env(DUAL_PERIOD)] ? $env(DUAL_PERIOD) : 8.0}]
set stages [expr {[info exists env(DUAL_PIPELINE_STAGES)] ?
                  $env(DUAL_PIPELINE_STAGES) : 0}]
set lane_cycles [expr {[info exists env(DUAL_LANE_CYCLES)] ?
                       $env(DUAL_LANE_CYCLES) : 2}]
set acc_stages [expr {[info exists env(DUAL_ACCUMULATE_STAGES)] ?
                      $env(DUAL_ACCUMULATE_STAGES) : 1}]

read_hdl -sv ../../rtl/bf16_mac.sv ../../rtl/bf16_mac_tree_core.sv \
             ../../rtl/bf16_dual_mac_tree.sv
elaborate bf16_dual_mac_tree \
    -parameters [list {MULTIPLIERS 8} {ACCUMULATORS 32} {LANES 2} \
                      {REDUCTION_GUARD_BITS 4} \
                      [list PIPELINE_STAGES $stages] \
                      [list LANE_CYCLES $lane_cycles] \
                      [list ACCUMULATE_STAGES $acc_stages]]
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

# Every register-to-register segment inside a lane is allowed lane_cycles
# clock cycles: the lane operand registers only reload every lane_cycles
# cycles, and the optional stage registers are enabled on the same phase. The
# issue valid/select shift registers stay single-cycle.
set lane_launch [get_cells -hier * -filter \
    {name =~ *lane_a_reg* || name =~ *lane_b_reg* ||
     name =~ *stage1_*_reg* || name =~ *stage2_result_reg*}]
set lane_capture [get_cells -hier * -filter \
    {name =~ *stage1_*_reg* || name =~ *stage2_result_reg* ||
     name =~ *bank_reg*}]

if {[llength $lane_launch] == 0 || [llength $lane_capture] == 0} {
    puts "ERROR: lane register collections are empty; multicycle not applied"
    exit 1
}
puts "INFO: multicycle launch cells [llength $lane_launch], \
capture cells [llength $lane_capture]"

set_multicycle_path $lane_cycles -setup -from $lane_launch -to $lane_capture
set_multicycle_path [expr {$lane_cycles - 1}] -hold \
    -from $lane_launch -to $lane_capture

syn_generic
syn_map
syn_opt

# Annotate switching activity from the GEMV testbench so report power is
# activity driven instead of vectorless. DUAL_VCD carries the full path of the
# dump taken at this point's clock period.
if {[info exists env(DUAL_VCD)]} {
    read_vcd -static $env(DUAL_VCD) -vcd_scope bf16_dual_mac_tree_gemv_tb/dut
}

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
report power  > power.rpt
write_hdl     > bf16_dual_mac_tree_mapped.sv
write_sdc     > bf16_dual_mac_tree.sdc

puts "BF16 DUAL-MAC TREE SYNTHESIS PASSED"
exit
