# SystemVerilog counter crash course

This small project demonstrates the basic RTL loop: write synthesizable
SystemVerilog, verify it with a self-checking SystemVerilog testbench, and
synthesize it with Cadence Genus.

## Layout

- `rtl/counter.sv` — synthesizable 8-bit counter
- `rtl/bf16_mac.sv` — BF16 multiplier, FP32 adder, and accumulator
- `tb/counter_tb.sv` — self-checking testbench
- `tb/bf16_mac_tb.sv` — self-checking BF16 MAC testbench
- `sim/files.f` — xrun source file list
- `scripts/synth.tcl` — technology-independent Genus flow
- `build/` — generated logs, libraries, reports, and netlists

The counter has a synchronous, active-high reset. On each rising clock edge,
reset clears the count; otherwise, `enable` increments it. With `enable` low,
the count holds. Overflow naturally wraps from `8'hff` to `8'h00`.

## Run simulation tests

```sh
make test
```

The testbench checks reset, normal counting, enable/hold behavior, 8-bit
wraparound, and reset priority. A successful run ends with `TEST PASSED` and a
zero exit status. The xrun log is written to `build/sim/xrun.log`.

Run only the BF16 MAC tests with `make test-bf16-mac`. The MAC commits
`accumulator + (a * b)` on each enabled rising edge. It uses FP32
round-to-nearest-even addition and flushes subnormal inputs and results to zero.
Its log is written to `build/sim_bf16_mac/xrun.log`.

The same RTL file also contains `bf16_mam` (Multi-Accumulator MAC), a
parameterized bank that shares one multiplier and adder across `ACCUMULATORS`
FP32 registers.
`accumulator_select` chooses the destination of each enabled MAC and the value
visible on the output. Run its tests with `make test-bf16-mam`.

`bf16_mama` (Multi-Accumulator MAC Array) instantiates `MAMS` independent MAM
lanes. Each lane has separate operands, enable, selection, and output; reset and
clear are shared. Run its tests with `make test-bf16-mama`.

`bf16_multi_mac_tree` is the parallel alternative. `MULTIPLIERS` exact 16-bit
BF16 product significands are aligned to a shared exponent and reduced by a
narrow signed integer tree. The tree is normalized and rounded to FP32 once,
then added to one selected FP32 accumulator with a full FP32 adder. The
`REDUCTION_GUARD_BITS` parameter controls the precision/efficiency tradeoff and
non-power-of-two configurations are padded with zero leaves. Run its tests with
`make test-bf16-multi-mac-tree`.

To run the underlying command manually:

```sh
mkdir -p build/sim
xrun -64bit -sv -f sim/files.f -top counter_tb \
  -xmlibdirname build/sim/xcelium.d \
  -logfile build/sim/xrun.log
```

## Run synthesis

```sh
make synth
```

The synthesis flows target TSMC CLN4P Base and MB cells using SVT, LVT, and
LVTLL CCS libraries at TT, 0.75 V, and 25 C. The first run extracts only those
six views from the kit archives into `build/cln4p_libs/`. Genus maps and
optimizes against a 1.5 GHz (`0.666667 ns`) clock. Reports, mapped netlists, and
SDC files land under their respective `build/synth*` directories. Use
`make synth-bf16-mac` or `make synth-bf16-mama` for those designs.

## Tree-MAC synthesis sweep results

CLN4P, `tt_0p75v_25c_typical`, `MULTIPLIERS=8`, `ACCUMULATORS=32`,
`REDUCTION_GUARD_BITS=4`, zero wireload. Power is activity driven from the
matched-frequency GEMV VCD. One OP is one BF16 MAC, so a cycle retires 8 OPs.

`bf16_multi_mac_tree` — one tree, output-side accumulator mux, single-cycle
datapath deepened with pipeline stages:

| Point | Period | Freq | Stages | Cells | Area (um2) | Power (mW) | pJ/cycle | pJ/OP | Slack |
|---|---|---|---|---|---|---|---|---|---|
| 1/4 | 2.667 ns | 375 MHz | 0 | 8722 | 588.5 | 1.378 | 3.68 | 0.459 | 0 ps |
| 1/2 | 1.333 ns | 750 MHz | 1 | 9352 | 653.4 | 3.035 | 4.05 | 0.506 | 0 ps |
| 1x | 0.667 ns | 1.5 GHz | 2 | 12994 | 811.2 | 6.806 | 4.54 | 0.567 | -67 ps |

`bf16_dual_mac_tree` — two replicated trees, input-side lane demux, each lane a
declared 2-cycle multicycle path (`LANE_CYCLES=2`, lanes own 16 accumulators
each):

| Point | Period | Freq | Stages | Cells | Area (um2) | Power (mW) | pJ/cycle | pJ/OP | Slack |
|---|---|---|---|---|---|---|---|---|---|
| 1/4 | 2.667 ns | 375 MHz | 0 | 14731 | 1051.4 | 1.896 | 5.06 | 0.632 | +42 ps |
| 1/2 | 1.333 ns | 750 MHz | 0 | 17987 | 1135.5 | 4.215 | 5.62 | 0.702 | 0 ps |
| 1x | 0.667 ns | 1.5 GHz | 1 | 23056 | 1366.6 | 9.265 | 6.18 | 0.772 | -26 ps |

`bf16_dual_mac_tree` with `ACCUMULATE_STAGES=1` — as above, plus the accumulate
read-modify-write split into a registered bank read and a separate add plus
write-back. The read is overlapped with the last cycle of the lane's tree
segment, so latency and throughput are unchanged:

| Point | Period | Freq | Stages | Cells | Area (um2) | Power (mW) | pJ/cycle | pJ/OP | Slack |
|---|---|---|---|---|---|---|---|---|---|
| 1/4 | 2.667 ns | 375 MHz | 0 | 14871 | 1064.9 | 1.948 | 5.20 | 0.649 | +262 ps |
| 1/2 | 1.333 ns | 750 MHz | 0 | 17982 | 1148.1 | 4.295 | 5.73 | 0.716 | 0 ps |
| 1x | 0.667 ns | 1.5 GHz | 1 | 21221 | 1293.9 | 9.009 | 6.01 | 0.751 | 0 ps |

The first dual-lane experiment does not pay off on its own: it costs 1.7-1.8x
the area and 1.36-1.38x the energy per OP, and it still misses 1.5 GHz. The
reason is that the relaxed path was never the binding one. In all three
`ACCUMULATE_STAGES=0` builds the critical path is
`issue_sel_reg -> bank read mux -> fp32_adder -> bank_reg`, the single-cycle
accumulate read-modify-write loop. Splitting the bank into two 16-entry halves
only shortens that mux by one level, so the 1x point still misses (-26 ps,
versus -67 ps for the single tree), while the multicycle relaxation is spent on
a multiply/align/reduce cone that had slack to spare.

Pipelining the accumulate loop fixes exactly that. With `ACCUMULATE_STAGES=1`
the limiter becomes `selected_accumulator_reg -> fp32_adder -> bank_reg`, and:

- the 1x point closes timing at 0 ps, making it the only 1.5 GHz build of the
  three that meets its constraint (single tree -67 ps, dual v1 -26 ps);
- it is also smaller and lower power than dual v1 at 1x (1293.9 vs 1366.6 um2,
  9.009 vs 9.265 mW), because Genus no longer has to over-size the accumulate
  cone chasing an unreachable target;
- the 1/4 point gains 262 ps of slack over the 42 ps of dual v1, i.e. headroom
  for a further frequency push or a voltage reduction.

It still does not beat the single tree on absolute area or energy per OP: 1.59x
area and 1.32x pJ/OP at 1x. Replicating the trees doubles leakage and clock
power, and the operand hold registers add 2 x 8 x 32 bits of flops that toggle
at the full issue rate, so halving each lane's activity does not halve its
energy. The honest conclusion is that the input-side mux buys timing closure at
1.5 GHz, not efficiency; if the goal is pJ/OP, the single tree at a lower
frequency point remains the better design.

The dual-lane design also imposes an issue contract the single tree does not:
consecutive operations must alternate accumulator halves, so drivers have to
interleave their output-column order. `bf16_dual_mac_tree_gemv_tb` visits
columns as 0, 16, 1, 17, ... to satisfy it, and the RTL asserts it.

Reproduce with `make synth-bf16-multi-mac-tree`,
`make synth-bf16-dual-mac-tree` (single-cycle accumulate) and
`make synth-bf16-dual-mac-tree-pipelined` (registered bank read); re-annotate
power on existing netlists with `make power-tree`, `make power-dual` and
`make power-dualp`. Note that the Genus pool here allows only two concurrent
seats, so run at most two synthesis points in parallel.

## Clean generated files

```sh
make clean
```

## Check Cadence licenses

```sh
make licenses
```

The helper displays separate Limited Single Core and Single Core Xcelium pools,
their aggregate total, and Genus. Each row includes the tool version, total
seats, available seats, and a colored utilization bar. Use
`scripts/check_licenses.sh --no-color` for plain output.
