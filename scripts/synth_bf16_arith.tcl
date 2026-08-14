# Standalone synthesis of one BF16 arithmetic unit.
#
# Run from build/synth_bf16_<add|mul> with:
#   BF16_UNIT    bf16_add or bf16_mul
#   BF16_PERIOD  virtual clock period in ns
#
# Both units are purely combinational and have no clock port, so timing is set
# up against a virtual clock with zero input and output delay. That measures the
# unit's own logic depth in isolation. The period is deliberately tighter than
# the block can achieve so synthesis stays timing-driven and the reported
# negative slack gives the achievable delay: delay = period - slack.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true

source ../../scripts/cln4p_libraries.tcl

set unit   [expr {[info exists env(BF16_UNIT)] ? $env(BF16_UNIT) : "bf16_mul"}]
set period [expr {[info exists env(BF16_PERIOD)] ? $env(BF16_PERIOD) : 0.2}]

read_hdl -sv ../../rtl/${unit}.sv
elaborate $unit
check_design -unresolved

create_clock -name vclk -period $period
set_input_delay  0.0 -clock vclk [all_inputs]
set_output_delay 0.0 -clock vclk [all_outputs]
set_input_transition 0.02 [all_inputs]
set_load 0.005 [all_outputs]

syn_generic
syn_map
syn_opt

redirect area_hier.rpt {report area -depth 3}
report timing > timing.rpt
report gates  > gates.rpt
report power  > power.rpt
write_hdl     > ${unit}_mapped.sv

puts "BF16 ARITH SYNTHESIS PASSED: $unit"
exit
