# Run from build/synth (the Makefile handles this working directory).
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
