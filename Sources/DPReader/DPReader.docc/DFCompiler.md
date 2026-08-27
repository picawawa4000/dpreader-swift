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
