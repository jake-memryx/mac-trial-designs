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

The table above predates enabling `lp_insert_clock_gating` in the synthesis
script (added for the dual-format build below, which depends on it). With clock
gating on, the same BF16-only pipelined build measures **9271 cells, 694.0 um2,
5.450 mW, 0.454 pJ/OP** at 0 ps slack. That is the baseline the dual-format
comparison uses.

### Dual-format BF16 / E4M3 mode

`FP8_ENABLE=1` adds a runtime-selectable E4M3 (OCP FP8) mode at double
throughput: 16 MACs/cycle against 8. Two FP8 values pack into each 16-bit
operand word, so the 256-bit operand bus, the 32-entry accumulator bank and the
FP32 accumulate path are all unchanged. Build with
`make synth-bf16-multi-mac-tree TREE_FP8=1`.

The reuse is nearly total because of one identity. A BF16 significand
`{1'b1, frac[6:0]}` is an integer equal to `value * 2^7`; left-justifying the
3-bit E4M3 mantissa as `{1'b1, mant[2:0], 4'b0}` gives exactly the same scaling.
So the 8x8 significand multiply, the normalize-on-bit-15 test and the FP32
product encoding are bit-identical in both formats, and only the exponent bias
differs:

| Format | `result_exp` |
|---|---|
| BF16 | `exp_a + exp_b - 127` |
| E4M3 | `exp_a + exp_b + 113` |

E4M3 products land in `[115,143]` in the FP32 exponent field, so they can
neither overflow nor underflow it and need no saturation logic. Everything
downstream of the products — alignment, reduction, normalize, round, accumulate
— is format-agnostic and untouched; the extra reduction level the wider lane
count needs is just `MULTIPLIERS=16` on the existing parameterized cores.
E4M3 subnormals are normalized properly rather than flushed.

**BF16 is kept first-class by not sharing the reduction tree.** An earlier
version widened one shared tree to 16 lanes, which taxed BF16 by 31%. Measuring
that penalty showed 79% of it was *combinational* logic in BF16's own active
path, not idle-lane leakage or clock power, so it could not be gated away: the
shared tree gave BF16 an extra reduction level, one more bit of datapath width
and dual-format decode muxes inside every lane.

The shipping design therefore gives each format its own reduction path and
shares only what the per-stage breakdown showed actually dominates — the
accumulator bank, pipeline registers, muxing and the FP32 accumulate adder:

- **BF16 path**: 8 pristine `bf16_multiplier` -> align/normalize with
  `SIGNIFICAND_BITS=16` (20-bit window, SUM_WIDTH 24). Identical to a BF16-only
  build.
- **E4M3 path**: 16 `mac_multiplier` -> align/normalize with
  `SIGNIFICAND_BITS=8` and its own `FP8_GUARD_BITS` (12-bit window,
  SUM_WIDTH 17). Independent sizing is only possible because the paths are
  separate, and it is worth a large fraction of the FP8 gain.
- The two join at a 32-bit mux feeding the existing accumulate operand
  register, which keeps it out of the tree's critical path.
- Each path's operands are mode-gated so the idle path is combinationally
  static, and the mode travels with each operation through the pipeline so a
  mode change on consecutive cycles cannot disturb work in flight.

All 1.5 GHz, `PIPELINE_STAGES=2`, `ACCUMULATE_STAGES=2`, clock gating enabled,
every build at 0 ps slack:

| Build | Mode | MACs/cyc | Cells | Area (um2) | Power (mW) | pJ/OP |
|---|---|---|---|---|---|---|
| BF16-only | BF16 | 8 | 9271 | 694.0 | 5.450 | 0.454 |
| dual | E4M3 | 16 | 14408 | 985.6 | 5.724 | **0.239** |
| dual | BF16 | 8 | 14408 | 985.6 | 6.282 | 0.523 |

FP8 mode reaches **0.239 pJ/OP, 1.90x better than the BF16 baseline at twice the
throughput** — close to ideal scaling, because the ~65% of the design that is
bank, registers, muxing and accumulate adder is amortized over 2x the work
rather than duplicated.

### Is BF16 actually untaxed? Block-level attribution

The flattened production builds show BF16 mode at 6.282 mW against the
dedicated build's 5.450 mW, a 15.3% penalty. A hierarchy-preserved run of both
(`make breakdown-bf16-multi-mac-tree`, which holds every module boundary so each
block is attributable) tells a different story. BF16-mode power, in mW:

| Block | BF16-only | Dual, BF16 mode | Delta |
|---|---|---|---|
| `bf16_align_stage` | 1.390 | 1.187 | **-0.203** |
| 8x `bf16_multiplier` | 0.826 | 0.699 | **-0.128** |
| `bf16_normalize_stage` | 0.423 | 0.355 | **-0.068** |
| accumulate adder, both halves | 0.540 | 0.560 | +0.021 |
| **entire FP8 path** | - | **0.001** | +0.001 |
| top residual (bank, registers, muxes, control) | 3.497 | 3.825 | +0.328 |
| **total** | **6.676** | **6.627** | **-0.050 (-0.7%)** |

Three conclusions:

- **The FP8 path is genuinely dark during BF16 operation** - 0.001 mW for 16
  multipliers plus a 16-lane align stage and reduction tree, i.e. leakage only.
  Operand gating plus clock gating do what they were meant to.
- **The BF16 datapath is the same hardware**: `bf16_align_stage` 84.234 ->
  83.977 um2, multipliers 130.832 -> 130.576 um2, normalize 40.837 -> 41.469
  um2. Nothing was added to it.
- **BF16-mode power is 0.7% *lower* than the dedicated build.** The BF16 blocks
  all come out cheaper, which is not noise: the operand isolation mux adds a
  gate layer ahead of the align stage, and that re-times arriving edges enough
  to cut glitch propagation into its barrel shifters - the highest glitch-power
  block in the design. It saves 0.203 mW there, more than paying for itself.

So the 15.3% seen in the flattened flow is **not an architectural tax**; it is
Genus making different global optimization choices on a larger netlist. The
residual real cost is the +0.328 mW top-level growth (the FP8 path's pipeline
registers, the isolation muxes, the result mux and `ctrl_mode_q`), which the
align-stage glitch saving happens to offset.

The practical implication is that preserving the two path hierarchies in the
production build (rather than letting `syn_opt` dissolve them) should capture
this, since the hierarchy-preserved netlist is the one that shows no penalty.
That is untested.

Two negative results worth recording:

- **Removing the BF16-side operand gate makes things worse, not better.** The
  reasoning was that leaving the BF16 cone completely ungated would give it a
  pristine path while FP8 mode absorbed the idle toggling. Measured: BF16 mode
  went to 6.537 mW (0.545 pJ/OP, worse) and FP8 mode to 7.251 mW (0.302 pJ/OP,
  27% worse). The ~0.9 mW attributed to the gate was mostly run-to-run
  optimization variance. Both paths stay gated.
- Clock gating is load-bearing for this design, not an incidental setting: the
  mode-qualified pipeline enables only become dark logic once
  `lp_insert_clock_gating` is on. Without it, no gates are inserted at all.

Area is +42% over the BF16-only build, which the area-secondary priority
accepts.

Verification: the dual-format multiplier is checked **exhaustively** over all
65536 E4M3 input pairs against a real-valued reference, covering every
subnormal, NaN, zero and the 448 max normal, and is separately proven
bit-identical to the original `bf16_multiplier` in BF16 mode. A mode-switching
testbench covers back-to-back alternating modes and cross-mode accumulation into
one accumulator. The FP8 GEMV testbench passes at the same `1e-3` relative
tolerance as the BF16 one even with the narrow 12-bit window. Ten testbenches
run under `make test`.

### Rejected alternative

An earlier experiment (`bf16_dual_mac_tree`, removed) moved the accumulator mux
to the input: two replicated trees, each owning 16 accumulators and given a
2-cycle multicycle path. It cost 1.6-1.8x the area and 1.3x the energy per OP
and still did not close 1x, because the multicycle relaxation was spent on the
multiply/align/reduce cone, which had slack, while the accumulate loop remained
the limiter. Pipelining that loop directly is the cheaper and effective fix.

## Matrix Core

`rtl/mcore/` implements the Matrix Core specified in `matrix_core.md`: a
four-stage `Command -> Fetch -> Compute -> Writeback` machine around four
TreeMAC lanes and 64 FP32 accumulators, with two memory ports (512-bit LoMem,
128-bit CoMem) and a 19-instruction ISA. Run its tests with `make test-mcore`.

The arithmetic is not new. `mcore_treemac` is the datapath of
`bf16_multi_mac_tree` reassembled from the same submodules — eight
`bf16_multiplier`, `bf16_mac_tree_align`, `bf16_mac_tree_normalize` and
`fp32_adder` — with an accumulator bank that adds the three views the ISA needs:
an arbitrary FP32 write for `load_accumulators`, a bulk clear for `acc_reset`,
and a combinational read port for the Compute→WB snapshot. Writeback's FPU is
the existing `bf16_add` and `bf16_mul`, one instance each, shared sequentially.

**The core contains no multiplier outside the TreeMAC lanes.** The specified
address formula `offset + outer*outer_stride + inner*inner_stride` is never
evaluated: streams are only ever walked in order, so a cursor keeps the address
itself and each access costs one add. The specified default
`outer_stride = inner_count*inner_stride` needs no product either, because with
that default the next outer iteration starts exactly one `inner_stride` past the
last inner address, so a `contiguous` flag reproduces it exactly. Stream state is
22-bit addresses with 16-bit counts and strides, against 32-bit integer
registers, and `set_stream` fits in two instruction words. The Command stage
walks a multi-access command one access per cycle at issue to get its exact row
range, which reuses one adder instead of building a parallel walk chain.

Two other design points worth noting:

- The accumulate loop is deliberately **flat** here, not pipelined like the
  synthesis-tuned `bf16_multi_mac_tree`. Pipelining that loop is only legal for
  round-robin accumulator selection, and `multi_mac` and the elementwise
  operations revisit accumulator 0 on consecutive cycles. The pipelined loop is
  still available for a `broadcast_mac`-only build, where the accumulator index
  is the column group.
- Memory requests carry a **ticket** whose top bit says whether Fetch or
  Writeback issued them, so both share one port per domain and reads may
  complete out of order. `make test-mcore-reorder` runs the whole suite with
  responses returned in reverse order to prove nothing depends on ordering.

### Trial synthesis

CLN4P, `tt_0p75v_25c_typical`, zero wireload, clock gating on, **hierarchy held**
(`auto_ungroup none`) so each block stays attributable. 2.0 ns (500 MHz), inputs
and outputs budgeted 30% of the period because the program memory and both
memories are off-core. Build with `make synth-mcore`; `MCORE_PERIOD` and
`MCORE_UNGROUP` select period and whether Genus may dissolve hierarchy.

**79344 cells, 5990.4 um2, 17217 flops (45.0% of area), 213 clock gates, 0 ps
slack.**

| Block | Area (um2) | Share |
|---|---:|---:|
| `compute_stage` | 2525.9 | 42.2% |
| — 4 × `mcore_treemac` | 2343.6 | 39.1% |
| — snapshot registers and muxing | 182.3 | 3.0% |
| `fetch_stage` | 1184.9 | 19.8% |
| — 2 × `mcore_read_buffer` | 835.6 | 13.9% |
| — AGU and packet assembly | 349.3 | 5.8% |
| `command_stage` | 593.3 | 9.9% |
| `writeback_stage` | 588.7 | 9.8% |
| — `bf16_add` + `bf16_mul` | 35.2 | 0.6% |
| `operand_queue` | 467.2 | 7.8% |
| `result_queue` | 388.2 | 6.5% |
| `fetch_cmd_queue` + `wb_cmd_queue` + `compute_cmd_queue` | 207.3 | 3.5% |
| `lomem_port` + `comem_port` | 34.4 | 0.6% |

A lane costs 574-605 um2, against 694 um2 for the standalone
`bf16_multi_mac_tree` at 1.5 GHz with 32 accumulators and a pipelined loop, so
the reused datapath costs what it did before.

Three things the split says:

- **The address generator is no longer the story.** The whole Command stage,
  including the reservation table, the loop stack, the register file and the
  range walker, is 9.9% of the core and contains no multiplier. The eighteen
  32x32 multipliers the literal address formula implied would each have been
  comparable to a `bf16_multiplier`.
- **After the datapath, the cost is moving operands, not computing on them.**
  The prefetch buffers and the five FIFOs together are 31.7%, all of it a
  consequence of a 512-bit operand architecture and the queue depths.
- **Power in the report is vectorless and carries no weight.** It needs an
  activity dump from a Matrix Core program, which does not exist yet.

The critical path is
`operand_queue/read_pointer_reg -> operand FIFO read mux -> multiply -> align ->
reduce -> normalize -> fp32_adder -> accumulator_bank_reg`: the flat accumulate
loop of section 10, with the FIFO output mux added in front of it. 500 MHz is
therefore the flat-loop limit, not a wireload or optimization artifact. Reaching
the tree MAC's 1.5 GHz needs the pipelined accumulate loop, which is only legal
when accumulators are selected round-robin — that is, a `broadcast_mac`-only
build, or an ISA rule that forbids re-issuing an accumulator still in flight.

Area levers in order of value, none of which touch the datapath:

1. The operand packet carries `lhs[4][8]` and `rhs[4][8]`, 1024 bits of BF16,
   but `broadcast_mac` replicates one A line to all four lanes and elementwise
   uses two of eight multiplier slots. Carrying A once plus the B row (640 bits)
   would roughly halve `operand_queue` and shrink packet assembly.
2. `FETCH_BUFFER_DEPTH` 4 to 2 halves the two read buffers, about 420 um2, at
   the cost of latency tolerance — worth measuring against real memory latency.
3. `result_queue` holds two 64-value snapshots although Writeback registers a
   packet the cycle it accepts one, so depth 1 there saves about 190 um2.

Together that is roughly 15% of the core for no loss of function.

### Verification

The testbench drives the top level only — program memory, two behavioral
memories, `start`/`done` — and checks program-visible memory against a `real`
reference. 387 checks pass in both response orderings. `MCORE_ARGS='+only=ew'`
runs one group and `'+trace'` logs every stage dispatch and completion; the
groups are `ctrl`, `acc`, `bcast`, `int8`, `multi`, `ew`, `buf`, `scale`,
`stride`, `dep`.

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
