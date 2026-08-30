# Biome Tile Generation

Generate fixed-resolution biome tiles efficiently for maps and other level-of-detail renderers.

## Use a Fixed Output Shape

Represent a map tile by its output pixel count and put the level of detail in the buffer stride.
All of these configurations produce a 64-by-64 biome-ID tile:

| World-space tile | Scale | Buffer context |
| --- | --- | --- |
| 64 by 64 blocks | 1:1 | `xCount: 64, zCount: 64, xStep: 1, zStep: 1` |
| 256 by 256 blocks | 1:4 | `xCount: 64, zCount: 64, xStep: 4, zStep: 4` |
| 1,024 by 1,024 blocks | 1:16 | `xCount: 64, zCount: 64, xStep: 16, zStep: 16` |

Create one ``CompiledNoiseRouterBiomeBulkSampler`` for each distinct shape and stride, retain it,
and move it around the world by changing only the base position. Compilation includes all six
climate functions and biome-tree selection in one program, so each tile crosses the backend
boundary once.

```swift
let scale: Int32 = 4
let context = CompiledDensityFunctionBufferContext(
    xCount: 64,
    yCount: 1,
    zCount: 64,
    xStep: scale,
    zStep: scale
)
let sampler = try generator.makeBiomeIDBulkSampler(
    for: context,
    in: RegistryKey(referencing: "minecraft:overworld"),
    strategy: .wasm
)

var biomeIDs = [Int32](repeating: 0, count: context.sampleCount)
biomeIDs.withUnsafeMutableBufferPointer { output in
    sampler.fill(at: PosInt3D(x: tileX, y: 256, z: tileZ), into: output)
}

// biomeIDs are in z/x/y order.
let firstBiome = sampler.palette[Int(biomeIDs[0])]
```

Use ``CompiledNoiseRouterBiomeBulkSampler/fill(at:into:)`` in a tile loop so the output allocation
is reused. Use ``CompiledNoiseRouterBiomeBulkSampler/callAsFunction(at:)`` when ownership of a new
``CompiledBiomeIDVolume`` is more convenient. A retained sampler is updated in place when
``WorldGenerator/setWorldSeed(_:)`` changes the seed.

## Choose a Backend

WebAssembly is the best default for interactive and portable tile generation. Module compilation
is quick, its steady-state throughput is far above direct Swift sampling, and the same module can
run in a browser or Node. Calling a `.wasm` sampler from native Swift without a ``WASMRuntime`` uses
the IR fallback; provide a runtime to execute WASM in-process, or deploy
``CompiledNoiseRouterBiomeBulkSampler/wasmModule`` to a WebAssembly host.

LLVM can be the faster native backend for final-density terrain, whose generation-cell bulk path
reuses interpolation work. It is not automatically faster for this biome workload: its scalar
fused climate-and-search loop is substantially slower than the paired-SIMD WASM module in Node.
LLVM JIT setup is also much more expensive because every shape and stride builds, optimizes, and
machine-compiles a complete six-climate-function-plus-biome-tree module. DPReader uses LLVM's O1
pipeline for this fused bulk program; it avoids the still slower-to-compile O3 pipeline.
For horizontal power-of-two map tiles, the LLVM loop specializes coordinate recovery to a mask and
shift, avoiding the per-sample 64-bit division and remainder operations of the generic 3D path.
It still uses a small parallel split because each scalar climate sample is expensive enough to
amortize that work.

Use ``WorldGenerator/generateBiomesInSquare(from:to:atY:in:scale:forceNoBaking:forceBaking:)``
without compilation as a correctness reference or for occasional small queries. For exact 1:1
pixels, use `forceNoBaking: true`. World-scale baking may quantize flat-cache inputs to their
quart-column sampling positions, which is useful for quart-aligned generation but is not exact
per-block sampling.

## Reference Workload

`benchmarkRealWorldBiomeTileGeneration` renders an 8-by-8 tile square centered on `(0, 0)` with
seed `987654321` at each scale above. Each level contains 262,144 samples and all backends must
produce the same palette-ID checksum. The bounds are `-4 * tileSide ..< 4 * tileSide` on both axes.

### What the Test Actually Does

`benchmarkRealWorldBiomeTileGeneration` loads the checked-in `vanilla/1.21.11` data pack and
constructs one overworld generator and one structure-placement sampler with world seed
`987654321`. For each workload it creates a 64-by-64 output context (`yCount == 1`) and 64 tile
origins, beginning at `(-4 * tileSide, 256, -4 * tileSide)` and advancing in Z-major, then X,
order. The output index order is Z/X/Y, so each result is converted to a palette index and folded
into a 32-bit FNV-1a hash (initial value `2166136261`).

The direct Swift loop is timed after one untimed reference call. It generates each square with
`forceNoBaking: true`, checks the expected sample count, and records the 1:1 results in the exact
X/Y/Z biome cache. The WASM sampler is emitted once per context; Node then reads each module,
constructs its instance, and makes one untimed warm-up call before timing all 64 tiles. The LLVM
sampler is likewise created once per context and warmed by `fill` before its timed loop. Module
emission, Node compilation/instantiation, LLVM optimization/JIT, and warm-up are reported as
setup but are not included in backend tile-generation times. Both compiled hashes must equal the
direct Swift hash.

After the biome loops, the same 8-by-8 world extent is used to enumerate eligible structure-set
placements. The structure portion measures placement resolution plus lightweight biome and
heightmap start validation only; it does not generate structure pieces, blocks, chunks, or loot.
Its diagnostics report candidate/valid counts, callback time and sample counts, terrain-cache
hits/misses, and the five slowest structure sets.

The benchmark also samples and validates structure starts in the complete 8-by-8 tile extent.
The efficient code flow is to cache dimension eligibility and seed-stable concentric-ring
placements once, discard structure sets that cannot generate in the requested dimension, merge
adjacent tile bounds, enumerate each intersecting placement region once, and then perform biome
and terrain start validation on each candidate. Valid starts can be bucketed back into tiles when
the caller needs per-tile results. This avoids walking every chunk, repeating placement regions at
tile boundaries, and generating candidates only to reject them for belonging to another dimension.
For terrain validation, retain a small working set of per-chunk height evaluators and cache the
vertical density columns at generation-cell corners. Nearby center and footprint heights can then
share both the baked density tree and interpolation inputs without generating a complete chunk.
When the generated `WORLD_SURFACE_WG` is guaranteed to include sea-level fluid, omit footprint
checks whose only condition is that this height reaches sea level; the condition is already true.
For generated noise terrain, sample the height before testing the final biome rather than scanning
every quart Y in a candidate column: start validity depends on the biome at the final generation
position, and the exact check remains in place there.
The benchmark prints biome and terrain callback time, their sample counts, and the slowest
structure sets so that a change in validation ordering does not hide a newly dominant phase.
It shares an exact-position biome cache with the generated 1:1 map tiles and then with structure
validation. A cached map biome is used only when its X, Y, and Z all match the structure query;
surface-height validation normally uses another Y, so the cache intentionally falls back rather
than treating biomes as two-dimensional.
Piece graphs, structure blocks, and loot stay deferred until a caller requests them.

One debug build on Apple Silicon produced these representative steady-state results after the
reusable-output and LLVM-pipeline optimizations. Compilation/setup is outside the timed
tile-generation loops and is printed separately by the benchmark and recorded below. Treat them
as comparative measurements, not portable guarantees.

| Level | Direct Swift | WASM in Node | LLVM |
| --- | ---: | ---: | ---: |
| 64-block tiles, 1:1 | 19.06 s | 274 ms | 2.32 s |
| 256-block tiles, 1:4 | 18.99 s | 279 ms | 2.38 s |
| 1,024-block tiles, 1:16 | 17.39 s | 297 ms | 2.48 s |

| Level | WASM Swift emission | Node compile/init/warm-up | LLVM JIT setup |
| --- | ---: | ---: | ---: |
| 64-block tiles, 1:1 | 46 ms | 14 ms | 14.33 s |
| 256-block tiles, 1:4 | 47 ms | 10 ms | 14.85 s |
| 1,024-block tiles, 1:16 | 48 ms | 11 ms | 13.73 s |

To reproduce the portable paths, run:

```shell
USE_TEST_VISIBLE=1 swift test --filter benchmarkRealWorldBiomeTileGeneration
```

To include LLVM when Homebrew LLVM is installed, run:

```shell
USE_TEST_VISIBLE=1 DPREADER_ENABLE_LLVM=1 swift test --filter benchmarkRealWorldBiomeTileGeneration
```
