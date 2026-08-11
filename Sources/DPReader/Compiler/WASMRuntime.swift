/// The host callbacks imported by a compiled density-function WASM module.
/// A browser implementation should expose these under the module name `dpreader` as
/// `sample_density` and `sample_noise`, respectively.
public struct WASMDensityFunctionImports: Sendable {
    public let sampleDensity: @Sendable (Int32, Int32, Int32, Int32) -> Double
    public let sampleNoise: @Sendable (Int32, Double, Double, Double) -> Double

    public init(
        sampleDensity: @escaping @Sendable (Int32, Int32, Int32, Int32) -> Double,
        sampleNoise: @escaping @Sendable (Int32, Double, Double, Double) -> Double
    ) {
        self.sampleDensity = sampleDensity
        self.sampleNoise = sampleNoise
    }
}

public typealias WASMDensityFunctionInvocation = @Sendable (Int32, Int32, Int32) -> Double
public typealias WASMBiomeSearchInvocation = @Sendable (
    Double, Double, Double, Double, Double, Double
) -> Int32

/// Instantiates emitted WASM with the embedding environment's WebAssembly engine.
///
/// WASI supplies system interfaces, but does not itself define a nested-module instantiation API.
/// Browser clients can implement this protocol using `WebAssembly.Module`/`WebAssembly.Instance`;
/// other embeddings can use their resident engine (for example Wasmtime or Wasmer).
public protocol WASMRuntime: Sendable {
    /// Instantiates a module exporting `sample(i32, i32, i32) -> f64`.
    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation

    /// Instantiates a module exporting `search(f64, f64, f64, f64, f64, f64) -> i32`.
    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation
}

/// A convenience runtime adapter for browser or embedding bridges implemented with closures.
public struct ClosureWASMRuntime: WASMRuntime {
    public typealias DensityFunctionInstantiator = @Sendable (
        [UInt8], String, WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation
    public typealias BiomeSearchInstantiator = @Sendable (
        [UInt8], String
    ) throws -> WASMBiomeSearchInvocation

    private let densityFunctionInstantiator: DensityFunctionInstantiator
    private let biomeSearchInstantiator: BiomeSearchInstantiator

    public init(
        instantiateDensityFunction: @escaping DensityFunctionInstantiator,
        instantiateBiomeSearch: @escaping BiomeSearchInstantiator
    ) {
        self.densityFunctionInstantiator = instantiateDensityFunction
        self.biomeSearchInstantiator = instantiateBiomeSearch
    }

    public func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        try self.densityFunctionInstantiator(module, exportName, imports)
    }

    public func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        try self.biomeSearchInstantiator(module, exportName)
    }
}
