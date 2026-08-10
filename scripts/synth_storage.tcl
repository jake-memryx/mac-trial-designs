# Standalone synthesis of the register bank and the shift register.
#
# Run from build/synth_<name> with:
#   STORAGE_MODULE  reg_bank | shift_reg
#   STORAGE_PERIOD  clock period in ns
#   STORAGE_ENTRIES entries for reg_bank
#   STORAGE_DEPTH   stages for shift_reg
#   STORAGE_TAP     output stage for shift_reg
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
set_db lp_insert_clock_gating true

source ../../scripts/cln4p_libraries.tcl

set module  [expr {[info exists env(STORAGE_MODULE)] ?
                   $env(STORAGE_MODULE) : "reg_bank"}]
set period  [expr {[info exists env(STORAGE_PERIOD)] ?
                   $env(STORAGE_PERIOD) : 0.666667}]
set entries [expr {[info exists env(STORAGE_ENTRIES)] ?
                   $env(STORAGE_ENTRIES) : 8}]
set depth   [expr {[info exists env(STORAGE_DEPTH)] ? $env(STORAGE_DEPTH) : 8}]
set tap     [expr {[info exists env(STORAGE_TAP)] ? $env(STORAGE_TAP) : 4}]

if {$module eq "reg_bank"} {
    read_hdl -sv ../../rtl/reg_bank.sv
    elaborate reg_bank -parameters [list [list ENTRIES $entries] {WIDTH 128}]
} else {
    read_hdl -sv ../../rtl/shift_reg.sv
    elaborate shift_reg -parameters [list [list DEPTH $depth] {WIDTH 128} \
                                          [list OUTPUT_TAP $tap]]
}
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

# Constrain the I/O, or the port-to-register and register-to-port paths go
# unreported and the block is effectively untimed.
set storage_inputs [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  0.0 -clock clk $storage_inputs
set_output_delay 0.0 -clock clk [all_outputs]
set_input_transition 0.02 $storage_inputs
set_load 0.005 [all_outputs]

syn_generic
syn_map
syn_opt

redirect area_hier.rpt {report area -depth 3}
report timing > timing.rpt
report gates  > gates.rpt
report power  > power.rpt

puts "STORAGE SYNTHESIS PASSED"
exit
