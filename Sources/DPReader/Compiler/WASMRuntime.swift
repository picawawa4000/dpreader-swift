/// Fallback host callbacks imported by a compiled density-function WASM module.
/// Baked Double Perlin noise is embedded in the module and does not use `sample_noise`; that import
/// is retained for custom `DensityFunctionNoise` implementations. A browser implementation should
/// expose callbacks requested by `WebAssembly.Module.imports` under the module name `dpreader`.
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
public struct WASMClimateSample: Sendable, Equatable {
    public let temperature: Double
    public let humidity: Double
    public let continentalness: Double
    public let erosion: Double
    public let weirdness: Double
    public let depth: Double

    public init(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.continentalness = continentalness
        self.erosion = erosion
        self.weirdness = weirdness
        self.depth = depth
    }
}

public typealias WASMClimateInvocation = @Sendable (Int32, Int32, Int32) -> WASMClimateSample
public typealias WASMBiomeSearchInvocation = @Sendable (
    Double, Double, Double, Double, Double, Double
) -> Int32

/// Instantiates emitted WASM with the embedding environment's WebAssembly engine.
///
/// WASI supplies system interfaces, but does not itself define a nested-module instantiation API.
/// Browser clients can implement this protocol using `WebAssembly.Module`/`WebAssembly.Instance`;
/// other embeddings can use their resident engine (for example Wasmtime or Wasmer).
public protocol WASMRuntime: Sendable {
    /// Whether this runtime supports a six-result climate export. Browser WebAssembly engines support
    /// multi-value returns; declaring support lets world generation use one boundary crossing per point.
    var supportsClimateFunctions: Bool { get }

    /// Instantiates a module exporting `sample(i32, i32, i32) -> f64`.
    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation

    /// Instantiates `sample_climate(i32, i32, i32) -> (f64, f64, f64, f64, f64, f64)`.
    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation

    /// Instantiates a module exporting `search(f64, f64, f64, f64, f64, f64) -> i32`.
    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation
}

public extension WASMRuntime {
    var supportsClimateFunctions: Bool { false }

    func instantiateClimateFunctions(
        module _: [UInt8],
        exportName _: String,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        throw DensityFunctionCompilationError.wasmRuntimeUnavailable
    }
}

/// A convenience runtime adapter for browser or embedding bridges implemented with closures.
public struct ClosureWASMRuntime: WASMRuntime {
    public typealias DensityFunctionInstantiator = @Sendable (
        [UInt8], String, WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation
    public typealias BiomeSearchInstantiator = @Sendable (
        [UInt8], String
    ) throws -> WASMBiomeSearchInvocation
    public typealias ClimateFunctionInstantiator = @Sendable (
        [UInt8], String, WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation

    private let densityFunctionInstantiator: DensityFunctionInstantiator
    private let biomeSearchInstantiator: BiomeSearchInstantiator
    private let climateFunctionInstantiator: ClimateFunctionInstantiator?

    public var supportsClimateFunctions: Bool { self.climateFunctionInstantiator != nil }

    public init(
        instantiateDensityFunction: @escaping DensityFunctionInstantiator,
        instantiateBiomeSearch: @escaping BiomeSearchInstantiator,
        instantiateClimateFunctions: ClimateFunctionInstantiator? = nil
    ) {
        self.densityFunctionInstantiator = instantiateDensityFunction
        self.biomeSearchInstantiator = instantiateBiomeSearch
        self.climateFunctionInstantiator = instantiateClimateFunctions
    }

    public func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        guard let climateFunctionInstantiator else {
            throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        }
        return try climateFunctionInstantiator(module, exportName, imports)
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
