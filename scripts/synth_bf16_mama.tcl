# Run from build/synth_bf16_mama (the Makefile handles this directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true

# This Genus version requires a target library even for generic synthesis.
# Fall back to the tutorial library shipped with the install.
set genus_root [file dirname [file dirname [file dirname [exec which genus]]]]
set tech_lib [file join $genus_root share synth tutorials tech tutorial.lib]
read_libs $tech_lib

read_hdl -sv ../../rtl/bf16_mac.sv
elaborate bf16_mama -parameters {MAMS 8 ACCUMULATORS_PER_MAM 4}
check_design -unresolved
syn_generic

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
write_hdl     > bf16_mama_generic.sv

puts "BF16 MAMA SYNTHESIS PASSED"
exit
