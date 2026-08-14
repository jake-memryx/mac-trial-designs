# Matrix Core

This is an implementation-oriented specification extracted from the SystemC architectural model. Parameters shown as `<P>` are implementation parameters; SystemC defaults are listed below.

## 1. Architectural constants

| Item | Default | Meaning |
|---|---:|---|
| TreeMACs | 4 | One per 128-bit LoMem lane |
| multipliers / TreeMAC | 8 | 8 BF16 multiplies per cycle |
| accumulators / TreeMAC | 16 | 64 logical accumulators total |
| BF16s / 128-bit line | 8 | Little-endian BF16 elements |
| LoMem fetch width | 512 bits | One wide row; 4 TreeMAC lanes |
| CoMem access width | 128 bits | Four accesses assemble one 512-bit operand |
| integer registers | 16 × signed 32-bit | Register 0–15 |
| output buffer | 8 × BF16 | One 128-bit output line |

Configurable queue/resource parameters:

```text
COMMAND_Q_DEPTH       = 4
DATA_Q_DEPTH          = 1       // operand and result packet queues
MEMORY_Q_DEPTH        = 12
FETCH_BUFFER_DEPTH    = 4       // per A/B prefetch buffer for BroadcastMAC
LOOP_STACK_DEPTH      = 4
STREAM_SLOTS          = 4
```

## 2. External interfaces

Two independent memory ports:

```text
LoMem: read/write, row-aligned, 512-bit wide fetches
CoMem: read/write, row-aligned, 128-bit accesses
```

A memory request contains `{domain, read/write, byte_address, byte_length, write_data}` and returns `{ticket, response, read_data}`. Requests may be outstanding up to `MEMORY_Q_DEPTH`. Responses may return later but must retain ticket/sequence association.

The instruction frontend supplies one decoded instruction per command cycle. The command stage may stall for queue capacity or memory-range dependency. Instructions are retired in program order; fetch, compute, and WB operations may overlap after issue.

## 3. Pipeline and sequencing

Stages:

```text
Command → Fetch → Compute → Writeback
```

There is at most one active operation in each stage. Between stages use bounded FIFOs:

```text
Fetch → Compute: operand packets, depth DATA_Q_DEPTH
Compute → WB:    result packets, depth DATA_Q_DEPTH
```

Every issued operation receives a nonzero sequence ID. Packets and completions carry the sequence ID. A consumer must reject a packet with the wrong sequence.

A command reserves all memory ranges it will access before issue. New reads conflict with older writes; new writes conflict with older reads. On conflict, retry without advancing PC. Queue-full stalls are structural; range conflicts and pending WB dependencies are data dependencies.

`Halt` stops issuing and enters drain; completion occurs only after all stage queues, active operations, memory requests, responses, and reservations are empty.

## 4. Data representation and arithmetic

- Memory BF16 uses IEEE BF16 bit patterns, little-endian within each 16-bit element.
- Compute TreeMAC accumulators are FP32.
- Compute operands are BF16; TreeMAC multiply/add operations use FP32 intermediate arithmetic and accumulate into FP32 accumulators.
- On every Compute→WB snapshot, each accumulator is rounded to BF16.
- WB FPU arithmetic is BF16:

```text
BF16 add:    result = round_bf16(float(lhs_bf16) + float(rhs_bf16))
BF16 multiply: result = round_bf16(float(lhs_bf16) * float(rhs_bf16))
```

The rounded BF16 result is the operand for the next WB operation.

## 5. TreeMAC

Each TreeMAC has `<ACCUMULATORS_PER_TREEMAC>` FP32 accumulators. One normal cycle consumes two 8-element BF16 vectors:

```text
p[0..7] = lhs[0..7] * rhs[0..7]
sum     = (((p0+p1)+(p2+p3)) + ((p4+p5)+(p6+p7)))
acc[i]  = acc[i] + sum
```

`BroadcastMAC` addresses accumulator groups explicitly. `MultiMAC` and elementwise operations use accumulator 0 or a group-derived accumulator as specified below.

## 6. Fetch and packet formats

### BF16 wide row

A LoMem 512-bit row is split into four lanes, each lane containing 8 BF16 values. A CoMem row-major operand is fetched as four 128-bit parts and assembled into the same logical representation.

### Operand packet

```text
sequence
operation
accumulator_index
active_lanes
lhs[4][8] : BF16
rhs[4][8] : BF16
preload[4] : FP32       // LoadAccumulators only
```

### Result packet

```text
sequence
values[N] : BF16       // snapshot already rounded at Compute→WB boundary
```

## 7. Instruction behavior

### Control

```text
set_stream S, ref, offset, inner_count, outer_count=1,
           inner_stride=1, outer_stride=inner_count*inner_stride
```

A stream address is `offset + outer*outer_stride + inner*inner_stride`; cursors advance on consumption. All accesses are row-aligned.

`li`, `addi`: signed 32-bit register operations with wraparound.

`loop count` / `endloop`: bounded loop stack; `count <= 0` skips the body.

`jump`, `blt`, `bge`: PC-relative control flow. Branches require an initialized register.

### `acc_reset`

Enqueue a Compute reset. All TreeMAC FP32 accumulators become zero.

### `load_accumulators S, idx`

- Source: LoMem `ROW_MAJOR_FP32`.
- Fetch one 128-bit line containing four FP32 values.
- Load the same four values into accumulator `idx` of all four TreeMACs.
- `idx ∈ [0, 15]`.

### `broadcast_mac A, B, valid_columns`

- A: row-major; LoMem or CoMem.
- B: LoMem `MATMUL_B` or `MATMUL_B_INT8` layout.
- `valid_columns ∈ [1,64]`.
- For each A row and each group of 4 output columns, fetch one A 128-bit line and four B lane lines.
- Replicate A to all TreeMACs; each TreeMAC lane computes one output column.
- Accumulator index is the output-column group.
- INT8 B bytes are converted to BF16 before the TreeMAC. INT8 uses two logical groups per physical 128-bit lane.
- A/B fetches use independent `<FETCH_BUFFER_DEPTH>` prefetch queues.

### `multi_mac A, B, valid_elements`

- Both operands: LoMem row-major BF16.
- `rows = ceil(valid_elements / 32)`; each row consumes one 512-bit A line and one 512-bit B line.
- Each TreeMAC lane computes an 8-element dot product into accumulator 0.
- The final row masks elements beyond `valid_elements`.
- `valid_elements > 0`.

### `elementwise_add A, B, valid_elements`

### `elementwise_mul A, B, valid_elements`

- A and B must have equal row-major shapes; either LoMem or CoMem.
- `valid_elements ∈ [1,64]`.
- No new Compute datapath: reuse TreeMAC multipliers.
- Add routes `A×1 + B×1`; multiply routes `A×B`.
- One accumulator is updated per TreeMAC per cycle; elementwise results are snapshotted in group-major order.

### `reduce_accumulators buffer_idx, count`

- `buffer_idx ∈ [0,7]`; `count ∈ [1,64]`.
- Compute snapshots the first `count` logical accumulator values in this order:

```text
accumulator 0: TreeMAC lane 0, 1, 2, 3
accumulator 1: TreeMAC lane 0, 1, 2, 3
...
```

- Snapshot values are BF16.
- WB initializes from the first BF16 value, then performs one sequential BF16 add per remaining value per cycle.
- Final BF16 sum is stored in output buffer slot `buffer_idx`.
- Compute continues after snapshot; WB owns the reduction.

### `scale_accumulators scales, output, valid_columns`

- `scales`: LoMem row-major BF16, fetched in 512-bit rows (`32 × BF16`).
- `output`: row-major LoMem or CoMem.
- Compute snapshots `valid_columns` accumulators to BF16.
- WB loads scale rows into a `<SCALE_BUFFER_DEPTH>`-entry BF16 scale buffer (SystemC implementation uses 32 entries).
- One WB FPU operation per cycle:

```text
value[i] = BF16_MUL(value[i], scale[i])
```

- Scaled values are written as 128-bit row-major lines, padding the final line with zero.

### `write_accumulators output, valid_columns`

- Output: row-major LoMem or CoMem.
- Snapshot first `valid_columns` accumulators to BF16.
- WB writes 8 BF16 values per 128-bit line; final line is zero-padded.

### `write_buf output`

- Output: row-major LoMem or CoMem.
- Wait for earlier reductions to finish, then copy the 8-entry output buffer into one 128-bit line.
- Valid slots emit their BF16 value; unset slots emit BF16 zero.
- Clear all buffer values/valid bits after the copy and advance the output stream by one line.

## 8. Memory layouts

- `ROW_MAJOR`: logical last dimension is packed into row-aligned BF16 lines; tail elements are zero-padded.
- `ROW_MAJOR_FP32`: row-aligned 128-bit lines containing four FP32 values.
- `MATMUL_B`: each B output column occupies one LoMem lane and is padded to a 128-bit lane row.
- `MATMUL_B_INT8`: two logical 8-byte INT8 groups share one 128-bit physical lane; scale values are separate BF16 data in LoMem.

## 9. Minimum RTL-visible state

```text
PC, 16×int32 registers + valid bits, loop stack
stream descriptors + cursors
4 × TreeMAC accumulator banks × 16 × FP32
output buffer: 8 × BF16 + 8 valid bits
one active command/fetch/compute/WB context
bounded operand/result/command FIFOs
memory request table and range reservations
```

Required externally observable behavior: instruction ordering, stream cursor advancement, BF16 rounding points, accumulator mapping, zero-padded writes, dependency stalls, and sequence-correct packet flow.
