# Run from build/synth (the Makefile handles this working directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

read_hdl -sv ../../rtl/counter.sv
elaborate counter8
check_design -unresolved

# 1.5 GHz clock (period in ns).
create_clock -name clk -period 0.666667 [get_ports clk]

syn_generic
syn_map
syn_opt

report gates   > gates.rpt
report timing  > timing.rpt
report area    > area.rpt
write_hdl      > counter8_mapped.sv
write_sdc      > counter8.sdc

puts "SYNTHESIS PASSED"
exit
