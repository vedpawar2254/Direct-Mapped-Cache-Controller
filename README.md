# Direct-Mapped Cache Controller

Verilog RTL + testbench for a **direct-mapped, read-only cache** with a
behavioral main-memory model. Simulates four access patterns and reports
hit/miss statistics and AMAT.

## Configuration

| Parameter   | Value        |
|-------------|--------------|
| Cache size  | 1 KB (1024 B)|
| Block size  | 16 bytes     |
| Lines       | 64           |
| Address     | 32-bit       |
| Mapping     | Direct-mapped|
| Policy      | Read-only, allocate-on-miss |

### Address breakdown (32-bit)

```
| 31 ........... 10 | 9 ..... 4 | 3 ..... 0 |
|      TAG (22)     | INDEX (6) | OFFSET(4) |
```

- **OFFSET** = log2(16) = **4 bits**  → byte within a 16-byte block
- **INDEX**  = log2(64) = **6 bits**  → which of 64 cache lines
- **TAG**    = 32 - 6 - 4 = **22 bits** → remaining high bits

## Modules

| File | Module | Role |
|------|--------|------|
| `rtl/cache_defs.vh`       | (macros) | Shared parameters + address field slices |
| `rtl/main_memory.v`       | `main_memory` | Slow backing store, `MEM_LATENCY`-cycle block fetch |
| `rtl/cache_controller.v`  | `cache_controller` | Tag/Valid/Data RAM, decoder, comparator, FSM, stats |
| `tb/tb_cache.v`           | `tb_cache` | Trace generation + hit/miss/AMAT reporting |

### Controller FSM

```
IDLE ──cpu_req──► COMPARE ──hit──► (return word) ──► IDLE
                     │
                    miss
                     ▼
                 ALLOCATE ──mem_ready──► (refill line, return word) ──► IDLE
```

On a **hit** (valid bit set AND tag matches) the requested 32-bit word is
selected from the stored 128-bit block. On a **miss** the controller fetches
the whole block from main memory, writes it into the data RAM, sets the tag
and valid bit, then returns the word.

## Metrics

- **Hit ratio**  = hits / accesses
- **Miss ratio** = misses / accesses
- **AMAT** = `HIT_TIME + miss_ratio × MISS_PENALTY`
  (testbench uses HIT_TIME = 1 cycle, MISS_PENALTY = 10 cycles)

## Run

Requires [Icarus Verilog](http://iverilog.icarus.com/):

```bash
brew install icarus-verilog     # macOS
./run.sh
```

Optional waveform:

```bash
gtkwave cache.vcd
```

## Waveform

First few accesses, captured from `cache.vcd` (sequential walk of `0x0, 0x4,
0x8, 0xC, 0x10`):

![Cache waveform](docs/waveform.png)

- `0x0` is a **cold miss**: FSM goes `COMPARE → ALLOC`, `mem_req` pulses, and
  after the memory latency `mem_ready` returns the block → `cpu_ready` + miss
  counted.
- `0x4`, `0x8`, `0xC` land in the **same 16-byte block** just refilled →
  `hit_flag` asserts immediately in `COMPARE`, no memory access. This is
  spatial locality visible on the wire.

Regenerate with: `./run.sh && python3 tools/plot_wave.py cache.vcd docs/waveform.png`
(or open `cache.vcd` in GTKWave).

## Results

| Phase       | Accesses | Hits | Misses | Hit ratio | Miss ratio | AMAT (cyc) | Behavior tested      |
|-------------|----------|------|--------|-----------|------------|------------|----------------------|
| SEQUENTIAL  | 64       | 48   | 16     | 0.750     | 0.250      | 3.500      | Spatial locality     |
| REPEATED    | 40       | 36   | 4      | 0.900     | 0.100      | 2.000      | Temporal locality    |
| RANDOM      | 200      | 2    | 198    | 0.010     | 0.990      | 10.900     | Poor locality        |
| CONFLICT    | 4        | 0    | 4      | 0.000     | 1.000      | 11.000     | Same-index eviction  |
| **Overall** | 308      | 86   | 222    | 0.279     | 0.721      | 8.208      | —                    |

**Reading the results**

- **Sequential** → 4 words share one 16-byte block, so 1 cold miss then 3
  hits per block = 75%. Demonstrates **spatial locality** via block fetch.
- **Repeated** → 4 cold misses, then the tiny working set stays resident =
  90%. Demonstrates **temporal locality**.
- **Random** → addresses scatter across 64 KB with no reuse, so nearly every
  access is a conflict/cold miss. Shows a cache gives no benefit without
  locality (AMAT ≈ raw miss penalty).
- **Conflict** → `0x000` and `0x400` are 1024 bytes apart and map to index 0
  with different tags. Alternating between them evicts the previous block,
  so both revisits miss even though the workload reuses just two blocks.

## Deliverables mapping

| Required deliverable | Where |
|----------------------|-------|
| Cache RTL            | `rtl/cache_controller.v`, `rtl/main_memory.v` |
| Controller FSM       | FSM in `cache_controller.v` (IDLE/COMPARE/ALLOCATE) |
| Memory-access trace  | Generated in `tb/tb_cache.v` (sequential/repeated/random/conflict) |
| Hit/miss report      | Simulation stdout (table above) |
| AMAT calculation     | `tb/tb_cache.v` `phase_report` task |
| Synthesis results    | See *Synthesis* below |

## Synthesis

The RTL is synthesizable (static array indices, no `$`-functions in the DUT).
With [Yosys](https://yosyshq.net/yosys/):

```bash
yosys -q -p "read_verilog -I rtl rtl/cache_controller.v; \
             synth -top cache_controller; stat"
```

### Results (Yosys 0.71, generic gate mapping)

| Metric            | Count  |
|-------------------|--------|
| Cells (total)     | 30,237 |
| Flip-flops (DFF)  | 9,862  |
| AND / ANDNOT      | 14,796 |
| NOR               | 4,788  |
| MUX               | 85     |
| Wires             | 20,321 |
| Public wire bits  | 10,094 |

**FF sanity check:** cache storage = 64 lines × (22 tag + 1 valid + 128 data)
= 64 × 151 = **9,664 bits**, plus FSM / stat / request registers ≈ **9,862** —
matches the DFF count. Most of the area is the cache array.

Yosys warns `Replacing memory with list of registers` for `tag_ram`,
`valid_ram`, `data_ram`: in a generic flow the arrays become flip-flops. On an
FPGA/ASIC these map to **block RAM**, collapsing the gate count dramatically.
For real NAND2-equivalent area, map to a standard-cell library (`abc` +
liberty file); for FPGA timing, push the same RTL through Vivado/Quartus and
read the post-synthesis timing summary.
