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

## Profiling Helpers

These are just helpers for profiling the compiled density functions.

- ``BufferedDensityFunctionProfilingState``
- ``BufferedDensityFunctionCompilationOptions``
- ``BufferedDensityFunctionProfilingEvent``
- ``BufferedDensityFunctionProfilingFunction``
- ``BufferedDensityFunctionProfilingNode``
- ``BufferedDensityFunctionProfilingReport``
