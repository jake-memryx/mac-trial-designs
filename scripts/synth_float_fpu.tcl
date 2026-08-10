# Standalone synthesis of the general-purpose floating point FPU.
#
# Run from build/synth_fpu_d<0|1> with:
#   FPU_PERIOD      clock period in ns
#   FPU_DIV_SQRT    1 to include the divide/sqrt recurrence unit
#   FPU_MANTISSA    mantissa bits: 7 = BF16, 10 = BF19 (TF32 layout)
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
set_db lp_insert_clock_gating true

source ../../scripts/cln4p_libraries.tcl

set period [expr {[info exists env(FPU_PERIOD)] ? $env(FPU_PERIOD) : 0.666667}]
set divsqrt [expr {[info exists env(FPU_DIV_SQRT)] ? $env(FPU_DIV_SQRT) : 0}]
set mantissa [expr {[info exists env(FPU_MANTISSA)] ? $env(FPU_MANTISSA) : 7}]

read_hdl -sv ../../rtl/float_fpu.sv
elaborate float_fpu -parameters [list [list MANTISSA_BITS $mantissa] \
                                       [list ENABLE_DIV_SQRT $divsqrt]]
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

# The combinational operations run straight from the primary inputs through the
# arithmetic cone into the output register, so without I/O constraints those
# paths are unconstrained and the block is effectively untimed. Zero input and
# output delay measures the FPU's own logic depth in isolation; the transition
# and load keep the endpoints from being optimistically ideal.
set fpu_inputs [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  0.0 -clock clk $fpu_inputs
set_output_delay 0.0 -clock clk [all_outputs]
set_input_transition 0.02 $fpu_inputs
set_load 0.005 [all_outputs]

syn_generic
syn_map
syn_opt

redirect area_hier.rpt {report area -depth 3}
report timing > timing.rpt
report gates  > gates.rpt
report power  > power.rpt
write_hdl     > float_fpu_mapped.sv

puts "FLOAT FPU SYNTHESIS PASSED"
exit
