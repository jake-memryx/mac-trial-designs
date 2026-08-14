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

## 10. RTL hierarchy

Sections 1–9 are the architectural contract. Sections 10–22 pin it down to one
implementation: module boundaries, encodings, cycle-level micro-sequences and
the observable checks that verify them.

```text
mcore                       top: stages, inter-stage FIFOs, port arbitration
├── mcore_cmd               Command stage (control processor)
├── mcore_fetch             Fetch stage: AGU, read clients, operand assembly
├── mcore_compute           Compute stage: 4 lanes, snapshot
│   └── mcore_treemac  ×4   one TreeMAC lane
│       ├── bf16_multiplier          ×8   (rtl/bf16_mac.sv)
│       ├── bf16_mac_tree_align           (rtl/bf16_mac_tree_core.sv)
│       ├── bf16_mac_tree_normalize       (rtl/bf16_mac_tree_core.sv)
│       └── fp32_adder                    (rtl/bf16_mac.sv)
├── mcore_writeback         WB stage: BF16 FPU, buffers, line packer
│   ├── bf16_add                          (rtl/bf16_add.sv)
│   └── bf16_mul                          (rtl/bf16_mul.sv)
├── mcore_memport      ×2   request arbitration and response routing
└── mcore_fifo         ×5   command and data channels
```

Existing arithmetic is reused unchanged. `mcore_treemac` is a thin wrapper, not
new arithmetic: it is the datapath of `bf16_multi_mac_tree` (multiply →
shared-exponent align → integer reduce → normalize/round once → FP32 add) with
a different accumulator bank. `bf16_multi_mac_tree` cannot be instantiated
directly because its bank has no write port and exposes only the selected
accumulator, while sections 7.3 and 7.9 require an arbitrary FP32 write
(`load_accumulators`), a bulk clear (`acc_reset`) and a full 16-entry read
(snapshot).

`bf16_multi_mac_tree` also pipelines the accumulate loop (`ACCUMULATE_STAGES`),
which is legal only for round-robin accumulator selection. `multi_mac` and the
elementwise operations revisit accumulator 0 on consecutive cycles, so
`mcore_treemac` keeps the flat one-cycle read-modify-write loop. The pipelined
loop remains available for a `broadcast_mac`-only build, where the accumulator
index is the column group and does advance round-robin.

## 11. Implementation parameters

`mcore_pkg` holds all of them. Architectural values are from section 1; the
remainder are choices this implementation makes.

| Parameter | Value | Source |
|---|---:|---|
| `TREEMACS` | 4 | §1 |
| `TREEMAC_MULTIPLIERS` | 8 | §1 |
| `TREEMAC_ACCUMULATORS` | 16 | §1 |
| `TOTAL_ACCUMULATORS` | 64 | §1 |
| `LINE_WIDTH` | 128 | §1 |
| `LOMEM_WIDTH` | 512 | §1 |
| `COMEM_WIDTH` | 128 | §1 |
| `BF16_PER_LINE` | 8 | §1 |
| `FP32_PER_LINE` | 4 | §1 |
| `INT8_PER_LINE` | 16 | §1 |
| `INT_REGISTERS` | 16 | §1 |
| `OUTPUT_BUFFER_SLOTS` | 8 | §1 |
| `SCALE_BUFFER_ENTRIES` | 32 | §7.10 |
| `COMMAND_Q_DEPTH` | 4 | §1 |
| `DATA_Q_DEPTH` | 2 | §1 (see §21) |
| `MEMORY_Q_DEPTH` | 12 | §1 |
| `FETCH_BUFFER_DEPTH` | 4 | §1 |
| `LOOP_STACK_DEPTH` | 4 | §1 |
| `STREAM_SLOTS` | 4 | §1 |
| `REDUCTION_GUARD_BITS` | 4 | matches the verified TreeMAC build |
| `MEM_ROW_WIDTH` | 16 | row address width, choice |
| `PROG_ADDR_WIDTH` | 12 | choice |
| `INSTR_WIDTH` | 64 | choice |
| `SEQ_WIDTH` | 6 | choice; 0 is the reserved null sequence |
| `TICKET_WIDTH` | 5 | choice; `> $clog2(MEMORY_Q_DEPTH)` plus source bit |
| `RESERVATIONS` | 4 | choice; range table depth |
| `COUNT_WIDTH` | 7 | holds 1..64 |

Derived: `ACC_SELECT_WIDTH = 4`, `LANE_SELECT_WIDTH = 2`,
`STREAM_ID_WIDTH = 3` (field is 3 bits; slots above `STREAM_SLOTS` are illegal).

## 12. Instruction encoding

The frontend supplies one 64-bit decoded word per command cycle from a
combinationally read program memory (`prog_addr` → `prog_data`). Every
instruction is one word except `set_stream`, which is four consecutive words.

```text
[63:59] opcode
[58:55] rd
[54:51] rs
[50:48] stream_a      (also buffer_idx for reduce_accumulators)
[47:45] stream_b
[44:38] count         valid_columns / valid_elements, 1..64
[37:34] acc_index     0..15
[33]    reserved
[32]    imm_is_reg    1 => imm[3:0] names a register
[31:0]  imm           literal, register index, or branch bound
```

Branches and `jump` alias `offset` over `[44:33]` as a signed 12-bit
PC-relative displacement, because they use neither `count` nor `acc_index`.

```text
[44:33] offset        signed, relative to the sequential PC
```

`set_stream` uses four words:

```text
word0 [63:59] opcode          [58:56] stream id      [55] domain
      [54:53] layout          [52:37] base_row       [36] has_outer_stride
      [35:31] reg_select      MSB..LSB = offset, inner_count, outer_count,
                              inner_stride, outer_stride
word1 [63:32] offset          [31:0]  inner_count
word2 [63:32] outer_count     [31:0]  inner_stride
word3 [63:32] outer_stride    [31:0]  reserved
```

A field selected by `reg_select` carries a register index in the low 4 bits of
its 32-bit slot and is resolved when the instruction executes.

Opcodes:

| Value | Mnemonic | Value | Mnemonic |
|---:|---|---:|---|
| 0 | `set_stream` | 10 | `broadcast_mac` |
| 1 | `li` | 11 | `multi_mac` |
| 2 | `addi` | 12 | `elementwise_add` |
| 3 | `loop` | 13 | `elementwise_mul` |
| 4 | `endloop` | 14 | `reduce_accumulators` |
| 5 | `jump` | 15 | `scale_accumulators` |
| 6 | `blt` | 16 | `write_accumulators` |
| 7 | `bge` | 17 | `write_buf` |
| 8 | `acc_reset` | 18 | `halt` |
| 9 | `load_accumulators` | | |

## 13. Memory ports

Each domain is one request channel and one response channel. `LoMem` requests
are 512-bit with a 4-bit lane write mask; `CoMem` requests are 128-bit.

```text
output <p>_req_valid          input  <p>_req_ready
output <p>_req_write          output <p>_req_row     [MEM_ROW_WIDTH-1:0]
output <p>_req_ticket         [TICKET_WIDTH-1:0]
output <p>_req_wdata          [W-1:0]
output <p>_req_lane_en        [3:0]                  (LoMem only)
input  <p>_rsp_valid          input  <p>_rsp_ticket  [TICKET_WIDTH-1:0]
input  <p>_rsp_data           [W-1:0]
```

Requests are row-aligned, so a request carries a row index rather than
`{byte_address, byte_length}`; the byte address is `row * (W/8)` and the length
is one row. Reads may complete out of order: the requester matches
`rsp_ticket`, not arrival order. Writes are posted and are accounted complete
when the request is accepted. Up to `MEMORY_Q_DEPTH` reads may be outstanding
per port.

`mcore_memport` arbitrates the two requesters on each port — Fetch (reads) and
WB (scale reads, writes) — and routes responses by ticket bit
`ticket[TICKET_WIDTH-1]`: 0 = Fetch, 1 = WB. The low bits are the requester's
own tag. Fetch has priority; WB write traffic cannot be starved because Fetch
requests are bounded by its buffer credits.

## 14. Instruction to stage decomposition

Dispatch is atomic: an instruction issues only when every stage it needs
accepts in the same cycle.

| Instruction | Fetch | Compute | WB |
|---|---|---|---|
| `set_stream`, `li`, `addi`, `loop`, `endloop`, `jump`, `blt`, `bge` | – | – | – |
| `acc_reset` | – | `COMPUTE_RESET` | – |
| `load_accumulators` | `FETCH_ACC_LOAD` | `COMPUTE_LOAD_ACC` | – |
| `broadcast_mac` | `FETCH_BROADCAST` | `COMPUTE_MAC` | – |
| `multi_mac` | `FETCH_MULTI` | `COMPUTE_MAC` | – |
| `elementwise_add` | `FETCH_ELEMENTWISE` | `COMPUTE_MAC` | – |
| `elementwise_mul` | `FETCH_ELEMENTWISE` | `COMPUTE_MAC` | – |
| `reduce_accumulators` | – | `COMPUTE_SNAPSHOT` | `WB_REDUCE` |
| `scale_accumulators` | – | `COMPUTE_SNAPSHOT` | `WB_SCALE` |
| `write_accumulators` | – | `COMPUTE_SNAPSHOT` | `WB_WRITE_ACC` |
| `write_buf` | – | – | `WB_WRITE_BUF` |
| `halt` | – | – | – |

Both elementwise instructions map to `COMPUTE_MAC`: the operand packet already
carries the routed operands, so Compute does not distinguish them. WB owns the
scale-row reads for `scale_accumulators`, so that instruction needs no Fetch
command even though it reads memory.

## 15. Address generation

A stream cursor produces a logical index `q`:

```text
q = offset + outer_cursor * outer_stride + inner_cursor * inner_stride
```

`q` is then mapped to a physical row, and for 128-bit accesses in LoMem to one
of its four lanes. The unit of `q` is layout-specific:

| Layout | Domain | Unit of `q` | Row | Lane |
|---|---|---|---|---|
| `ROW_MAJOR` | CoMem | 128-bit line | `base_row + q` | – |
| `ROW_MAJOR` | LoMem | 128-bit line | `base_row + (q >> 2)` | `q[1:0]` |
| `ROW_MAJOR_FP32` | LoMem | 128-bit line | `base_row + (q >> 2)` | `q[1:0]` |
| `MATMUL_B` | LoMem | 512-bit row | `base_row + q` | all four |
| `MATMUL_B_INT8` | LoMem | 512-bit row | `base_row + q` | all four |

`multi_mac` and `scale_accumulators` read whole 512-bit rows through a
`ROW_MAJOR` LoMem stream; for them the unit of `q` is also a 512-bit row and no
lane select applies. This is the one case where the same layout is indexed in
two units, so it is a property of the consuming instruction, not of the layout.

Because CoMem is 128 bits wide, a CoMem operand that needs 512 bits is
assembled from four consecutive accesses (`q`, `q+1`, `q+2`, `q+3`), which is
how `broadcast_mac` reads A from CoMem.

`MATMUL_B` packing, with `k_chunks = ceil(Dk/8)`:

```text
LoMem[base_row + s*k_chunks + kc][lane l] = B[kc*8 .. kc*8+7, column + s*4 + l]
```

`MATMUL_B_INT8` packs two logical groups per physical lane, low bytes first:

```text
lane bytes[0:7]  = B[kc*8 .. kc*8+7, column + p*8 + l]        -> accumulator 2p
lane bytes[8:15] = B[kc*8 .. kc*8+7, column + p*8 + 4 + l]    -> accumulator 2p+1
```

Cursors advance once per access on consumption. The Command stage owns the
cursors and advances them at issue, so a queued command carries an immutable
view `{descriptor, inner_cursor, outer_cursor}` and later `set_stream` or
register writes cannot disturb work in flight. Multi-access commands advance by
their full access count; `broadcast_mac` and `multi_mac` consume their streams
to exhaustion (`inner_cursor = 0`, `outer_cursor = outer_count`).

Stream shape invariants the assembler must honour for `broadcast_mac`:

```text
A inner_count == 1                       (one A line reused across all groups)
A outer_count == B outer_count
B inner_count == ceil(valid_columns/4)                 for MATMUL_B
B inner_count == ceil(ceil(valid_columns/4)/2)         for MATMUL_B_INT8
```

## 16. Fetch micro-sequences

Fetch runs one command at a time, issuing reads as its buffer credits allow and
emitting operand packets in order. Reads are tagged, so a response can be
matched to the slot that wants it.

`FETCH_ACC_LOAD` — one 128-bit read; the four FP32 words become `preload[0..3]`
of a single packet with `accumulator_index = idx` and all lanes active.

`FETCH_BROADCAST` — two nested loops:

```text
for outer in 0 .. outer_count-1:
    read one 128-bit A line                       (LoMem lane or CoMem line)
    for s in 0 .. groups-1:
        read one 512-bit B row
        emit packet:
            lhs[lane][0..7] = A line               (broadcast, all lanes)
            rhs[lane][0..7] = B row lane
            accumulator_index = s
            active_lanes = tail mask of group s
```

`groups = ceil(valid_columns/4)`. The tail mask clears lanes whose column
`s*4 + lane >= valid_columns`. For `MATMUL_B_INT8` each B row yields two
packets: the low bytes of every lane converted from signed INT8 to BF16 with
`accumulator_index = 2*inner`, then the high bytes with `2*inner + 1`. The
second packet is suppressed when its whole group is beyond `valid_columns`.
A and B use independent `FETCH_BUFFER_DEPTH` prefetch queues, so B rows for the
next group can be in flight while the current packet is being consumed.

`FETCH_MULTI` — `rows = ceil(valid_elements/32)`; per row one 512-bit A read and
one 512-bit B read:

```text
lhs[lane][e] = A row lane element e
rhs[lane][e] = B row lane element e
accumulator_index = 0
```

Elements at or beyond `valid_elements` are replaced with BF16 zero in both
operands, which contributes an exact zero product; lanes with no valid element
are additionally masked out of `active_lanes`.

`FETCH_ELEMENTWISE` — `groups = ceil(valid_elements/4)`. One 128-bit A line and
one 128-bit B line hold eight elements each, so one pair of reads serves two
groups. For group `g`, lane `l` handles element `i = g*4 + l`:

```text
elementwise_mul: lhs[l][0] = A[i], rhs[l][0] = B[i]
elementwise_add: lhs[l][0] = A[i], rhs[l][0] = 1.0
                 lhs[l][1] = B[i], rhs[l][1] = 1.0
remaining multiplier slots are zeroed
accumulator_index = g
```

This is the `A×1 + B×1` / `A×B` routing of section 7.7 and adds no datapath.
Because the result lands in accumulator `g` through the accumulate adder, a
plain elementwise result requires `acc_reset` first; without it the operation is
a fused `acc += A op B`.

## 17. Compute micro-sequences

One `mcore_treemac` per lane, 16 FP32 accumulators each, global numbering
accumulator-major and lane-minor:

```text
global 0 = lane0.acc[0], 1 = lane1.acc[0], 2 = lane2.acc[0], 3 = lane3.acc[0]
global 4 = lane0.acc[1], ... global 63 = lane3.acc[15]
```

Per lane, one enabled cycle is:

```text
p[e]  = bf16_multiplier(lhs[e], rhs[e])          e = 0..7, exact FP32
tree  = normalize(reduce(align(p)))              one rounding to FP32
acc[i]= fp32_adder(acc[i], tree)                 i = accumulator_index
```

The alignment window is `16 + REDUCTION_GUARD_BITS` bits, so products more than
20 bits below the largest product in the same cycle are truncated. That is the
accepted precision of the existing verified TreeMAC, not a new choice.

Commands:

- `COMPUTE_RESET` — one cycle, `clear` on all lanes, all 64 accumulators to
  `+0`. Needs no operand packet.
- `COMPUTE_LOAD_ACC` — one packet; lane `l` writes `preload[l]` into
  `acc[accumulator_index]` through the bank write port. This overwrites, it does
  not accumulate.
- `COMPUTE_MAC` — consumes operand packets until the packet marked `last`
  arrives, one accumulate cycle per packet in every enabled lane. Compute never
  needs to know how many packets a command produces.
- `COMPUTE_SNAPSHOT` — no operand packets. Reads the bank in global order and
  rounds each FP32 to BF16 (round-to-nearest, ties-to-even, subnormal results
  flushed to zero), producing one result packet of 64 BF16 values with `count`
  valid. The bank is read combinationally, four lanes at a time, so the snapshot
  takes `ceil(count/4)` cycles. The live bank is free to advance as soon as the
  packet is accepted.

`COMPUTE_MAC` and `COMPUTE_SNAPSHOT` for different instructions never overlap:
there is at most one active operation in the stage.

## 18. Writeback micro-sequences

WB consumes one result packet per command that has one, and owns all stores.

`WB_WRITE_ACC` — `lines = ceil(count/8)`; per line, pack eight BF16 values
little-endian, zero-fill the tail of the last line, and issue one store to the
stream address for that line.

`WB_REDUCE` — `sum = values[0]`, then one `bf16_add(sum, values[i])` per cycle
for `i = 1 .. count-1`. `count = 1` copies the single value. The result goes to
output buffer slot `buffer_idx` and sets its valid bit. This is `count-1`
cycles of a single BF16 adder; Compute is not blocked meanwhile.

`WB_SCALE` — per block of 32 values: read one 512-bit scale row into the
32-entry scale buffer, then one `bf16_mul(value[i], scale[i])` per cycle,
emitting a store every time eight scaled values are packed. The final line is
zero-padded. Blocks repeat until `count` values are scaled, so `ceil(count/32)`
scale rows are read.

`WB_WRITE_BUF` — waits until no reduction is in flight, packs the eight output
buffer slots into one 128-bit line (invalid slots emit BF16 `+0`), issues one
store, then clears all values and valid bits.

WB is done with a command when its last store has been accepted by the memory
port.

## 19. Sequencing and dependencies

Every issued instruction gets a nonzero sequence ID from a wrapping counter
(`SEQ_WIDTH` bits, value 0 reserved). Stage commands and both packet types
carry it. A consumer compares the sequence of the packet at the head of its
data FIFO with the sequence of its current command; a mismatch is a design
error, so the packet is not consumed and an assertion fires. This makes
misordering visible instead of silently corrupting a result.

Range reservations live in the Command stage: a `RESERVATIONS`-entry table of
`{valid, seq, domain, is_write, row_low, row_high, owner}`. At issue, an
instruction reserves one entry per memory range it will touch, computed from
the captured stream view:

```text
row_low  = row(q_first)
row_high = row(q_last)                q_last = q of the final access
```

Ranges are conservative at row granularity: LoMem lane masking is ignored, so
two 128-bit accesses in the same physical row conflict. Conflict rules:

```text
new read  conflicts with an older write to an overlapping range, same domain
new write conflicts with an older read  to an overlapping range, same domain
write-write is ordered by the WB stage FIFO and does not conflict
```

On conflict the instruction does not issue and the PC does not advance, so it
retries next cycle. Entries are freed when the owning stage reports completion
of that sequence (`fetch_done_seq`, `wb_done_seq`). A full table also stalls
issue. Queue-full stalls are structural; conflicts and table-full are data
dependencies, and the distinction is visible on separate status outputs so the
testbench can tell why the core stalled.

`halt` stops issue and enters drain. `done` asserts only when the command FIFOs
are empty, all three stage FSMs are idle, the operand and result FIFOs are
empty, no memory read is outstanding, every store has been accepted, and the
reservation table is empty.

## 20. Error conditions

A sticky `error` output is raised at issue, and the core stops issuing, for:

```text
undefined or invalid stream slot; stream id >= STREAM_SLOTS
read of an uninitialized integer register
inner_count <= 0 or outer_count <= 0 in set_stream
count == 0, or count > 64 (> 32 elements per row for multi_mac is legal:
    count is elements, up to 64)
accumulator index >= 16
buffer_idx >= 8
domain or layout unsupported by the instruction:
    load_accumulators   requires LoMem ROW_MAJOR_FP32
    broadcast_mac B     requires LoMem MATMUL_B or MATMUL_B_INT8
    multi_mac A and B   require LoMem ROW_MAJOR
    scale_accumulators  scales require LoMem ROW_MAJOR
    write targets       require ROW_MAJOR in either domain
endloop with an empty loop stack; loop with a full loop stack
```

Stream exhaustion is not checked in hardware; it is an assembler
responsibility, as are the shape invariants of section 15.

## 21. Assumptions and deviations

1. **Request/response instead of ticketed byte ranges.** Section 2 describes
   `{domain, read/write, byte_address, byte_length}`. All accesses are
   row-aligned and one row long, so the port carries a row index. Tickets are
   kept because they are what routes a response back to Fetch or WB.
2. **`DATA_Q_DEPTH = 2`, not 1.** A depth-1 FIFO would serialize Fetch and
   Compute into lockstep and lose the run-ahead the pipeline exists for. Depth
   is a parameter; 1 still functions.
3. **`STREAM_SLOTS = 4`** per section 1, with a 3-bit encoding field so 8 slots
   need no encoding change. Slots `>= STREAM_SLOTS` are an error.
4. **Reduction arithmetic is block floating point.** Section 4 says the TreeMAC
   uses "FP32 intermediate arithmetic". This implementation reduces exact
   product significands under a shared exponent and rounds once, which is the
   existing verified TreeMAC and is at least as accurate as a rounded-at-every-
   node FP32 tree, but it is not bit-identical to one. Products more than
   `16 + REDUCTION_GUARD_BITS` bits below the cycle's largest product are
   truncated.
5. **Subnormals are flushed to zero** everywhere, and BF16 rounding is
   round-to-nearest ties-to-even, inherited from the reused arithmetic.
6. **Elementwise operations accumulate.** Section 7.7 specifies the multiplier
   routing but not whether the accumulator is overwritten. Reusing the MAC
   datapath means accumulating, so `acc_reset` is required for pure elementwise
   semantics.
7. **`elementwise_*` and `multi_mac` `count` is an element count** in `[1,64]`;
   `multi_mac` spreads it across `ceil(count/32)` row pairs.
8. **One instruction issues per cycle at most**, and multi-word `set_stream`
   takes four command cycles.
9. **A new program does not clear accumulators.** Reset clears everything;
   `start` clears PC, register valid bits, stream valid bits and the loop
   stack, but software must issue `acc_reset` or `load_accumulators`.
10. **`flush`** aborts: it clears every FIFO, stage FSM and buffer, but not the
    accumulators or the integer registers. Outstanding memory responses are
    dropped by ticket mismatch.

## 22. Verification

`tb/mcore_tb.sv` drives the top level with behavioral LoMem and CoMem models
(three-cycle read latency, optionally out-of-order response return) and programs
written with the `mcore_prog_pkg` assembler. Everything is checked from outside
the core - memory contents, `done`, `error`, the stall outputs - so the tests
constrain behavior rather than implementation.

Run it with `make test-mcore`. `MCORE_ARGS='+only=<group>'` runs one group
(`ctrl`, `acc`, `bcast`, `int8`, `multi`, `ew`, `buf`, `scale`, `dep`),
`'+trace'` logs every stage dispatch and completion, and `make
test-mcore-reorder` re-runs the whole suite with read responses returned out of
order so the ticket matching of section 13 is exercised. Both orderings pass 352
checks.

The items below are implemented and passing. Arithmetic is compared against a
`real` reference at 2% relative tolerance, with stimulus chosen to be exactly
representable in BF16 so the only error is the prescribed rounding.

Control:

1. Reset state: PC 0, `!done`, `!error`, no stage command valid.
2. `li`/`addi` including signed wraparound at `0x7fffffff`.
3. Nested `loop`/`endloop` trip counts; `loop 0` skips the body including a
   four-word `set_stream`; `loop` with a register count.
4. `jump` forward and backward; `blt`/`bge` taken and not taken.
5. `set_stream` field capture, derived `outer_stride`, cursor clear, and a
   register-sourced field resolved at execute time.
6. Uninitialized register read, bad stream, bad `count`, bad layout and
   `endloop` underflow each set `error`.

Dataflow and dependencies:

7. Every program ends in `halt` and every test waits for `done`, so the drain
   rule is checked once per program: `done` only after the last store is
   accepted and the reservation table is empty. A program that fails to drain
   dumps all stage states, which is how the one real bug found during bring-up
   was localized (Fetch derived its iteration counts from the command channel
   instead of the latched command, so they went stale as soon as the command was
   accepted and the last-packet condition never fired).
8. Range conflict: two `elementwise_add`/`write_accumulators` passes where the
   second reads exactly the rows the first writes. The core reports a dependency
   stall - not a structural one - while it waits, and the second pass reads
   post-write data.
9. Out-of-order read responses (`+mem_reorder`): the whole suite passes with
   responses returned in reverse arrival order, so nothing depends on read
   completion order.

Arithmetic:

10. `acc_reset` then `write_accumulators 64` writes 64 BF16 zeros.
11. `load_accumulators` preloads four FP32 values into one accumulator index of
    all four lanes, visible through `write_accumulators`, leaving the other
    accumulators zero.
12. GEMV via `broadcast_mac` with `valid_columns` of 1, 4, 5, 13 and 64, A from
    LoMem and from CoMem. Checks accumulator mapping, column-group ordering,
    tail lane masking and A reuse across groups.
13. `MATMUL_B_INT8` GEMV with `valid_columns` of 5, 12 and 64, covering both
    byte halves, INT8-to-BF16 conversion of negative values, and an odd group
    count where the high half of the last row is never fetched.
14. `multi_mac` dot products for 8, 21, 32 and 64 elements, checking that the
    four lane partial sums land in the four `acc[0]` copies and that tail
    elements are zeroed.
15. `elementwise_add` and `elementwise_mul` for 1, 7 and 64 elements after
    `acc_reset`.
16. `reduce_accumulators` for `count` 8 and 1, checked against the same
    sequential BF16 add order, into two buffer slots; then `write_buf` emits
    zeros for the six unset slots.
17. `scale_accumulators` for `count` 12 into CoMem, checking the scale-row read,
    the per-value BF16 multiply and zero padding of the final line.

Not yet covered, in rough priority order: backpressure with a stage held not
ready and the atomic-dispatch case where only one of two stages would accept;
issue-time capture against a later `set_stream` to the same slot; `count` over
32 for `scale_accumulators`, which is where the second scale row and the
`SCALE_BUFFER_ENTRIES` wrap are exercised; a loop-driven tiled GEMM over
multiple A rows and output tiles; `flush` mid-command; and the reservation table
running full.
