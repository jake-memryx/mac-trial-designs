# Run from build/synth (the Makefile handles this working directory).
# Keep the run within one eight-thread Genus license allocation.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true

read_hdl -sv ../../rtl/counter.sv
elaborate counter8
check_design -unresolved

# Generic synthesis is intentionally library-independent for this tutorial.
syn_generic

report gates   > gates.rpt
report timing  > timing.rpt
report area    > area.rpt
write_hdl      > counter8_generic.sv

puts "SYNTHESIS PASSED"
exit
