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

/// Calls a fixed-size bulk export and copies its results into `output`.
/// The runtime adapter can perform the module-memory to Swift-memory transfer as one typed-array copy.
public typealias WASMDensityFunctionBulkInvocation = @Sendable (
    Int32, Int32, Int32, UnsafeMutablePointer<Double>
) -> Void

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
    Double, Double, Double, Double, Double, Double, Int64, Int32
) -> Int32
public typealias WASMBiomeIDBulkInvocation = @Sendable (
    Int32, Int32, Int32, UnsafeMutablePointer<Int32>
) -> Void

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

    /// Instantiates a module exporting a fixed-size bulk sampler and its linear memory.
    /// The sampler returns the byte offset of `sampleCount` contiguous `f64` results.
    func instantiateDensityFunctionBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation

    /// Instantiates a fixed-size biome sampler whose linear-memory result is `sampleCount`
    /// contiguous `i32` palette indices.
    func instantiateBiomeIDBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation

    /// Instantiates `sample_climate(i32, i32, i32) -> (f64, f64, f64, f64, f64, f64)`.
    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation

    /// Instantiates a module exporting `search(f64, f64, f64, f64, f64, f64, i64, i32) -> i32`.
    /// The final inputs are an optional previous leaf's squared distance and node index.
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

    func instantiateDensityFunctionBulk(
        module _: [UInt8],
        exportName _: String,
        memoryExportName _: String,
        sampleCount _: Int,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation {
        throw DensityFunctionCompilationError.wasmRuntimeUnavailable
    }

    func instantiateBiomeIDBulk(
        module _: [UInt8],
        exportName _: String,
        memoryExportName _: String,
        sampleCount _: Int,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation {
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
    public typealias DensityFunctionBulkInstantiator = @Sendable (
        [UInt8], String, String, Int, WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation
    public typealias BiomeIDBulkInstantiator = @Sendable (
        [UInt8], String, String, Int, WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation

    private let densityFunctionInstantiator: DensityFunctionInstantiator
    private let biomeSearchInstantiator: BiomeSearchInstantiator
    private let climateFunctionInstantiator: ClimateFunctionInstantiator?
    private let densityFunctionBulkInstantiator: DensityFunctionBulkInstantiator?
    private let biomeIDBulkInstantiator: BiomeIDBulkInstantiator?

    public var supportsClimateFunctions: Bool { self.climateFunctionInstantiator != nil }

    public init(
        instantiateDensityFunction: @escaping DensityFunctionInstantiator,
        instantiateBiomeSearch: @escaping BiomeSearchInstantiator,
        instantiateClimateFunctions: ClimateFunctionInstantiator? = nil,
        instantiateDensityFunctionBulk: DensityFunctionBulkInstantiator? = nil,
        instantiateBiomeIDBulk: BiomeIDBulkInstantiator? = nil
    ) {
        self.densityFunctionInstantiator = instantiateDensityFunction
        self.biomeSearchInstantiator = instantiateBiomeSearch
        self.climateFunctionInstantiator = instantiateClimateFunctions
        self.densityFunctionBulkInstantiator = instantiateDensityFunctionBulk
        self.biomeIDBulkInstantiator = instantiateBiomeIDBulk
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

    public func instantiateDensityFunctionBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation {
        guard let densityFunctionBulkInstantiator else {
            throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        }
        return try densityFunctionBulkInstantiator(
            module,
            exportName,
            memoryExportName,
            sampleCount,
            imports
        )
    }

    public func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        try self.biomeSearchInstantiator(module, exportName)
    }

    public func instantiateBiomeIDBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation {
        guard let biomeIDBulkInstantiator else {
            throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        }
        return try biomeIDBulkInstantiator(module, exportName, memoryExportName, sampleCount, imports)
    }
}
