# Standalone synthesis of a flat registered buffer.
#
# Run from build/synth_reg_<width>b_e<0|1> with:
#   REG_WIDTH   buffer width in bits
#   REG_ENABLE  1 for an enable-gated load, 0 for unconditional
#   REG_PERIOD  clock period in ns
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
set_db lp_insert_clock_gating true

source ../../scripts/cln4p_libraries.tcl

set width  [expr {[info exists env(REG_WIDTH)]  ? $env(REG_WIDTH)  : 512}]
set enable [expr {[info exists env(REG_ENABLE)] ? $env(REG_ENABLE) : 1}]
set period [expr {[info exists env(REG_PERIOD)] ? $env(REG_PERIOD) : 0.666667}]

read_hdl -sv ../../rtl/reg_buffer.sv
elaborate reg_buffer -parameters [list [list WIDTH $width] \
                                       [list HAS_ENABLE $enable]]
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]
set reg_inputs [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  0.0 -clock clk $reg_inputs
set_output_delay 0.0 -clock clk [all_outputs]
set_input_transition 0.02 $reg_inputs
set_load 0.005 [all_outputs]

syn_generic
syn_map
syn_opt

redirect area_hier.rpt {report area -depth 3}
report timing > timing.rpt
report gates  > gates.rpt
report power  > power.rpt

puts "REG BUFFER SYNTHESIS PASSED: ${width}b enable=${enable}"
exit
