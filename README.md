# Verilog counter crash course

This small project demonstrates the basic RTL loop: write synthesizable
Verilog, verify it with a self-checking SystemVerilog testbench, and synthesize
it with Cadence Genus.

## Layout

- `rtl/counter.v` — synthesizable 8-bit counter
- `tb/counter_tb.sv` — self-checking testbench
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

## Clean generated files

```sh
make clean
```
