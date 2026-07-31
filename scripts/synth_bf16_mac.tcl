# Run from build/synth_bf16_mac (the Makefile handles this directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

read_hdl -sv ../../rtl/bf16_mac.sv
elaborate bf16_mac
check_design -unresolved

# 1.5 GHz clock (period in ns).
create_clock -name clk -period 0.666667 [get_ports clk]

syn_generic
syn_map
syn_opt

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
write_hdl     > bf16_mac_mapped.sv
write_sdc     > bf16_mac.sdc

puts "BF16 MAC SYNTHESIS PASSED"
exit
