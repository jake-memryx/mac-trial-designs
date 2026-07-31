# Run from build/synth_bf16_multi_mac_tree (the Makefile handles this
# directory). Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

read_hdl -sv ../../rtl/bf16_mac.sv ../../rtl/bf16_multi_mac_tree.sv
elaborate bf16_multi_mac_tree \
    -parameters {{MULTIPLIERS 8} {ACCUMULATORS 32} {REDUCTION_GUARD_BITS 4}}
check_design -unresolved

# 125 MHz clock, 1/12th of the 1.5 GHz target (period in ns).
create_clock -name clk -period 8.0 [get_ports clk]

syn_generic
syn_map
syn_opt

# Annotate switching activity from the GEMV testbench so report power is
# activity driven instead of vectorless.
read_vcd -static ../vcd/bf16_multi_mac_tree_gemv.vcd \
    -module bf16_multi_mac_tree_MULTIPLIERS8_ACCUMULATORS32_REDUCTION_GUARD_BITS4 \
    -vcd_scope bf16_multi_mac_tree_gemv_tb/dut

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
report power  > power.rpt
write_hdl     > bf16_multi_mac_tree_mapped.sv
write_sdc     > bf16_multi_mac_tree.sdc

puts "BF16 MULTI-MAC TREE SYNTHESIS PASSED"
exit
