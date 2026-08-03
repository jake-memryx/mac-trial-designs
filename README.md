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

## Tree-MAC synthesis results

CLN4P, `tt_0p75v_25c_typical`, `MULTIPLIERS=8`, `ACCUMULATORS=32`,
`REDUCTION_GUARD_BITS=4`, zero wireload. Power is activity driven from the
matched-frequency GEMV VCD. One OP is one BF16 MAC, so a cycle retires 8 OPs.
The design targets 1.5 GHz (`0.666667 ns`) with `PIPELINE_STAGES=2`. Build with
`make synth-bf16-multi-mac-tree`, or `TREE_ACC=0` for the flat reference build;
results land in `build/synth_tree_a<TREE_ACC>`.

### The problem

At 1x the design missed timing by 67 ps on this path:

```
select_delay_reg -> 32:1 accumulator read mux -> fp32_adder -> accumulator_bank_reg
```

That is the whole accumulate read-modify-write in one cycle. It normally cannot
be pipelined, because it is a feedback loop: the next operation might target the
same accumulator, so any register inside the loop creates a read-after-write
hazard.

### The fix: exploit round-robin selection

Accumulators are selected in a fixed order `0,1,2,...,31`, so an accumulator is
not revisited for 32 cycles. That removes the hazard and lets the loop be cut
into short segments with no forwarding and no multicycle constraints.
`ACCUMULATE_STAGES` controls the depth:

- `0` - bank read, FP32 add and write-back in one cycle (original).
- `1` - registered bank read, then the full FP32 adder. The read address is a
  tap of the control chain, so the bank mux gets a cycle to itself.
- `2` - also splits `fp32_adder` into `fp32_adder_align` (decompose, special
  values, magnitude compare, alignment) and `fp32_adder_normalize` (add/sub,
  cancellation normalize, round).

Latency becomes `PIPELINE_STAGES + ACCUMULATE_STAGES` cycles; throughput stays
one operation per cycle. The contract is asserted in RTL: an accumulator still
in flight must not be re-issued.

### Results

Both builds are 1.5 GHz, `PIPELINE_STAGES=2`, from the same RTL:

| Accumulate loop | Cells | Area (um2) | Power (mW) | pJ/cycle | pJ/OP | Slack |
|---|---|---|---|---|---|---|
| flat (`TREE_ACC=0`) | 13303 | 828.7 | 6.500 | 4.33 | 0.542 | -48 ps |
| pipelined (`TREE_ACC=2`) | 11413 | 765.4 | 6.402 | 4.27 | 0.534 | **0 ps** |

The design closes, and it does so while getting **smaller and lower power**:
7.6% less area and 1.5% less energy per OP. Relieving the timing pressure lets
Genus drop the upsized cells and duplicated logic it was using to chase an
unreachable target, which more than pays for the ~100 bits of added pipeline
register. The critical path is now
`add_aligned_small_q_reg -> fp32_adder_normalize -> accumulator_bank_reg`.

Two caveats on the numbers:

- Splitting `fp32_adder` into two submodules changes the hierarchy Genus sees,
  which shifts its optimization result. The flat build above measures
  828.7 um2 / -48 ps, against 811.2 um2 / -67 ps before the split, so the table
  compares same-RTL builds rather than quoting the older figure.
- The Genus pool here allows only two concurrent seats, so run at most two
  synthesis jobs in parallel.

`ACCUMULATE_STAGES=1` (registered bank read only, without splitting the adder)
is functionally verified but was never needed to close timing, so it is not
built by the flow.

### Rejected alternative

An earlier experiment (`bf16_dual_mac_tree`, removed) moved the accumulator mux
to the input: two replicated trees, each owning 16 accumulators and given a
2-cycle multicycle path. It cost 1.6-1.8x the area and 1.3x the energy per OP
and still did not close 1x, because the multicycle relaxation was spent on the
multiply/align/reduce cone, which had slack, while the accumulate loop remained
the limiter. Pipelining that loop directly is the cheaper and effective fix.

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
