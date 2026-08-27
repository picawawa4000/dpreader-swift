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

LLVM has the best steady-state native throughput, but its JIT setup is much more expensive for the
large fused climate-and-search program. Prefer it for a long-lived service which will render
thousands of tiles with each shape and stride. DPReader uses LLVM's O1 pipeline for this fused bulk
program: in this workload it substantially reduces setup time and performs better than the much
slower-to-compile O3 pipeline.

Use ``WorldGenerator/generateBiomesInSquare(from:to:atY:in:scale:forceNoBaking:forceBaking:)``
without compilation as a correctness reference or for occasional small queries. For exact 1:1
pixels, use `forceNoBaking: true`. World-scale baking may quantize flat-cache inputs to their
quart-column sampling positions, which is useful for quart-aligned generation but is not exact
per-block sampling.

## Reference Workload

`benchmarkRealWorldBiomeTileGeneration` renders an 8-by-8 tile square centered on `(0, 0)` with
seed `987654321` at each scale above. Each level contains 262,144 samples and all backends must
produce the same palette-ID checksum. The bounds are `-4 * tileSide ..< 4 * tileSide` on both axes.

One debug build on Apple Silicon produced these representative results after the reusable-output
and LLVM-pipeline optimizations. Treat them as comparative measurements, not portable guarantees.

| Level | Direct Swift | WASM in Node | LLVM | WASM compile | LLVM compile |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64-block tiles, 1:1 | 17.80 s | 287 ms | 125 ms | 44 ms | 14.13 s |
| 256-block tiles, 1:4 | 17.91 s | 284 ms | 132 ms | 43 ms | 15.00 s |
| 1,024-block tiles, 1:16 | 16.72 s | 300 ms | 130 ms | 43 ms | 16.32 s |

At these rates, LLVM's setup cost breaks even with WASM only after roughly six thousand tiles per
shape. To reproduce the portable paths, run:

```shell
swift test --filter benchmarkRealWorldBiomeTileGeneration
```

To include LLVM when Homebrew LLVM is installed, run:

```shell
DPREADER_ENABLE_LLVM=1 swift test --filter benchmarkRealWorldBiomeTileGeneration
```

