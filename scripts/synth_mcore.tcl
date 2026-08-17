# Matrix Core trial synthesis: an area characterization, not a shipping build.
#
# Run from build/synth_mcore (the Makefile handles this directory).
#
# Two deliberate differences from the tree-MAC flow:
#
#   * Hierarchy is held (auto_ungroup none) so area is attributable to the
#     Command, Fetch, Compute and Writeback stages and to the FIFOs. Absolute
#     numbers are therefore slightly worse than a dissolved build; the point of
#     this run is the split.
#   * Power is vectorless. There is no activity dump for the Matrix Core yet, so
#     the power number in the reports carries no weight.
#
# The clock is relaxed by default (MCORE_PERIOD): the accumulate loop inside the
# TreeMAC lanes is flat here, so 1.5 GHz is not expected to close and would only
# distort the area figure.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
set_db lp_insert_clock_gating true

source ../../scripts/cln4p_libraries.tcl

set period [expr {[info exists env(MCORE_PERIOD)] ? $env(MCORE_PERIOD) : 2.0}]
set ungroup [expr {[info exists env(MCORE_UNGROUP)] ? $env(MCORE_UNGROUP) : 0}]

read_hdl -sv ../../rtl/bf16_mac.sv \
             ../../rtl/bf16_mac_tree_core.sv \
             ../../rtl/bf16_add.sv \
             ../../rtl/bf16_mul.sv \
             ../../rtl/mcore/mcore_pkg.sv \
             ../../rtl/mcore/mcore_fifo.sv \
             ../../rtl/mcore/mcore_read_buffer.sv \
             ../../rtl/mcore/mcore_treemac.sv \
             ../../rtl/mcore/mcore_cmd.sv \
             ../../rtl/mcore/mcore_fetch.sv \
             ../../rtl/mcore/mcore_compute.sv \
             ../../rtl/mcore/mcore_writeback.sv \
             ../../rtl/mcore/mcore_memport.sv \
             ../../rtl/mcore/mcore.sv
elaborate mcore
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

# The program memory and both memories are outside the core, so give their
# arrival and required times a share of the period instead of leaving them at
# zero, which would flatter the decode and store paths.
set io_budget [expr {$period * 0.3}]
set_input_delay  $io_budget -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay $io_budget -clock clk [all_outputs]

if {$ungroup == 0} {
    set_db auto_ungroup none
}

syn_generic
syn_map
syn_opt

report gates  > gates.rpt
report timing > timing.rpt
report area   > area.rpt
redirect area_hier.rpt {report area -depth 3}
report power  > power.rpt
write_hdl     > mcore_mapped.sv
write_sdc     > mcore.sdc

# Per-block area, which is the number this run exists to produce.
set fh [open area_by_block.rpt w]
foreach inst {command_stage
              fetch_stage
              fetch_stage/buffer_a
              fetch_stage/buffer_b
              compute_stage
              compute_stage/g_lane[0].treemac
              writeback_stage
              lomem_port
              comem_port
              fetch_cmd_queue
              compute_cmd_queue
              wb_cmd_queue
              operand_queue
              result_queue} {
    if {[catch {redirect -variable out {report area -instance $inst}} err]} {
        puts $fh "== $inst : unavailable ($err)"
    } else {
        puts $fh "== $inst"
        puts $fh $out
    }
}
close $fh

puts "MCORE SYNTHESIS PASSED"
exit
