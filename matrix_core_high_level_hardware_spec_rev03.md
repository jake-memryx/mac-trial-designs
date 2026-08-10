# Matrix Core (MCore) High-Level Hardware Specification

**Document status:** Draft architectural baseline for SystemC and RTL bring-up  
**Revision:** 0.3  
**Basis:** Current `mcore/` Python functional model, `mcore.md`, and the decoupled command/dataflow execution model defined in this specification  
**Scope:** One Matrix Core (MCore), its command processor, compute datapath, and its interfaces to Local Memory (LoMem) and Communication Memory (CoMem)

---

## 1. Purpose

This document converts the current Python MCore model into a hardware-facing specification suitable as the starting contract for:

1. a SystemC implementation,
2. an RTL microarchitecture, and
3. compiler / firmware integration against the MCore command semantics.

The Python model remains the functional reference for arithmetic, layouts, stream semantics, and command results. The hardware execution model in this document supersedes the Python call-stack sequencing where the two differ: the Command Processor dispatches work asynchronously into independently sequenced pipeline stages.

The first implementation target is **functional and command-semantic equivalence** with the defined V1 architecture. Physical pipelining, memory latency hiding, arbitration, instruction encoding, and performance optimization may be added without changing the architectural results defined here.

### 1.1 Normative language

- **SHALL / MUST**: required for V1 architectural compatibility.
- **SHOULD**: recommended implementation choice for the first SystemC / RTL version.
- **MAY**: optional.
- **TBD**: not defined by the current model and must be resolved separately.

### 1.2 What is frozen by this specification

The following are considered V1 architectural constants:

- 4 TreeMAC compute lanes.
- 8 BF16 multipliers per TreeMAC.
- 16 FP32 accumulators per TreeMAC.
- 32 BF16 multipliers total.
- 64 FP32 accumulators total.
- 128-bit base memory line.
- 512-bit LoMem physical row, split into four independent 128-bit lanes.
- 128-bit CoMem physical row.
- 16 signed 32-bit integer control registers.
- Stream-based 2-D address generation.
- Decoupled command issue: the Command Processor may continue issuing later work after an earlier stage command has been accepted. Fetch, Compute, and Writeback execute their own queued commands in order.
- BF16 compute operands and FP32 accumulation.
- Existing accumulator ordering, tail masking, and data-layout behavior.

The following are **not** frozen by the Python model:

- clock frequency,
- physical TreeMAC pipeline depth,
- FP unit implementation,
- instruction binary encoding,
- program memory depth and interface,
- number of hardware stream-descriptor slots,
- loop-stack depth,
- memory latency,
- memory arbitration,
- exact read/write port count,
- ready/valid protocol details,
- interrupt/error reporting,
- reset sequencing at chip integration level,
- GBF128 conversion hardware,
- byte/bit endianness at external interfaces.

---

## 2. Architectural Summary

The V1 MCore is a four-lane matrix compute engine.

Each lane contains one **TreeMAC**. A TreeMAC consumes two 8-element BF16 vectors, performs eight products, reduces the eight products through an FP32 adder tree, and accumulates the result into one selected FP32 accumulator.

At full utilization:

- 4 TreeMACs operate in parallel.
- Each TreeMAC contains an 8-wide BF16 multiply/reduction datapath.
- The four TreeMACs provide 32 BF16 multipliers in parallel.
- One selected accumulator in each active TreeMAC is updated by a BroadcastMAC accumulator-group operation.
- A maximum MatMul output tile contains **64 columns**:
  - 16 accumulator indices,
  - × 4 TreeMAC lanes,
  - = 64 independent output partial sums.

### 2.1 Fixed V1 parameters

| Parameter | Symbol | V1 value | Notes |
|---|---:|---:|---|
| TreeMAC count | `M` | 4 | One per LoMem lane |
| BF16 multipliers / TreeMAC | `m` | 8 | One 8-element dot product |
| FP32 accumulators / TreeMAC | `a` | 16 | Common accumulator index across lanes |
| Total multipliers | `Mt` | 32 | `M * m` |
| Total accumulators | `At` | 64 | `M * a` |
| Base line width | — | 128 bits | 8 BF16, 4 FP32, or 16 INT8 |
| LoMem row width | — | 512 bits | 4 × 128-bit lanes |
| CoMem row width | — | 128 bits | One base line |
| Integer registers | — | 16 | Signed int32, wrap on write |
| Max BroadcastMAC output tile | — | 64 columns | 4 lanes × 16 accumulators |

### 2.2 Logical block and command/dataflow relationship

The Command Processor (CP) is **adjacent to** the dataflow pipeline. It is not a pipeline stage and normal command issue does not wait for a previously issued stage command to finish.

The data path is:

```text
                 command issue / backpressure / completion
              +---------------------------------------------+
              |                                             |
              |      +--------------------------------+     |
program ----> |      |       Command Processor        |     |
              |      | PC / decode / loops / RF       |     |
              |      | stream issue state / hazards   |     |
              |      +----+-------------+----------+--+     |
              |           |             |          |        |
              |      fetch cmd     compute cmd   wb cmd      |
              |           |             |          |        |
              |           v             v          v        |
              |   +------------+  +------------+  +------------+
              +-->| Fetch CmdQ |  | Compute Q  |  | Writeback Q|
                  +-----+------+  +-----+------+  +-----+------+
                        |               |               |
                        v               v               v
LoMem/CoMem ------> +--------+      +---------+      +----------+ -----> LoMem/CoMem
                    | Fetch  | ===> | Compute | ===> | Writeback|
                    |  FSM   | data |   FSM   | data |   FSM    |
                    +--------+      | TreeMAC |      +----------+
                                    +---------+
```

Each pipeline stage contains:

- an input command queue,
- an in-order stage FSM,
- local state/buffering required by that stage,
- backpressure to the CP when its command queue cannot accept more work.

Fetch, Compute, and Writeback may therefore be active on different commands at the same time. The dataflow connections remain ordered `Fetch -> Compute -> Writeback`; the CP controls work from the side rather than becoming part of that data path.

The exact queue depths and physical ready/valid interface are implementation parameters unless frozen later.

---

## 3. Execution Model

### 3.1 Architectural roles

The V1 implementation is divided into two control domains:

1. **Command Processor** — walks the program, executes control-flow/register operations, resolves command operands, checks hazards, and dispatches stage work.
2. **Dataflow stages** — Fetch, Compute, and Writeback, each implemented as an independent in-order FSM fed by its own command queue.

The CP does not wait for a stage command to finish merely because it has been issued. Acceptance into the required stage command queue(s) is sufficient for the CP to advance, unless a dependency rule requires otherwise.

### 3.2 Non-blocking stage command issue

For a command that targets one pipeline stage:

1. the CP decodes the program command,
2. resolves immediate/register operands and required stream state,
3. checks dependency conditions,
4. checks that the target stage command queue can accept the command,
5. enqueues the stage command,
6. advances the PC and continues program execution.

The targeted stage executes the command later, in FIFO order with respect to other commands queued to that stage.

A program-level command MAY expand into coordinated internal commands for more than one stage. For such a command, dispatch SHOULD be atomic across the required stage queues: the CP advances the PC only when every required queue can accept its corresponding internal command. This prevents partial issue and command/data misalignment.

### 3.3 Stage FSM and queue semantics

Each Fetch, Compute, and Writeback stage SHALL have an input command queue with FIFO ordering.

A stage FSM:

1. takes the oldest command when the stage is able to begin it,
2. performs all stage-local work for that command,
3. produces any required downstream data or completion indication,
4. retires the command,
5. proceeds to the next queued command.

Commands SHALL NOT reorder within a stage.

A stage may be busy while the CP continues to issue commands to that stage until its queue fills. Once full, the stage deasserts command-ready and the CP stalls only when it next needs to issue to that stage.

### 3.4 Dataflow between stages

Pipeline data moves only in the forward direction:

```text
Fetch -> Compute -> Writeback
```

The command queues and the data channels are separate concepts:

- **command queues** tell each stage what operation to perform,
- **dataflow channels** carry operand/result payloads between stages.

The stage interfaces SHALL provide enough buffering or backpressure that a producer does not overwrite data that the consumer has not accepted.

The baseline design SHOULD preserve in-order correspondence between stage commands and their associated data packets. An implementation MAY use explicit tags/sequence IDs, but tags are not architecturally required if FIFO ordering is sufficient to prove correct pairing.

### 3.5 CP stall conditions

The CP is expected to run ahead whenever it is safe to do so. It stalls for two architectural reasons:

1. **structural backpressure** — a stage command queue required by the next command is full or otherwise cannot accept the command,
2. **true dependency** — issuing the next command would allow it to observe or overwrite state whose required producer/consumer relationship is not guaranteed by existing FIFO order and dataflow handshakes.

Same-stage dependencies are normally satisfied by the stage's FIFO ordering. For example, a queued `ResetAccumulators` followed by a queued `BroadcastMAC` does not require the CP to wait for the reset to retire; the Compute stage executes them in order.

Normal producer/consumer flow between adjacent stages does not itself require a CP stall when the coordinated stage commands and data channels already preserve order. For example, the CP may enqueue the Compute half of a `BroadcastMAC` before Fetch has produced its operand packet; the Compute FSM waits locally for the matching data.

A **true CP dependency** exists when stage-local FIFO ordering and forward dataflow are not sufficient to preserve program semantics. Important examples include:

- a later Fetch reading a memory range that an earlier Writeback has not yet committed,
- a later Writeback overwriting a memory range that an earlier Fetch still needs to consume,
- any future command whose control decision depends on a value produced asynchronously by a stage,
- any architectural state that has not been captured/reserved at issue and is still owned by an earlier in-flight command.

For potentially overlapping memory accesses, the CP SHALL preserve program-order memory semantics or conservatively stall when the hazard cannot be disproved.

The exact dependency tracker may be a scoreboard, busy bits, address-range tracking, completion tokens, or equivalent logic. The mechanism is implementation-defined; the required dependency behavior is architectural.

### 3.6 Issue-time state capture

Queued commands SHALL NOT accidentally observe later CP register or stream changes.

At dispatch, the hardware must therefore capture or reserve enough state to make the queued command deterministic. This includes, as applicable:

- resolved immediate/register values,
- stream identity and descriptor fields,
- the stream cursor/range consumed by that command,
- valid-column counts,
- accumulator indices,
- memory-domain/layout selections.

A recommended implementation is to maintain issue-side stream cursors in the CP and reserve the address range for a command when it is enqueued. The queued stage command then carries an immutable view of its starting stream state. Other implementations are legal if later `SetStream` or register updates cannot change the meaning of already-issued work.

If a command's resource consumption cannot be known at issue, the CP SHALL conservatively stall until the required prior state is resolved.

### 3.7 Completion and retirement visibility

Each stage SHALL expose enough status to support:

- command-queue ready/full indication,
- stage idle/busy state or equivalent,
- command retirement/completion notification when required by dependency tracking.

The CP does not need to wait for every completion. Completion information is consumed only when needed for dependency release, status, or final program drain.

### 3.8 Program start

Starting a new program resets CP architectural state:

- `PC = 0`,
- control-register allocation/state is cleared,
- issue-side stream state is cleared,
- loop stack is cleared,
- execution state becomes running.

The baseline assumes a new program starts only when no prior program remains in flight. A hardware reset or explicit abort/flush mechanism SHALL clear stage command queues and inter-stage buffered data.

Program start does **not** implicitly define a fresh accumulation result. Programs SHALL explicitly issue `ResetAccumulators` or `LoadAccumulators` before starting a new accumulation when required.

### 3.9 Halt and program completion

`Halt` stops further program issue, but reaching `Halt` does not imply that all previously issued stage commands have retired.

The architectural `done` condition SHALL be asserted only after:

- `Halt` has been reached,
- all Fetch/Compute/Writeback command queues are empty,
- no stage FSM has an in-flight command,
- required inter-stage data buffers have drained,
- all prior memory writes belonging to the program have been accepted according to the memory-interface contract.

This drain-on-halt rule preserves non-blocking issue while providing deterministic program completion.

---

## 4. Numeric Datapath

## 5. Supported storage formats

The broader MCore concept names three matrix storage formats:

- signed INT8,
- BF16,
- GBF128.

V1 executable behavior currently implements:

- BF16 row-major data,
- FP32 accumulator seed data in LoMem,
- BF16 MatMul-B packed weights,
- signed INT8 MatMul-B packed weights with conversion to BF16 before TreeMAC compute.

GBF128 is a future feature and is **not** part of the V1 executable datapath.

## 6. Internal arithmetic contract

For the existing TreeMAC path:

1. both multiplicand vectors are interpreted / converted as BF16,
2. each BF16 operand is extended to FP32,
3. multiplication is performed into FP32,
4. the eight FP32 products are reduced with a balanced FP32 add tree,
5. the reduced FP32 value is added into the selected FP32 accumulator.

The current software reduction order is deterministic:

```text
level 0: p0 p1 p2 p3 p4 p5 p6 p7
level 1: (p0+p1) (p2+p3) (p4+p5) (p6+p7)
level 2:    s0+s1             s2+s3
level 3:             final_sum
accum:              acc += final_sum
```

To obtain bit-level agreement with the Python numerical model, the SystemC / RTL model SHOULD preserve the same operation ordering and FP32 rounding points.

### 6.1 Floating-point details still TBD

The source does not define a hardware contract for:

- NaN payload propagation,
- signaling NaNs,
- denormal/subnormal handling,
- flush-to-zero behavior,
- exception flags,
- exact overflow/underflow flag behavior,
- selectable rounding modes.

V1 SystemC may use the software BF16/FP32 behavior as its reference until a chip-wide floating-point policy is defined.

## 7. Accumulator bank

Each TreeMAC SHALL contain:

```text
16 x FP32 accumulators
```

The same accumulator index is selected across all active TreeMAC lanes during a standard `BroadcastMAC` accumulator-group update.

The logical global ordering is accumulator-major, lane-minor:

```text
global output 0  = TreeMAC0.acc[0]
global output 1  = TreeMAC1.acc[0]
global output 2  = TreeMAC2.acc[0]
global output 3  = TreeMAC3.acc[0]

global output 4  = TreeMAC0.acc[1]
...
global output 63 = TreeMAC3.acc[15]
```

This ordering is the basis of the 64-column MatMul output tile.

## 8. Accumulator reset

`ResetAccumulators` sets all 64 FP32 accumulators to +0.

## 9. Accumulator preload / bias load

`LoadAccumulators(stream, accumulator_index)` loads one 128-bit FP32 line from LoMem:

```text
FP32 word 0 -> TreeMAC0.acc[accumulator_index]
FP32 word 1 -> TreeMAC1.acc[accumulator_index]
FP32 word 2 -> TreeMAC2.acc[accumulator_index]
FP32 word 3 -> TreeMAC3.acc[accumulator_index]
```

This mechanism is used to seed bias values before MAC operations.

## 10. Compute Micro-operations

## 11. BroadcastMAC

`BroadcastMAC` is the main MatMul / convolution primitive.

Inputs:

- A stream: row-major BF16, from LoMem or CoMem.
- B stream: packed `MATMUL_B` BF16 or `MATMUL_B_INT8`, from LoMem.
- `valid_columns`: 1..64.

### 11.1 BF16 B behavior

For every A outer iteration:

1. Read one 128-bit A line = 8 BF16 values.
2. Hold that A line in the A buffer.
3. For accumulator indices `0 .. ceil(valid_columns/4)-1`:
   - read one 512-bit B row,
   - split it into four 128-bit B lanes,
   - route B lane `l` to TreeMAC `l`,
   - broadcast the same A line to all active TreeMACs,
   - update the selected accumulator index,
   - disable inactive TreeMAC lanes in the tail group.

Example full-width 64-column tile:

```text
A chunk 0:
  B group  0 -> accum[0]  on TM0..3
  B group  1 -> accum[1]  on TM0..3
  ...
  B group 15 -> accum[15] on TM0..3

A chunk 1:
  next K chunk of group 0 -> accum[0]
  ...
```

### 11.2 INT8 B behavior

A physical 128-bit LoMem lane contains two logical 8-element signed INT8 B vectors:

```text
bytes [ 0: 8] -> logical low lane
bytes [ 8:16] -> logical high lane
```

Across four physical lanes, one 512-bit LoMem row therefore contains eight logical B lanes.

For each retained B row:

1. low halves are converted signed INT8 -> BF16 and applied to accumulator `2*p`,
2. high halves are converted signed INT8 -> BF16 and applied to accumulator `2*p+1`.

If the second accumulator group is completely outside `valid_columns`, the high-half operation is omitted.

INT8 packing reduces B memory traffic while preserving the same logical accumulator organization.

### 11.3 Broadcast buffers

V1 requires logical storage equivalent to:

- A buffer: 8 BF16 = 128 bits,
- B buffer: 4 × 8 BF16 = 512 bits.

An INT8-capable Fetch implementation additionally retains one 512-bit physical B row while unpacking its low/high logical halves.

## 12. MultiMAC

`MultiMAC` provides a wide lane-parallel MAC operation.

For each consumed wide group:

- consume up to 32 BF16 values from A,
- consume up to 32 BF16 values from B,
- split each operand into four 8-element TreeMAC lanes,
- TreeMAC `l` performs an 8-element dot product,
- accumulate into `TreeMAC[l].acc[0]`.

Tail behavior:

- only TreeMAC lanes needed by the remaining valid elements are enabled,
- padding inside a final 8-element line is zero.

`MultiMAC` leaves four independent accumulator-0 partial sums. No cross-TreeMAC scalar-combine operation is part of this V1 specification.


## 13. Memory Architecture

## 14. Base line

The base memory data unit is 128 bits = 16 bytes.

Equivalent payloads include:

- 8 × BF16,
- 4 × FP32,
- 16 × INT8.

Logical matrix rows are padded on their last dimension to a multiple of a 128-bit line.

A tensor row is therefore **128-bit-line aligned**, but it is not necessarily aligned to a 512-bit LoMem physical row.

## 15. Local Memory (LoMem)

V1 physical model:

```text
LoMem physical row = 512 bits
                   = 4 lanes × 128 bits
```

Properties:

- read returns all four 128-bit lanes,
- write supplies four 128-bit lane positions,
- a 4-bit lane mask selects which lanes are updated,
- data storage itself is untyped raw bytes.

Suggested abstract write interface:

```text
lomem_wr_row_addr
lomem_wr_data[511:0]
lomem_wr_lane_en[3:0]
```

The exact request/response handshake is TBD.

### 15.1 LoMem lane-to-TreeMAC connection

Physical lane `l` maps naturally to TreeMAC `l` for wide compute.

This mapping SHALL remain fixed for V1 layouts.

## 16. Communication Memory (CoMem)

V1 physical model:

```text
CoMem physical row = 128 bits
```

Properties:

- one 128-bit line per read,
- one 128-bit line per write,
- raw-byte storage,
- lower bandwidth / higher-latency conceptual role than LoMem.

Exact latency, arbitration, and placement are system-level TBDs.

## 17. Memory depth

LoMem and CoMem depths are parameters in the high-level model.

No fixed V1 hardware depth is specified by the source.

## 18. Memory Access Concurrency Requirements

The memory system must support the logical operand movements required by queued Fetch and Writeback work. Physical port count is not frozen by this specification.

### 18.1 BroadcastMAC

For each BroadcastMAC work item, Fetch must obtain:

- the required 128-bit A line(s), and
- the corresponding packed 512-bit B row(s).

The A line is reusable across multiple B accumulator groups. If A resides in CoMem, the operands naturally come from separate memory domains. If A resides in LoMem, the Fetch FSM must schedule or buffer the A and B accesses without changing command-visible results.

Possible implementations include:

- multiple LoMem read paths,
- banked reads,
- A prefetch registers,
- B prefetch registers,
- serialized accesses hidden behind stage/data queues.

### 18.2 MultiMAC

`MultiMAC` requires one wide A operand group and one wide B operand group for each logical wide operation.

If both operands reside in LoMem, Fetch must provide both 512-bit groups through an appropriate port, bank, prefetch, or serialized-access scheme.

### 18.3 Writeback

Writeback emits one 128-bit BF16 line for every eight output values. The Writeback stage owns memory-write sequencing and may remain active while the CP and earlier pipeline stages continue with later independent work.

The baseline architecture uses a Compute-to-Writeback result snapshot. The snapshot command is ordered in the Compute FIFO after all accumulator updates it must observe. Once the resulting packet is accepted by Writeback-owned buffering, subsequent Compute commands may reuse or reset the accumulator bank without waiting for the memory write itself to finish.

A later Fetch that reads from an overlapping output address remains a true memory dependency and must wait until the required Writeback has committed.

## 19. Data Layouts

## 20. Matrix reference concept

The Python host model identifies a matrix using:

```text
domain   : LoMem or CoMem
base_row : physical memory base row
shape    : logical tensor shape
layout   : layout kind
```

Current layout kinds:

- `ROW_MAJOR`
- `ROW_MAJOR_FP32`
- `MATMUL_B`
- `MATMUL_B_INT8`

A hardware command cannot directly contain a Python `MatrixRef`. The compiler / command-loading layer SHALL lower the relevant fields into a hardware descriptor or directly into instruction fields.

### 20.1 Hardware descriptor metadata

At minimum, a hardware-visible memory descriptor needs enough information to reproduce layout-specific physical addressing.

Depending on the command, this can include:

- memory domain,
- physical base row,
- layout kind,
- logical-line-to-physical-lane mapping,

The exact descriptor format and width are TBD.

## 21. ROW_MAJOR BF16

The last logical dimension is padded with zeros to a multiple of 8 BF16 values.

One logical line:

```text
128 bits = 8 BF16 values
```

### 21.1 CoMem mapping

Logical line offset `q` maps to:

```text
physical_row = base_row + q
```

### 21.2 LoMem mapping

Four consecutive logical 128-bit lines share one physical LoMem row:

```text
physical_row = base_row + floor(q / 4)
lane         = q mod 4
```

This mapping is also used for row-major writeback.

## 22. ROW_MAJOR_FP32

This format is LoMem-only and is used for accumulator preload / bias.

One logical line:

```text
128 bits = 4 FP32 values
```

Physical mapping is the same four-lines-per-LoMem-row mapping:

```text
physical_row = base_row + floor(q / 4)
lane         = q mod 4
```

When loaded into accumulator index `s`, the four FP32 values in the selected 128-bit line map to TreeMAC0..3 at accumulator `s`.

## 23. MATMUL_B BF16 layout

For logical:

```text
B[Dk, Dn]
```

define:

```text
k_chunks = ceil(Dk / 8)
tile_width = 64 output columns
```

B is stored in LoMem by:

1. 64-column output tile,
2. accumulator group within the tile,
3. K chunk,
4. TreeMAC lane.

For output tile base `tile_column`, accumulator index `s`, K chunk `kc`, and lane `l`:

```text
LoMem[tile_base + s*k_chunks + kc][l]
    = B[kc*8 : (kc+1)*8,
        tile_column + s*4 + l]
```

Out-of-range K values and output-column tails are zero padded.

A full 64-column tile uses all 16 accumulator groups.

## 24. MATMUL_B_INT8 layout

INT8 B preserves an 8-element K chunk but packs two logical output lanes into each physical 128-bit lane.

For pair index `p`, K chunk `kc`, and physical LoMem lane `l`:

```text
lane bytes [0:8]
    = B[kc*8:(kc+1)*8, tile_column + p*8 + l]

lane bytes [8:16]
    = B[kc*8:(kc+1)*8, tile_column + p*8 + 4 + l]
```

The low half feeds accumulator `2*p`.

The high half feeds accumulator `2*p + 1`.

INT8 values are signed and converted to BF16 before the TreeMAC.

## 25. Conv1D weight layout

User-facing Conv1D weights have shape:

```text
(Cout, K, Cin)
```

Each kernel tap's `Cin` values are independently padded to a multiple of 8 BF16 values.

The padded `(K, Cin)` kernel for each output channel is then mapped into the same MATMUL_B organization used for MatMul columns.

This enables activation windows to remain natural row-major data without im2col duplication.

## 26. Conv2D weight layout

User-facing Conv2D weights have shape:

```text
(Kh, Kw, Cin, Cout)
```

Spatial taps are flattened in row-major `(Kh, Kw)` order, with each tap retaining independent 8-element Cin padding, and then packed into MATMUL_B layout.

The command program uses stream bounds to omit out-of-range padding taps rather than materializing padded activation data.

---

## 27. Stream Address Generation

## 28. Stream state

A configured stream contains:

```text
base/reference metadata
offset
inner_count
outer_count
inner_stride
outer_stride
inner_cursor
outer_cursor
```

Counts SHALL be positive.

## 29. Address sequence

For a stream access:

```text
stream_offset =
    offset
    + outer_cursor * outer_stride
    + inner_cursor * inner_stride
```

After an access:

1. increment `inner_cursor`,
2. if `inner_cursor == inner_count`:
   - set `inner_cursor = 0`,
   - increment `outer_cursor`.

If `outer_stride` is omitted:

```text
outer_stride = inner_count * inner_stride
```

## 30. Stream offset units are consumer-specific in V1

The current model does **not** use one universal address unit for all stream-consuming commands.

| Consumer / layout | Meaning of stream offset |
|---|---|
| `BroadcastMAC` A / `ROW_MAJOR` | Logical 128-bit line offset |
| `BroadcastMAC` B / `MATMUL_B*` | Physical 512-bit LoMem row offset |
| `LoadAccumulators` / `ROW_MAJOR_FP32` | Logical 128-bit FP32 line offset |
| `WriteAccumulators` / `ROW_MAJOR` | Logical 128-bit BF16 line offset |
| `MultiMAC` / LoMem `ROW_MAJOR` | Physical 512-bit wide-row offset |

A hardware implementation SHALL either preserve these semantics or have the compiler lower them into a normalized physical-address representation.

A normalized RTL AGU is recommended, but changing the command-visible stream arithmetic requires corresponding compiler changes.

---

## 31. Integer Control Datapath

## 32. Register file

V1 supports up to 8 distinct integer registers.

Architectural value width:

```text
signed 32-bit two's complement
```

Every register write wraps modulo `2^32` and is then interpreted as signed int32.

In Python-level register names SHALL be lowered by the compiler to 4-bit physical register indices.

## 33. Load immediate

```text
LoadImm(rd, imm32):
    R[rd] = imm32
```

The current assembler requires `LoadImm` values to be immediate integers.

## 34. Add immediate

```text
AddImm(rd, rs, imm):
    R[rd] = wrap_int32(R[rs] + imm)
```

`rd == rs` is legal.

## 35. IntValue operands

Many instruction fields accept either:

- a literal integer, or
- a register value resolved at execution time.

The RTL encoding for immediate-versus-register selection is TBD.

---

## 36. Control Flow

## 37. Loop

`Loop(count)`:

- resolves `count`,
- if `count > 0`, pushes:
  - `remaining = count`,
  - `body_pc = PC after Loop`,
- if `count <= 0`, skips to the instruction after the matching `EndLoop`.

Nested loops are supported semantically.

Maximum hardware loop-stack depth is TBD.

## 38. EndLoop

`EndLoop`:

1. requires an active loop frame,
2. decrements `remaining`,
3. if `remaining > 0`, sets `PC = body_pc`,
4. otherwise pops the frame and falls through.

## 39. Conditional branch

Two comparisons exist:

- `BranchIfLess`
- `BranchIfGreaterEqual`

Branch operands:

- a source integer register,
- bound = immediate or register,
- signed relative instruction offset.

The command processor increments PC before executing the instruction. Therefore, when a branch is taken:

```text
PC = PC_after_sequential_increment + offset
```

The DASL compiler resolves labels into this relative form.

## 40. V1 Instruction Semantic Reference

| Instruction | Required behavior |
|---|---|
| `SetStream` | Create/reset a 2-D stream descriptor and cursors |
| `LoadImm` | Write signed int32 register |
| `AddImm` | Signed int32 add with wrap |
| `Loop` | Enter fixed/register-driven loop or skip zero/nonpositive loop |
| `EndLoop` | Decrement/repeat/pop innermost loop |
| `BranchIfLess` | Relative branch if signed register `<` bound |
| `BranchIfGreaterEqual` | Relative branch if signed register `>=` bound |
| `ResetAccumulators` | Clear all 64 FP32 accumulators |
| `LoadAccumulators` | Load one FP32 value per TreeMAC into a common accumulator index |
| `BroadcastMAC` | Broadcast 8 BF16 A values; consume packed B groups; accumulate |
| `MultiMAC` | Four parallel 8-element lane dot products into each TreeMAC's `acc[0]` |
| `WriteAccumulators` | BF16-pack the first `valid_columns` accumulator values to a row-major stream |
| `Halt` | End program |

### 40.1 Illegal-program conditions

The architecture treats the following as programming errors:

- using an undefined stream,
- using an uninitialized integer register,
- using more than 16 integer registers,
- stream count <= 0,
- exhausting a stream,
- out-of-range accumulator index,
- invalid `valid_columns`,
- unsupported memory domain/layout for an operation,
- malformed BroadcastMAC stream dimensions,
- entering `EndLoop` without an active loop,
- loop without a matching `EndLoop`.

Hardware error response is TBD. Options include assertion-only behavior, sticky error status, command trap, or program halt.

## 41. Stage Command Ownership and Expansion

Program commands are decoded by the CP. Control-only commands execute in the CP; datapath commands are translated into one or more internal stage commands.

| Program-level command | CP action / primary stage ownership |
|---|---|
| `SetStream` | CP updates issue-side stream descriptor state |
| `LoadImm`, `AddImm` | CP integer RF operation |
| `Loop`, `EndLoop`, conditional branches | CP control-flow operation |
| `ResetAccumulators` | enqueue Compute command |
| `LoadAccumulators` | coordinated Fetch + Compute work; Fetch supplies FP32 seed data and Compute applies it in queue order |
| `BroadcastMAC` | coordinated Fetch + Compute work; Fetch produces operand packets, Compute consumes them in order |
| `MultiMAC` | coordinated Fetch + Compute work; Fetch produces wide operand packets, Compute consumes them in order |
| `WriteAccumulators` | coordinated Compute + Writeback work; Compute snapshots the selected accumulators in Compute-queue order and forwards a result packet that Writeback consumes |
| `Halt` | CP stops new issue and enters pipeline-drain state |

The exact internal microcommand encoding is TBD. The visible requirement is that multi-stage expansion preserves program semantics while allowing independent stages to overlap.

## 42. Writeback

`WriteAccumulators(stream, valid_columns)` is implemented as an ordered Compute-to-Writeback handoff.

When the corresponding Compute command reaches the head of the Compute queue, Compute snapshots accumulator values in global output order:

```text
acc0 lane0..3,
acc1 lane0..3,
...
```

The first `valid_columns` values are transferred to Writeback-owned buffering as a result packet. Once that packet has been accepted, later Compute commands may modify the live accumulator bank without affecting the pending write.

Writeback then:

1. consumes the captured FP32 values,
2. converts them to BF16,
3. packs up to 8 BF16 values per 128-bit output line,
4. zero-fills unused positions in a tail line,
5. writes the lines through the configured row-major output stream.

`valid_columns` range:

```text
1..64
```

The output stream may target LoMem or CoMem if it is row-major.

There is no V1 direct FP32 accumulator writeback path.

---

## 43. Kernel Mapping Requirements

The MCore is a programmable repeated-dot-product engine. High-level kernels are primarily compiler/program constructs, not separate fixed-function hardware units.

## 44. MatMul

Operation:

```text
C[Dm, Dn] = A[Dm, Dk] @ B[Dk, Dn]
```

Current requirements:

- A:
  - BF16 `ROW_MAJOR`,
  - LoMem or CoMem.
- B:
  - BF16 `MATMUL_B`,
  - LoMem.
- C:
  - BF16 `ROW_MAJOR`,
  - LoMem or CoMem.

The high-level MatMul compiler currently emits BF16 B layout only, although `BroadcastMAC` also understands the INT8 B layout.

### 44.1 Tiling

```text
K chunk = 8 BF16 values
output tile = up to 64 columns
accumulator group = 4 columns
```

For a full 64-column tile:

```text
16 accumulator groups × K chunks
```

## 45. Conv1D

Activation:

```text
X[Lin, Cin]
```

- row-major BF16,
- CoMem,
- raw/unpadded.

Weights:

```text
W[Cout, K, Cin]
```

- packed into MATMUL_B form,
- LoMem.

Output:

```text
Y[Lout, Cout]
```

- row-major BF16.

The compiler does not materialize im2col data.

A spatial window is represented by address-stream bounds over consecutive 128-bit channel chunks.

### 45.1 Valid padding

```text
Lout = Lin - K + 1
```

Each output position reuses `BroadcastMAC`.

The activation window spans `K * ceil(Cin/8)` logical BF16 channel chunks.

### 45.2 Same padding

No padded activation data is written.

The program splits positions into:

- left boundary,
- fully-overlapping middle,
- right boundary.

Out-of-range taps are omitted by changing stream start/count values.

This control-flow-based trimming is an architectural/software mapping technique and requires no special zero-padding datapath.

## 46. Conv2D

The current source demonstrates Conv2D through DASL programs rather than a generic `compile_conv2d()` function.

Weights are packed as flattened `(Kh, Kw)` taps using the same MatMul-B concept.

Same-padding programs split the 2-D image into branch-free spatial regions and issue BroadcastMAC only for valid kernel rows / columns.

Therefore V1 hardware need not contain a fixed-function Conv2D controller beyond the existing stream, loop, branch, and BroadcastMAC machinery.

## 47. Bias

Bias is supported by loading FP32 accumulator seed values before the corresponding MAC loops.

The program may use `LoadAccumulators` instead of `ResetAccumulators`.

---

## 48. Recommended First SystemC Partition

A first SystemC implementation SHOULD model the decoupled issue/dataflow architecture explicitly.

### 48.1 `MCoreCmd`

Responsibilities:

- PC and instruction decode,
- 16×32 signed control RF,
- loop/branch handling,
- issue-side stream state,
- command expansion,
- dependency tracking / scoreboard,
- per-stage command-ready checks,
- atomic dispatch of coordinated stage commands,
- halt/drain completion.

`MCoreCmd` should not call a stage and wait for that call to finish. It should enqueue a command through a non-blocking stage interface and continue when issue rules permit.

### 48.2 `MCoreFetch`

Contains:

- Fetch command FIFO,
- Fetch FSM,
- LoMem/CoMem request generation,
- layout-specific address generation used by Fetch,
- 128/512-bit formatting,
- MATMUL_B routing,
- INT8 half-lane unpacking/conversion,
- A/B operand buffering,
- ordered output channel to Compute.

### 48.3 `MCoreCompute`

Contains:

- Compute command FIFO,
- Compute FSM,
- ordered input channel from Fetch,
- `TreeMAC[4]`,
- 16×FP32 accumulator bank per TreeMAC,
- accumulator reset/load control,
- ordered accumulator-snapshot/result channel toward Writeback,
- completion indications needed by the CP dependency tracker.

### 48.4 `MCoreWriteback`

Contains:

- Writeback command FIFO,
- Writeback FSM,
- accumulator-snapshot/result input buffering from Compute,
- accumulator-major/lane-minor output formatting,
- FP32 -> BF16 conversion,
- line packing and tail zeroing,
- LoMem/CoMem write generation,
- completion indication.

### 48.5 Inter-stage channels

Fetch->Compute and Compute->Writeback channels SHOULD use ready/valid or an equivalent lossless backpressure protocol. Their buffer depths are TBD.

### 48.6 Memory abstraction

Memory behavior SHOULD be parameterized for depth, latency, arbitration, and physical port structure. Those implementation choices must not alter command ordering or data results.

## 49. Recommended First RTL Partition

Suggested top-level hierarchy:

```text
mcore
├── mcore_cmd
│   ├── pc_decode
│   ├── int_rf_16x32
│   ├── loop_branch_ctrl
│   ├── stream_issue_state
│   ├── dependency_scoreboard
│   └── stage_dispatch
├── mcore_fetch
│   ├── cmd_fifo
│   ├── fetch_fsm
│   ├── agu
│   ├── lomem_router
│   ├── comem_router
│   ├── a_buffer
│   ├── b_buffer
│   └── int8_to_bf16
├── mcore_compute
│   ├── cmd_fifo
│   ├── compute_fsm
│   ├── input_data_fifo
│   └── treemac[4]
│       ├── mul[8]
│       ├── fp32_reduce_tree
│       └── acc_rf_16x32
└── mcore_writeback
    ├── cmd_fifo
    ├── writeback_fsm
    ├── result_fifo
    ├── acc/result_mux
    ├── fp32_to_bf16
    ├── line_packer
    └── memory_write_router
```

The CP is structurally beside these three stages. It supplies command queues and receives ready/completion/dependency information; bulk matrix data does not flow through the CP.

A stage command FIFO MAY be shallow in the first implementation, but queue depth greater than one is useful for exercising the intended run-ahead behavior.

## 50. Internal CP-to-Stage Interface Requirements

Each stage command port SHOULD have the logical shape:

```text
cmd_valid
cmd_ready
cmd_payload
```

A command is accepted when the stage queue accepts the payload. The physical signaling may be a ready/valid channel, FIFO write interface, or equivalent.

Each stage SHALL also provide completion/status information sufficient for the CP dependency tracker and halt drain. The exact format is TBD.

The Fetch->Compute and Compute->Writeback data channels SHALL be independently backpressured so command issue and data movement remain decoupled.

## 51. Proposed External Interface Shape

This section is a **starting integration proposal**, not a source-defined interface.

## 52. Core control

At minimum:

```text
clk
reset

program/command load interface   TBD
start / enable                   TBD
done
error/status                    TBD
```

The semantic instruction set is defined, but its binary representation is not.

## 53. LoMem logical clients

Rather than freezing a physical port count too early, the MCore should expose or internally schedule at least these logical clients:

- A / row-major line read,
- B / wide packed read,
- wide row read for MultiMAC,
- FP32 accumulator preload read,
- row-major writeback.

The final memory subsystem must determine whether these map to:

- one serialized port,
- dual read ports,
- four 128-bit banks,
- prefetch queues,
- local operand registers,
- or an arbitration network.

## 54. CoMem logical clients

Required access classes:

- 128-bit row-major A/activation read,
- 128-bit row-major output write.

Exact handshake and latency are TBD.

---

## 55. State and Reset Requirements

A full hardware reset SHOULD initialize:

- CP state to idle,
- PC to 0,
- all 16 integer RF entries to 0,
- issue-side stream-valid state to 0,
- loop-stack valid state to 0,
- Fetch/Compute/Writeback command FIFOs to empty,
- inter-stage data FIFOs/buffers to empty,
- all stage FSMs to idle,
- A/B buffers to 0,
- all accumulators to 0,
- dependency-scoreboard state to clear,
- done/error state to reset values.

Architecturally, software MUST NOT depend on accumulator contents after a new program is loaded unless it explicitly resets or loads them.

---

## 56. Verification Invariants

The following assertions are useful in SystemC and RTL.

### 56.1 Structural

- exactly 4 TreeMAC instances,
- exactly 16 accumulator entries per TreeMAC,
- accumulator index in `[0, 15]`,
- active lanes in `[1, 4]`,
- BroadcastMAC `valid_columns` in `[1, 64]`.

### 56.2 Stream

- stream counts > 0,
- stream must be configured before use,
- no stream access after exhaustion,
- Broadcast A `inner_count == 1`,
- Broadcast A/B `outer_count` equal,
- BF16 Broadcast B `inner_count == ceil(valid_columns/4)`,
- INT8 Broadcast B `inner_count == ceil(ceil(valid_columns/4)/2)`.

### 56.3 Layout

- Broadcast B must be MATMUL_B or MATMUL_B_INT8 in LoMem,
- accumulator preload must be ROW_MAJOR_FP32 in LoMem,
- writeback target must be ROW_MAJOR.

### 56.4 Control

- no `EndLoop` with empty loop stack,
- no unresolved register read,
- no use of register index outside `[0, 15]`,
- branch target inside valid program range or defined trap behavior.

### 56.5 Decoupled issue / pipeline

- every accepted stage command retires exactly once,
- commands retire in FIFO order within each stage,
- the CP does not advance past a stage-targeted command until all required stage queue writes for that command have been accepted,
- the CP stalls when a required stage queue cannot accept a command,
- same-stage dependencies are preserved by FIFO order,
- cross-stage dependencies are not released before required producer state/data has been captured or completed,
- overlapping Fetch/Writeback memory hazards preserve program order,
- already-issued commands are unaffected by later RF or stream reconfiguration,
- Fetch->Compute data packets remain aligned with the Compute commands that consume them,
- Compute->Writeback result packets remain aligned with Writeback commands,
- `done` is never asserted while any stage command or program-owned data/write remains in flight.

---

## 57. Open Hardware Decisions

These items should be resolved before RTL interface freeze.

### 57.1 Memory / bandwidth

1. LoMem depth.
2. CoMem depth.
3. LoMem organization: true 512-bit memory vs four 128-bit banks.
4. LoMem read-port count.
5. Ability to serve A and B simultaneously when both reside in LoMem.
6. Ability to source both 512-bit MultiMAC operands efficiently.
7. Read latency.
8. Write latency.
9. Read-during-write behavior.
10. Core-group arbitration if LoMem is shared by multiple cores.

### 57.2 Command architecture

1. instruction width / binary encoding,
2. program memory depth,
3. load/start interface,
4. number of stream-descriptor slots,
5. stream descriptor field widths,
6. loop-stack depth,
7. immediate widths,
8. branch-offset width,
9. memory address width,
10. exception/error behavior.

### 57.3 Floating point

1. BF16 multiplier implementation,
2. FP32 adder latency,
3. FP rounding mode,
4. NaN/Inf behavior,
5. subnormal/FTZ policy,
6. FP32-to-BF16 writeback rounding policy,
7. GBF128 conversion path.

### 57.4 Pipeline / decoupling

1. Fetch command FIFO depth.
2. Compute command FIFO depth.
3. Writeback command FIFO depth.
4. Fetch->Compute data FIFO depth.
5. Compute->Writeback result FIFO depth.
6. Dependency-scoreboard implementation.
7. Stage completion signaling and optional sequence/tag fields.
8. Stream issue-state reservation mechanism.
9. TreeMAC internal latency and accumulator hazard handling.
10. A/B prefetch depth.
11. Compute-to-Writeback result FIFO organization and snapshot width.

### 57.5 Integration

1. reset polarity / synchrony,
2. clock gating,
3. power gating,
4. scan/DFT constraints,
5. debug/performance counters,
6. interrupt/completion mechanism.

---

## 58. V1 RTL Bring-up Scope Recommendation

The smallest useful RTL baseline is:

### 58.1 Required

- 4 TreeMACs.
- BF16 BroadcastMAC.
- FP32 accumulators.
- ResetAccumulators.
- LoadAccumulators.
- MultiMAC.
- WriteAccumulators.
- 16×32 integer RF.
- Per-stage command FIFOs and stage FSMs.
- CP command-ready backpressure handling.
- Dependency tracking for cross-stage hazards.
- Halt drain across all stage/data queues.
- SetStream.
- LoadImm / AddImm.
- Loop / EndLoop.
- BLT / BGE.
- Halt.
- LoMem and CoMem interfaces.
- ROW_MAJOR, ROW_MAJOR_FP32, MATMUL_B address/layout behavior.

### 58.2 Second step

- MATMUL_B_INT8 unpack and INT8->BF16 conversion.

### 58.3 Defer until behavior is clarified

- GBF128.
- strided convolution.
- dilated convolution.

This scope is sufficient to reproduce the currently exercised MatMul, Conv1D, and programmable Conv2D behaviors while implementing the intended decoupled command/dataflow architecture.

---

## 59. Acceptance Tests for First SystemC / RTL Model

The following should be treated as architectural smoke tests.

## 60. TreeMAC

- 8-element BF16 dot product matches reference reduction order.
- all 16 accumulator indices independently addressable.
- accumulator reset.
- accumulator preload.
- repeated accumulation has expected FP32 result.

## 61. BroadcastMAC

Test:

- full 64-column tile,
- tails of 1, 4, 5, 63 columns,
- multiple K chunks,
- A from CoMem,
- A from LoMem,
- B BF16,
- B INT8 once implemented.

Verify:

- accumulator mapping,
- lane masks,
- B group ordering,
- A reuse,
- stream cursor final state.

## 62. MatMul

Cover:

- Dk < 8,
- Dk not divisible by 8,
- Dn < 4,
- Dn not divisible by 4,
- Dn = 64,
- Dn > 64 with tail,
- multiple Dm rows,
- C in LoMem and CoMem.

## 63. Conv1D

Cover:

- valid padding,
- same padding,
- Cin < 8,
- Cin > 8,
- Cout tail,
- multiple kernel taps.

Verify that no padded activation storage is required.

## 64. Control flow

- nested loops,
- zero-count loop,
- register loop count,
- BLT taken/not-taken,
- BGE taken/not-taken,
- int32 positive overflow,
- int32 negative overflow.

## 65. Decoupled command issue

Cover:

- CP queues multiple Compute commands while Compute remains busy,
- CP continues through control-only commands while Fetch/Compute/Writeback have in-flight work,
- Fetch queue full stalls only when the next command requires Fetch,
- Compute queue full stalls only when the next command requires Compute,
- Writeback queue full stalls only when the next command requires Writeback,
- same-stage ResetAccumulators -> BroadcastMAC ordering without waiting for reset retirement at issue,
- Compute snapshots accumulator results in FIFO order before later Compute commands may overwrite them,
- a Fetch that reads a pending Writeback address is stalled until the required write has committed,
- stream/RF changes after issue do not change queued command meaning,
- Halt waits for complete pipeline drain before `done`.

---

## 66. Traceability to Current Python Model

The Python implementation remains the functional reference for operation semantics, arithmetic, layouts, and stream behavior. Its direct call sequencing is **not** the hardware dispatch contract. For hardware execution ordering, queueing, run-ahead, backpressure, dependency handling, and completion, this specification is normative.

Primary source locations:

| Topic | Current source |
|---|---|
| architectural constants / TreeMAC arithmetic | `mcore.py` |
| instruction semantic types / command processor | `control.py` |
| Fetch / Compute / Writeback behavior | `stages.py` |
| LoMem / CoMem physical model | `memory.py` |
| row-major and MatMul-B packing | `layout.py` |
| compiler-generated MatMul / Conv1D programs | `kernels.py` |
| DASL opcode mapping | `compiler.py` |

Important symbols to keep aligned during implementation:

```text
mcore.py:
    TREEMAC_MULTIPLIERS
    TREEMAC_ACCUMULATORS
    LOMEM_LANES
    TreeMAC

control.py:
    MAX_REGISTERS  # set to 16 for architectural conformance
    MemoryStream
    CommandProcessor

stages.py:
    FetchStage
    ComputeStage.broadcast_mac
    ComputeStage.multi_mac
    WritebackStage.write_accumulators

layout.py:
    DataLayout.pack_row_major
    DataLayout.pack_matmul_b
    DataLayout.pack_matmul_b_int8
    DataLayout.store_conv1d_weights
    DataLayout.store_conv2d_weights
```

---

## 67. Baseline Design Contract

For the first SystemC / RTL implementation, the most important contract is:

1. **The Command Processor is adjacent to, not inside, the Fetch -> Compute -> Writeback dataflow.**
2. **Stage-targeted commands are non-blocking at the CP once accepted into the required stage queue(s).**
3. **Fetch, Compute, and Writeback each execute queued commands in FIFO order using independent FSMs.**
4. **The CP stalls only for structural backpressure or dependencies that are not already guaranteed by stage FIFO/dataflow ordering.**
5. **Already-issued commands capture/reserve their required RF and stream state and cannot be changed by later CP updates.**
6. **Halt stops issue; `done` waits for all program-owned stage commands, data, and writes to drain.**
7. **Preserve data layout and accumulator ordering exactly.**
8. **Preserve BF16-input / FP32-accumulate numerical behavior.**
9. **Provide 16 signed 32-bit integer command registers.**
10. **Use the same stream-address semantics or change compiler + hardware together.**
11. **Keep unresolved physical details explicit as TBDs rather than encoding them into architectural behavior.**

This decoupled model is the baseline execution architecture for SystemC and RTL. Physical queue depths, buffering, memory organization, and dependency-tracking implementation may evolve while preserving these semantics.
