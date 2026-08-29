# Density Function Compiler

DPReader's JIT compiler for density functions.

DPReader contains a runtime compiler for density functions that can be used to compile density functions to a faster executable format. Currently, there is an LLVM backend and a WebAssembly backend. More backends may be added in the future. There is also a compiler for biome search trees.

## Topics

### Compiled Types

- ``CompiledBiomeSearchTree``
- ``CompiledDensityFunction``
- ``CompiledDensityFunctionBulk``
- ``CompiledClimateBiomeBulkSampler``
- ``CompiledDensityFunctionBulkProgram``
- ``CompiledNoiseRouterBiomeBulkSampler``

### General Helpers

- ``CompiledBiomeIDVolume``
- ``CompiledDensityFunctionBuffer``
- ``CompiledDensityFunctionBufferContext``
- ``CompiledDensityFunctionBulkEvaluationContext``
- ``CompilationBackend``
- ``DensityFunctionCompilationError``
- ``DensityFunctionCellSize``
- ``DensityFunctionCellVolume``

### WebAssembly Helpers

- ``WASMRuntime``
- ``ClosureWASMRuntime``
- ``WASMBiomeIDBulkInvocation``
- ``WASMBiomeSearchInvocation``
- ``WASMClimateInvocation``
- ``WASMDensityFunctionBulkInvocation``
- ``WASMDensityFunctionInvocation``
- ``WASMClimateSample``
- ``WASMDensityFunctionImports``

### Compilers

- ``compile(biomeSearchTree:strategy:useAlternativeNode:runtime:)``
- ``compile(densityFunction:bufferContext:strategy:registry:options:runtime:)``
- ``compile(densityFunction:cellSize:cellVolume:strategy:registry:)``
- ``compile(densityFunction:strategy:registry:runtime:)``
- ``compile(noiseRouter:biomeSearchTree:bufferContext:strategy:useAlternativeNode:registry:runtime:)``

### Chunk terrain compilation

``WorldGenerator`` uses the buffered density-function compiler for final-density terrain when a
compilation backend is configured. The scalar compiled-function registry remains for individual
point consumers such as climate sampling. Terrain has its own lazy, context-keyed compiled-function
registry: each entry is compiled for the complete generation-cell corner lattice of a chunk—the
exact set of final-density values vanilla evaluates before interpolation—so one buffer invocation
supplies the whole chunk. Entries are reused for matching chunk shapes and rebuilt when the world
seed changes. If a configured backend cannot compile a density tree, terrain automatically retains
the interpreted path.

### Reseeding compiled graphs

Generator-owned compiled density functions keep seed-independent code separate from mutable
sampler state. ``WorldGenerator/setWorldSeed(_:)`` replaces Double Perlin permutations and origins
inside stable, lock-protected noise objects and also refreshes the shared End-simplex and legacy
interpolated-noise state. Compiled-function registries, biome search trees, and retained bulk
samplers keep their identity; LLVM JIT modules and in-process WASM instances are not rebuilt.

LLVM accesses generator-owned noises through their stable shared state. When a ``WASMRuntime`` is
attached, generated modules import the same mutable noise state from the host, so an existing
instance immediately observes a new seed. A standalone `wasmModule` emitted without a runtime
remains self-contained and therefore represents the seed at module-generation time; the native
Swift fallback attached to its compiled sampler still follows ``WorldGenerator/setWorldSeed(_:)``.

Direct calls to the compiler with an independently constructed ``BakedNoise`` continue embedding
an immutable snapshot. This preserves self-contained deployable WASM and fully embedded LLVM for
callers that do not need reseeding.

### Tile-based biome generation

- <doc:BiomeTileGeneration>

## Profiling Helpers

These are just helpers for profiling the compiled density functions.

- ``BufferedDensityFunctionProfilingState``
- ``BufferedDensityFunctionCompilationOptions``
- ``BufferedDensityFunctionProfilingEvent``
- ``BufferedDensityFunctionProfilingFunction``
- ``BufferedDensityFunctionProfilingNode``
- ``BufferedDensityFunctionProfilingReport``
