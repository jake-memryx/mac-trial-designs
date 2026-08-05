# Per-stage area and power breakdown of the tree MAC.
#
# The shipping flow lets Genus dissolve hierarchy, which gives the best QoR but
# leaves the combinational logic as unnamed gates that cannot be attributed to a
# stage. This run keeps every module boundary intact so area and power can be
# reported per stage. Absolute numbers are therefore slightly worse than the
# production build; the point is the relative split.
#
# Run from build/breakdown_tree with the same env vars as the synthesis script.
set_db max_cpus_per_server 8
set_db auto_super_thread false
set_db super_thread_servers ""

set_db hdl_error_on_latch true
source ../../scripts/cln4p_libraries.tcl

set period [expr {[info exists env(TREE_PERIOD)] ? $env(TREE_PERIOD) : 0.666667}]
set stages [expr {[info exists env(TREE_PIPELINE_STAGES)] ?
                  $env(TREE_PIPELINE_STAGES) : 2}]
set acc_stages [expr {[info exists env(TREE_ACCUMULATE_STAGES)] ?
                      $env(TREE_ACCUMULATE_STAGES) : 2}]
set fp8 [expr {[info exists env(TREE_FP8)] ? $env(TREE_FP8) : 0}]
set vcd_scope [expr {[info exists env(TREE_VCD_SCOPE)] ?
                     $env(TREE_VCD_SCOPE) : "bf16_multi_mac_tree_gemv_tb/dut"}]

read_hdl -sv ../../rtl/bf16_mac.sv ../../rtl/fp8_mac.sv \
             ../../rtl/bf16_mac_tree_core.sv \
             ../../rtl/bf16_multi_mac_tree.sv
elaborate bf16_multi_mac_tree \
    -parameters [list {MULTIPLIERS 8} {ACCUMULATORS 32} \
                      {REDUCTION_GUARD_BITS 4} \
                      [list FP8_ENABLE $fp8] \
                      [list PIPELINE_STAGES $stages] \
                      [list ACCUMULATE_STAGES $acc_stages]]
check_design -unresolved

create_clock -name clk -period $period [get_ports clk]

# Hold every module boundary so each stage stays attributable.
set_db auto_ungroup none

syn_generic
syn_map
syn_opt

if {[info exists env(TREE_VCD)]} {
    read_vcd -static $env(TREE_VCD) -vcd_scope $vcd_scope
}

# These reports print to stdout rather than returning a string, so they must be
# captured with redirect. Option spellings vary between Genus releases, so try
# the hierarchical forms in turn.
redirect area_hier.rpt {report area -depth 5}

proc try_report {file cmds} {
    foreach cmd $cmds {
        if {![catch {redirect $file [list eval $cmd]}]} {
            if {[file size $file] > 0} {
                puts "INFO: '$cmd' produced [file size $file] bytes"
                return 1
            }
        }
        puts "INFO: '$cmd' unavailable"
    }
    return 0
}

try_report power_hier.rpt {
    {report power -hierarchy}
    {report power -hier}
    {report power -depth 5}
    {report power}
}

# Per-instance power as a cross-check and to cover releases where the
# hierarchical form is unavailable.
set fh [open power_by_instance.rpt w]
foreach inst {align_stage
              normalize_stage
              g_accumulate_pipelined.g_adder_split.align_half
              g_accumulate_pipelined.g_adder_split.normalize_half
              align_stage/g_leaf[0].g_product.multiplier} {
    if {[catch {redirect -variable out {report power -instance $inst}} err]} {
        puts $fh "== $inst : unavailable ($err)"
    } else {
        puts $fh "== $inst"
        puts $fh $out
    }
}
close $fh

report timing > timing.rpt
report gates  > gates.rpt
write_hdl     > breakdown_mapped.sv
write_sdc     > breakdown.sdc

puts "BF16 MULTI-MAC TREE BREAKDOWN PASSED"
exit
