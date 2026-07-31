# Run from build/synth_bf16_mama (the Makefile handles this directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

read_hdl -sv ../../rtl/bf16_mac.sv
elaborate bf16_mama -parameters {{MAMS 8} {ACCUMULATORS_PER_MAM 4}}
check_design -unresolved

# 125 MHz clock, 1/12th of the 1.5 GHz target (period in ns).
create_clock -name clk -period 8.0 [get_ports clk]

syn_generic
syn_map
syn_opt

# Annotate switching activity from the GEMV testbench so report power is
# activity driven instead of vectorless.
read_vcd -static ../vcd/bf16_mama_gemv.vcd \
    -module bf16_mama_MAMS8_ACCUMULATORS_PER_MAM4 \
    -vcd_scope bf16_mama_gemv_tb/dut

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
report power  > power.rpt
write_hdl     > bf16_mama_mapped.sv
write_sdc     > bf16_mama.sdc

puts "BF16 MAMA SYNTHESIS PASSED"
exit
