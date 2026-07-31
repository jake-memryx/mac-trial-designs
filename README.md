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

## Run generic synthesis

```sh
make synth
```

This runs generic synthesis without a process-design-kit cell library. Reports
and the generated generic netlist land in `build/synth/`. A later exercise can
add timing constraints and a real standard-cell library for technology mapping.
Use `make synth-bf16-mac` for the generic BF16 MAC synthesis flow.

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
