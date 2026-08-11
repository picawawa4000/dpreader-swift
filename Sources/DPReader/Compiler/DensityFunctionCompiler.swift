import Foundation

/// Selects the backend used after density functions have been lowered to the shared SSA IR.
public enum CompilationBackend: Sendable, Equatable {
    case llvm
    case wasm
}

public enum DensityFunctionCompilationError: Error {
    case noLLVM
    case unsupportedCompilationStrategy(CompilationBackend)
    case nonCompilableDensityFunction
    case badDensityFunction(String)
    case llvmError(String)
    case wasmRuntimeUnavailable
}

private typealias NativeCompiledDensityFunction = @convention(c) (Int32, Int32, Int32) -> Double
private typealias NativeCompiledBiomeSearch = @convention(c) (
    Double, Double, Double, Double, Double, Double
) -> Int32
public typealias CompiledDensityFunctionBuffer = @convention(c) (
    UnsafeRawPointer?,
    Int32,
    Int32,
    Int32,
    UnsafeMutablePointer<Double>?
) -> Void

/// A callable scalar density program and, for WASM compilation, its deployable module bytes.
public final class CompiledDensityFunction: @unchecked Sendable {
    public let strategy: CompilationBackend
    /// A module exporting `sample(i32, i32, i32) -> f64`, present only for the WASM strategy.
    public let wasmModule: [UInt8]?
    private let implementation: @Sendable (Int32, Int32, Int32) -> Double

    init(
        strategy: CompilationBackend,
        wasmModule: [UInt8]? = nil,
        implementation: @escaping @Sendable (Int32, Int32, Int32) -> Double
    ) {
        self.strategy = strategy
        self.wasmModule = wasmModule
        self.implementation = implementation
    }

    public func callAsFunction(_ x: Int32, _ y: Int32, _ z: Int32) -> Double {
        self.implementation(x, y, z)
    }
}

final class CompiledWASMClimateFunctions: @unchecked Sendable {
    let wasmModule: [UInt8]
    private let implementation: WASMClimateInvocation
    private let fallbackFunctions: [Int: any DensityFunction]

    init(
        wasmModule: [UInt8],
        implementation: @escaping WASMClimateInvocation,
        fallbackFunctions: [Int: any DensityFunction]
    ) {
        self.wasmModule = wasmModule
        self.implementation = implementation
        self.fallbackFunctions = fallbackFunctions
    }

    func sample(x: Int32, y: Int32, z: Int32) -> WASMClimateSample {
        let compiled = self.implementation(x, y, z)
        guard !self.fallbackFunctions.isEmpty else { return compiled }

        let position = PosInt3D(x: x, y: y, z: z)
        var temperature = compiled.temperature
        var humidity = compiled.humidity
        var continentalness = compiled.continentalness
        var erosion = compiled.erosion
        var weirdness = compiled.weirdness
        var depth = compiled.depth
        for (index, function) in self.fallbackFunctions {
            let value = function.sample(at: position)
            switch index {
            case 0: temperature = value
            case 1: humidity = value
            case 2: continentalness = value
            case 3: erosion = value
            case 4: weirdness = value
            case 5: depth = value
            default: preconditionFailure("Invalid climate function index.")
            }
        }
        return WASMClimateSample(
            temperature: temperature,
            humidity: humidity,
            continentalness: continentalness,
            erosion: erosion,
            weirdness: weirdness,
            depth: depth
        )
    }
}

/// The block dimensions of one generation cell.
public struct DensityFunctionCellSize: Sendable, Hashable {
    public let horizontalBlockCount: Int32
    public let verticalBlockCount: Int32

    /// Creates a cell whose block dimensions are four times the corresponding noise settings.
    public init(sizeHorizontal: Int, sizeVertical: Int) {
        precondition(sizeHorizontal > 0 && sizeVertical > 0, "Noise cell sizes must be positive.")
        precondition(sizeHorizontal <= Int(Int32.max) / 4 && sizeVertical <= Int(Int32.max) / 4, "Noise cell size overflowed Int32.")
        self.horizontalBlockCount = Int32(sizeHorizontal * 4)
        self.verticalBlockCount = Int32(sizeVertical * 4)
    }

    public init(horizontalBlockCount: Int32, verticalBlockCount: Int32) {
        precondition(horizontalBlockCount > 0 && verticalBlockCount > 0, "Density function cell sizes must be positive.")
        self.horizontalBlockCount = horizontalBlockCount
        self.verticalBlockCount = verticalBlockCount
    }

    public var blockCount: Int {
        Int(self.horizontalBlockCount) * Int(self.verticalBlockCount) * Int(self.horizontalBlockCount)
    }
}

/// The number of generation cells evaluated by one bulk invocation.
public struct DensityFunctionCellVolume: Sendable, Hashable {
    public let xCount: Int32
    public let yCount: Int32
    public let zCount: Int32

    public init(xCount: Int32, yCount: Int32, zCount: Int32) {
        precondition(xCount > 0 && yCount > 0 && zCount > 0, "Density function cell volume counts must be positive.")
        self.xCount = xCount
        self.yCount = yCount
        self.zCount = zCount
    }

    public var cellCount: Int {
        Int(self.xCount) * Int(self.yCount) * Int(self.zCount)
    }
}

/// Caller-owned transient storage used by flat and 2D caches while evaluating a cell column.
public struct CompiledDensityFunctionBulkEvaluationContext: @unchecked Sendable {
    public var cacheValues: UnsafeMutablePointer<Double>?
    public var cacheValueCount: Int

    public init(cacheValues: UnsafeMutablePointer<Double>?, cacheValueCount: Int) {
        self.cacheValues = cacheValues
        self.cacheValueCount = cacheValueCount
    }
}

/// A compiled cell-volume evaluator and its exact output/cache storage requirements.
public final class CompiledDensityFunctionBulkProgram: @unchecked Sendable {
    public let function: CompiledDensityFunctionBuffer
    public let cellSize: DensityFunctionCellSize
    public let cellVolume: DensityFunctionCellVolume
    public let cacheCount: Int
    public let cacheElementsPerCell: Int
    public let cacheValueCount: Int
    public let outputValueCount: Int

    init(
        function: @escaping CompiledDensityFunctionBuffer,
        cellSize: DensityFunctionCellSize,
        cellVolume: DensityFunctionCellVolume,
        cacheCount: Int
    ) {
        self.function = function
        self.cellSize = cellSize
        self.cellVolume = cellVolume
        self.cacheCount = cacheCount
        self.cacheElementsPerCell = cellSize.blockCount
        self.cacheValueCount = cacheCount * cellSize.blockCount
        self.outputValueCount = cellVolume.cellCount * cellSize.blockCount
    }
}

public struct CompiledDensityFunctionBufferContext: Sendable {
    public let xCount: Int32
    public let yCount: Int32
    public let zCount: Int32
    public let xStep: Int32
    public let yStep: Int32
    public let zStep: Int32

    public init(xCount: Int32, yCount: Int32, zCount: Int32, xStep: Int32 = 1, yStep: Int32 = 1, zStep: Int32 = 1) {
        self.xCount = xCount
        self.yCount = yCount
        self.zCount = zCount
        self.xStep = xStep
        self.yStep = yStep
        self.zStep = zStep
    }

    public var sampleCount: Int {
        let count = Int64(self.xCount) * Int64(self.yCount) * Int64(self.zCount)
        precondition(self.xCount > 0 && self.yCount > 0 && self.zCount > 0, "Buffer context counts must be positive.")
        precondition(count <= Int64(Int.max), "Buffer context sample count overflowed Int.")
        return Int(count)
    }
}

public struct BufferedDensityFunctionCompilationOptions: Sendable {
    public var profilingState: BufferedDensityFunctionProfilingState?

    public init(profilingState: BufferedDensityFunctionProfilingState? = nil) {
        self.profilingState = profilingState
    }
}

public struct BufferedDensityFunctionProfilingNode: Sendable, Codable {
    public let index: Int
    public let kind: String
    public let label: String
    public let xCount: Int
    public let yCount: Int
    public let zCount: Int
    public let sampleCount: Int
    public let outputValueCount: Int
    public let plannedUseCount: Int
    public let fusedTransformCount: Int
    public let cacheHitCount: Int
    public let totalNanos: UInt64
}

public struct BufferedDensityFunctionProfilingEvent: Sendable, Codable {
    public let nanosSinceStart: UInt64
    public let kind: String
    public let valueCount: Int
    public let pooledBufferCount: Int
    public let pooledValueCount: Int
    public let retainedBufferCount: Int
    public let retainedValueCount: Int
}

public struct BufferedDensityFunctionProfilingFunction: Sendable, Codable {
    public let index: Int
    public let type: String
    public let label: String
    public let callCount: Int
    public let selfNanos: UInt64
    public let totalNanos: UInt64
}

public struct BufferedDensityFunctionProfilingReport: Sendable, Codable {
    public let buildNanos: UInt64
    public let totalNanos: UInt64
    public let nodeCount: Int
    public let sharedNodeReuseCount: Int
    public let fusedTransformCount: Int
    public let realizedNodeCount: Int
    public let nodeResultCacheHitCount: Int
    public let allocatedBufferCount: Int
    public let allocatedValueCount: Int
    public let reusedBufferCount: Int
    public let reusedValueCount: Int
    public let recycledBufferCount: Int
    public let recycledValueCount: Int
    public let storedRetainedBufferCount: Int
    public let storedRetainedValueCount: Int
    public let releasedRetainedBufferCount: Int
    public let releasedRetainedValueCount: Int
    public let currentPooledBufferCount: Int
    public let currentPooledValueCount: Int
    public let peakPooledBufferCount: Int
    public let peakPooledValueCount: Int
    public let currentRetainedBufferCount: Int
    public let currentRetainedValueCount: Int
    public let peakRetainedBufferCount: Int
    public let peakRetainedValueCount: Int
    public let nodes: [BufferedDensityFunctionProfilingNode]
    public let functions: [BufferedDensityFunctionProfilingFunction]
    public let events: [BufferedDensityFunctionProfilingEvent]
}

public final class BufferedDensityFunctionProfilingState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport: BufferedDensityFunctionProfilingReport?

    public init() {}

    public func latestReport() -> BufferedDensityFunctionProfilingReport? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.lastReport
    }

    func record(_ report: BufferedDensityFunctionProfilingReport) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.lastReport = report
    }
}

private let doublePointerAlignmentBytes: UInt64 = 8

private func validateCompiledDensityFunctionBufferContext(
    _ bufferContext: CompiledDensityFunctionBufferContext
) throws -> (sampleCount: Int64, planeStride: Int64) {
    guard bufferContext.xCount > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive xCount.")
    }
    guard bufferContext.yCount > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive yCount.")
    }
    guard bufferContext.zCount > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive zCount.")
    }
    guard bufferContext.xStep > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive xStep.")
    }
    guard bufferContext.yStep > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive yStep.")
    }
    guard bufferContext.zStep > 0 else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation requires a positive zStep.")
    }

    let planeStride = Int64(bufferContext.xCount) * Int64(bufferContext.yCount)
    let sampleCount = planeStride * Int64(bufferContext.zCount)
    guard sampleCount <= Int64(Int.max) else {
        throw DensityFunctionCompilationError.badDensityFunction("Buffered compilation sample count overflowed Int.")
    }
    return (sampleCount, planeStride)
}

private struct BulkGenerationCellCounts {
    let horizontal: Int32
    let vertical: Int32
}

private func findPreferredBulkGenerationCellCounts(
    in function: any DensityFunction,
    registry: Registry<DensityFunction>,
    visited: inout Set<ObjectIdentifier>,
    referenceStack: inout [String]
) -> BulkGenerationCellCounts? {
    if type(of: function) is AnyObject.Type {
        let identity = ObjectIdentifier(function as AnyObject)
        if visited.contains(identity) {
            return nil
        }
        visited.insert(identity)
    }

    if let interpolated = function as? ChunkInterpolatedCache {
        return BulkGenerationCellCounts(
            horizontal: interpolated.bufferedHorizontalCellBlockCount,
            vertical: interpolated.bufferedVerticalCellBlockCount
        )
    }
    if let reference = function as? ReferenceDensityFunction {
        let key = reference.targetKey.name
        guard !referenceStack.contains(key), let target = registry.get(reference.targetKey) else {
            return nil
        }
        referenceStack.append(key)
        defer {
            _ = referenceStack.popLast()
        }
        return findPreferredBulkGenerationCellCounts(in: target, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let unary = function as? UnaryDensityFunction {
        return findPreferredBulkGenerationCellCounts(in: unary.inputOperand, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let binary = function as? BinaryDensityFunction {
        return findPreferredBulkGenerationCellCounts(in: binary.firstOperand, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: binary.secondOperand, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let clampFunction = function as? ClampDensityFunction {
        return findPreferredBulkGenerationCellCounts(in: clampFunction.clampedInput, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let rangeChoice = function as? RangeChoice {
        return findPreferredBulkGenerationCellCounts(in: rangeChoice.inputChoiceFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: rangeChoice.whenInRangeOutput, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: rangeChoice.whenOutOfRangeOutput, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let shiftedNoise = function as? ShiftedNoise {
        return findPreferredBulkGenerationCellCounts(in: shiftedNoise.shiftXFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: shiftedNoise.shiftYFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: shiftedNoise.shiftZFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let weirdScaledSampler = function as? WeirdScaledSampler {
        return findPreferredBulkGenerationCellCounts(in: weirdScaledSampler.inputFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let blendDensity = function as? BlendDensity {
        return findPreferredBulkGenerationCellCounts(in: blendDensity.argumentFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let findTopSurface = function as? FindTopSurface {
        return findPreferredBulkGenerationCellCounts(in: findTopSurface.densityFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
            ?? findPreferredBulkGenerationCellCounts(in: findTopSurface.upperBoundFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let spline = function as? SplineDensityFunction {
        return findPreferredBulkGenerationCellCounts(in: spline.splineSegment, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
        return findPreferredBulkGenerationCellCounts(in: wrapper.wrappedDensityFunction, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
    return nil
}

private func findPreferredBulkGenerationCellCounts(
    in segment: SplineSegment,
    registry: Registry<DensityFunction>,
    visited: inout Set<ObjectIdentifier>,
    referenceStack: inout [String]
) -> BulkGenerationCellCounts? {
    switch segment {
    case .number:
        return nil
    case .object(let object):
        return findPreferredBulkGenerationCellCounts(in: object, registry: registry, visited: &visited, referenceStack: &referenceStack)
    }
}

private func findPreferredBulkGenerationCellCounts(
    in object: SplineObject,
    registry: Registry<DensityFunction>,
    visited: inout Set<ObjectIdentifier>,
    referenceStack: inout [String]
) -> BulkGenerationCellCounts? {
    if let preferred = findPreferredBulkGenerationCellCounts(in: object.inputFunction, registry: registry, visited: &visited, referenceStack: &referenceStack) {
        return preferred
    }
    for value in object.pointValues {
        if let preferred = findPreferredBulkGenerationCellCounts(in: value, registry: registry, visited: &visited, referenceStack: &referenceStack) {
            return preferred
        }
    }
    return nil
}

private func findPreferredBulkGenerationCellCounts(
    in function: any DensityFunction,
    registry: Registry<DensityFunction>
) -> BulkGenerationCellCounts? {
    var visited: Set<ObjectIdentifier> = []
    var referenceStack: [String] = []
    return findPreferredBulkGenerationCellCounts(in: function, registry: registry, visited: &visited, referenceStack: &referenceStack)
}

public func compile(
    densityFunction root: any DensityFunction,
    strategy: CompilationBackend = .llvm,
    registry: Registry<DensityFunction> = Registry(),
    runtime: (any WASMRuntime)? = nil
) throws -> CompiledDensityFunction {
    let program = try buildDensityFunctionIR(densityFunction: root, registry: registry)
    switch strategy {
    case .wasm:
        let module = try buildDensityFunctionWASMModule(program)
        if let runtime {
            let imports = WASMDensityFunctionImports(
                sampleDensity: { index, x, y, z in
                    precondition(index >= 0 && Int(index) < program.densityFunctions.count)
                    return program.densityFunctions[Int(index)].sample(at: PosInt3D(x: x, y: y, z: z))
                },
                sampleNoise: { index, x, y, z in
                    precondition(index >= 0 && Int(index) < program.noises.count)
                    return program.noises[Int(index)].sample(x: x, y: y, z: z)
                }
            )
            let implementation = try runtime.instantiateDensityFunction(
                module: module,
                exportName: "sample",
                imports: imports
            )
            return CompiledDensityFunction(
                strategy: .wasm,
                wasmModule: module,
                implementation: implementation
            )
        }
        #if os(WASI) || arch(wasm32)
        // A WASI host must execute emitted WASM through its resident engine. Evaluating the IR here would
        // hide a missing browser/embedding bridge and defeat the purpose of selecting this backend.
        throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        #else
        return CompiledDensityFunction(strategy: .wasm, wasmModule: module) { x, y, z in
            evaluateDensityFunctionIR(program, x: x, y: y, z: z)
        }
        #endif
    case .llvm:
#if canImport(CLLVM)
        return try compileDensityFunctionIRWithLLVM(program, registry: registry)
#else
        throw DensityFunctionCompilationError.unsupportedCompilationStrategy(.llvm)
#endif
    }
}

func compileWASMClimateFunctions(
    _ densityFunctions: [any DensityFunction],
    registry: Registry<DensityFunction>,
    runtime: any WASMRuntime
) throws -> CompiledWASMClimateFunctions {
    precondition(densityFunctions.count == 6, "A climate program requires six density functions.")
    var fallbackFunctions: [Int: any DensityFunction] = [:]
    var wasmDensityFunctions: [any DensityFunction] = []
    wasmDensityFunctions.reserveCapacity(densityFunctions.count)
    for (index, densityFunction) in densityFunctions.enumerated() {
        let scalarProgram = try buildDensityFunctionIR(densityFunction: densityFunction, registry: registry)
        let isSelfContained = scalarProgram.densityFunctions.isEmpty
            && scalarProgram.noises.allSatisfy { $0 is BakedNoise }
        if isSelfContained {
            wasmDensityFunctions.append(densityFunction)
        } else {
            // Calling an unsupported node back through JavaScript is much more expensive than keeping
            // that complete root on the Swift side of the single combined WASM invocation.
            fallbackFunctions[index] = densityFunction
            wasmDensityFunctions.append(ConstantDensityFunction(value: 0))
        }
    }

    let program = try buildDensityFunctionIR(densityFunctions: wasmDensityFunctions, registry: registry)
    let module = try buildDensityFunctionWASMModule(program, exportName: "sample_climate")
    let imports = WASMDensityFunctionImports(
        sampleDensity: { index, x, y, z in
            precondition(index >= 0 && Int(index) < program.densityFunctions.count)
            return program.densityFunctions[Int(index)].sample(at: PosInt3D(x: x, y: y, z: z))
        },
        sampleNoise: { index, x, y, z in
            precondition(index >= 0 && Int(index) < program.noises.count)
            return program.noises[Int(index)].sample(x: x, y: y, z: z)
        }
    )
    let implementation = try runtime.instantiateClimateFunctions(
        module: module,
        exportName: "sample_climate",
        imports: imports
    )
    return CompiledWASMClimateFunctions(
        wasmModule: module,
        implementation: implementation,
        fallbackFunctions: fallbackFunctions
    )
}

#if canImport(CLLVM)
import CLLVM

private final class JITCompiler: @unchecked Sendable {
    static let shared = JITCompiler()

    let jit: LLVMOrcLLJITRef
    private let lock = NSLock()
    private var retainedObjects: [AnyObject] = []

    private init() {
        LLVMInitializeNativeTarget()
        LLVMInitializeNativeAsmPrinter()
        LLVMInitializeNativeAsmParser()

        var jit: LLVMOrcLLJITRef?
        let error = LLVMOrcCreateLLJIT(&jit, nil)
        if let error {
            fatalError("Failed to initialize LLVM: \(takeLLVMErrorMessage(error))")
        }
        self.jit = jit!
    }

    func retain(_ object: AnyObject) {
        self.retainedObjects.append(object)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return try body()
    }
}

private final class NoiseRuntimeSamplerBox: @unchecked Sendable {
    let noise: any DensityFunctionNoise

    init(noise: any DensityFunctionNoise) {
        self.noise = noise
    }
}

final class DensityFunctionCompilationContext {
    private struct CompiledValueKey: Hashable {
        let functionIdentity: ObjectIdentifier
        let x: UInt
        let y: UInt
        let z: UInt
    }

    private struct CachedCompiledValue {
        let value: LLVMValueRef
        let block: LLVMBasicBlockRef?
    }

    struct ChunkInterpolatedCornerStorage {
        let valid: LLVMValueRef
        let cellStartX: LLVMValueRef
        let cellStartY: LLVMValueRef
        let cellStartZ: LLVMValueRef
        let corners: [LLVMValueRef]
    }

    struct Coordinate2DCacheStorage {
        let valid: LLVMValueRef
        let x: LLVMValueRef
        let z: LLVMValueRef
        let value: LLVMValueRef
    }

    struct Chunk2DCacheStorage {
        let localValid: LLVMValueRef
        let localValues: LLVMValueRef
        let outside: Coordinate2DCacheStorage
    }

    struct ChunkFlatCacheStorage {
        let localValid: LLVMValueRef
        let localValues: LLVMValueRef
        let startBiomeX: Int32
        let startBiomeZ: Int32
        let horizontalCacheSize: Int32
    }

    struct BulkCoordinate2DCacheStorage {
        let localValid: LLVMValueRef
        let localValues: LLVMValueRef
        let outside: Coordinate2DCacheStorage
    }

    struct BulkGenerationCellState {
        let cellXIndex: LLVMValueRef
        let cellYIndex: LLVMValueRef
        let cellZIndex: LLVMValueRef
        let cellStartX: LLVMValueRef
        let cellStartY: LLVMValueRef
        let cellStartZ: LLVMValueRef
        let localXIndex: LLVMValueRef
        let localYIndex: LLVMValueRef
        let localZIndex: LLVMValueRef
        let horizontalCount: Int32
        let verticalCount: Int32
    }

    let llvmContext: LLVMContextRef
    let builder: LLVMBuilderRef
    let doubleType: LLVMTypeRef
    let int32Type: LLVMTypeRef
    let int64Type: LLVMTypeRef
    let densityFunctionRegistry: Registry<DensityFunction>
    let bulkInitialY: LLVMValueRef?
    let bulkBaseX: LLVMValueRef?
    let bulkBaseZ: LLVMValueRef?
    let bulkBufferContext: CompiledDensityFunctionBufferContext?

    private var referenceResolutionStack: [String] = []
    private var compiledValues: [CompiledValueKey: CachedCompiledValue] = [:]
    private var chunkInterpolatedCornerStorageByIdentity: [ObjectIdentifier: ChunkInterpolatedCornerStorage] = [:]
    private var coordinate2DCacheStorageByIdentity: [ObjectIdentifier: Coordinate2DCacheStorage] = [:]
    private var chunk2DCacheStorageByIdentity: [ObjectIdentifier: Chunk2DCacheStorage] = [:]
    private var chunkFlatCacheStorageByIdentity: [ObjectIdentifier: ChunkFlatCacheStorage] = [:]
    private var bulkCoordinate2DCacheStorageByIdentity: [ObjectIdentifier: BulkCoordinate2DCacheStorage] = [:]
    var bulkGenerationCellState: BulkGenerationCellState?

    init(
        llvmContext: LLVMContextRef,
        builder: LLVMBuilderRef,
        doubleType: LLVMTypeRef,
        int32Type: LLVMTypeRef,
        int64Type: LLVMTypeRef,
        densityFunctionRegistry: Registry<DensityFunction>,
        bulkInitialY: LLVMValueRef? = nil,
        bulkBaseX: LLVMValueRef? = nil,
        bulkBaseZ: LLVMValueRef? = nil,
        bulkBufferContext: CompiledDensityFunctionBufferContext? = nil
    ) {
        self.llvmContext = llvmContext
        self.builder = builder
        self.doubleType = doubleType
        self.int32Type = int32Type
        self.int64Type = int64Type
        self.densityFunctionRegistry = densityFunctionRegistry
        self.bulkInitialY = bulkInitialY
        self.bulkBaseX = bulkBaseX
        self.bulkBaseZ = bulkBaseZ
        self.bulkBufferContext = bulkBufferContext
    }

    @inline(__always)
    func constant(_ value: Double) -> LLVMValueRef {
        LLVMConstReal(self.doubleType, value)
    }

    @inline(__always)
    func floatConstant(_ value: Float) -> LLVMValueRef {
        LLVMConstReal(LLVMFloatTypeInContext(self.llvmContext), Double(value))
    }

    @inline(__always)
    func int32Constant(_ value: Int32) -> LLVMValueRef {
        LLVMConstInt(self.int32Type, UInt64(UInt32(bitPattern: value)), 1)
    }

    @inline(__always)
    func int64Constant(_ value: UInt64) -> LLVMValueRef {
        LLVMConstInt(self.int64Type, value, 0)
    }

    @inline(__always)
    func buildMin(_ lhs: LLVMValueRef, _ rhs: LLVMValueRef, name: String) -> LLVMValueRef {
        let isLessThan = LLVMBuildFCmp(self.builder, LLVMRealOLT, lhs, rhs, "\(name).cmp")
        return LLVMBuildSelect(self.builder, isLessThan, lhs, rhs, name)
    }

    @inline(__always)
    func buildMax(_ lhs: LLVMValueRef, _ rhs: LLVMValueRef, name: String) -> LLVMValueRef {
        let isGreaterThan = LLVMBuildFCmp(self.builder, LLVMRealOGT, lhs, rhs, "\(name).cmp")
        return LLVMBuildSelect(self.builder, isGreaterThan, lhs, rhs, name)
    }

    @inline(__always)
    func buildAbs(_ value: LLVMValueRef, name: String) -> LLVMValueRef {
        let isNegative = LLVMBuildFCmp(self.builder, LLVMRealOLT, value, self.constant(0.0), "\(name).is_negative")
        let negated = LLVMBuildFNeg(self.builder, value, "\(name).negated")
        return LLVMBuildSelect(self.builder, isNegative, negated, value, name)
    }

    @inline(__always)
    func buildFloorDiv(_ value: LLVMValueRef, by divisor: Int32, name: String) -> LLVMValueRef {
        let divisorValue = self.int32Constant(divisor)
        let quotient = LLVMBuildSDiv(self.builder, value, divisorValue, "\(name).quotient")!
        let remainder = LLVMBuildSRem(self.builder, value, divisorValue, "\(name).remainder")!
        let remainderIsNegative = LLVMBuildICmp(
            self.builder,
            LLVMIntSLT,
            remainder,
            self.int32Constant(0),
            "\(name).remainder_is_negative"
        )!
        let adjusted = LLVMBuildSub(self.builder, quotient, self.int32Constant(1), "\(name).adjusted")!
        return LLVMBuildSelect(self.builder, remainderIsNegative, adjusted, quotient, name)!
    }

    @inline(__always)
    func buildLerp(_ delta: LLVMValueRef, start: LLVMValueRef, end: LLVMValueRef, name: String) -> LLVMValueRef {
        let difference = LLVMBuildFSub(self.builder, end, start, "\(name).difference")!
        let scaled = LLVMBuildFMul(self.builder, delta, difference, "\(name).scaled")!
        return LLVMBuildFAdd(self.builder, start, scaled, name)!
    }

    @inline(__always)
    func buildAnd(_ lhs: LLVMValueRef, _ rhs: LLVMValueRef, name: String) -> LLVMValueRef {
        LLVMBuildAnd(self.builder, lhs, rhs, name)!
    }

    @inline(__always)
    func buildFloatTrunc(_ value: LLVMValueRef, name: String) -> LLVMValueRef {
        LLVMBuildFPTrunc(self.builder, value, LLVMFloatTypeInContext(self.llvmContext), name)!
    }

    @inline(__always)
    func buildFloatExtend(_ value: LLVMValueRef, name: String) -> LLVMValueRef {
        LLVMBuildFPExt(self.builder, value, self.doubleType, name)!
    }

    @inline(__always)
    func buildIntInHalfOpenRange(_ value: LLVMValueRef, lowerBound: Int32, upperBound: Int32, name: String) -> LLVMValueRef {
        let atLeastLowerBound = LLVMBuildICmp(
            self.builder,
            LLVMIntSGE,
            value,
            self.int32Constant(lowerBound),
            "\(name).at_least_lower_bound"
        )!
        let belowUpperBound = LLVMBuildICmp(
            self.builder,
            LLVMIntSLT,
            value,
            self.int32Constant(upperBound),
            "\(name).below_upper_bound"
        )!
        return self.buildAnd(atLeastLowerBound, belowUpperBound, name: name)
    }

    func withResolvedReference<T>(
        _ reference: ReferenceDensityFunction,
        body: (any CompilableDensityFunction) throws -> T
    ) throws -> T {
        let key = reference.targetKey.name
        if self.referenceResolutionStack.contains(key) {
            let cycle = (self.referenceResolutionStack + [key]).joined(separator: " -> ")
            throw DensityFunctionCompilationError.badDensityFunction("Cyclic density function reference: \(cycle)")
        }
        guard let target = self.densityFunctionRegistry.get(reference.targetKey) else {
            throw DensityFunctionCompilationError.badDensityFunction("Missing referenced density function: \(key)")
        }
        guard let compilableTarget = target as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }

        self.referenceResolutionStack.append(key)
        defer {
            _ = self.referenceResolutionStack.popLast()
        }
        return try body(compilableTarget)
    }

    func buildRuntimeDensitySampleCall(
        _ densityFunction: AnyObject,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef,
        name: String
    ) -> LLVMValueRef {
        var parameterTypes: [LLVMTypeRef?] = [self.int64Type, self.int32Type, self.int32Type, self.int32Type]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(self.doubleType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let functionPointer = LLVMConstIntToPtr(
            self.int64Constant(densityFunctionSamplerAddress()),
            LLVMPointerType(functionType, 0)
        )
        var arguments: [LLVMValueRef?] = [
            self.int64Constant(opaquePointerBits(for: densityFunction)),
            x,
            y,
            z
        ]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildCall2(self.builder, functionType, functionPointer, buffer.baseAddress, UInt32(buffer.count), name)
        }
    }

    func buildRuntimeNoiseSampleCall(
        _ noise: any DensityFunctionNoise,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef,
        name: String
    ) -> LLVMValueRef {
        let box = NoiseRuntimeSamplerBox(noise: noise)
        JITCompiler.shared.retain(box)

        var parameterTypes: [LLVMTypeRef?] = [self.int64Type, self.doubleType, self.doubleType, self.doubleType]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(self.doubleType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let functionPointer = LLVMConstIntToPtr(
            self.int64Constant(noiseSamplerAddress()),
            LLVMPointerType(functionType, 0)
        )
        var arguments: [LLVMValueRef?] = [
            self.int64Constant(opaquePointerBits(for: box)),
            x,
            y,
            z
        ]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildCall2(self.builder, functionType, functionPointer, buffer.baseAddress, UInt32(buffer.count), name)
        }
    }

    func buildFloorCall(_ value: LLVMValueRef, name: String) -> LLVMValueRef {
        var parameterTypes: [LLVMTypeRef?] = [self.doubleType]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(self.doubleType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let functionPointer = LLVMConstIntToPtr(
            self.int64Constant(floorDoubleAddress()),
            LLVMPointerType(functionType, 0)
        )
        var arguments: [LLVMValueRef?] = [value]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildCall2(self.builder, functionType, functionPointer, buffer.baseAddress, UInt32(buffer.count), name)
        }
    }

    func cachedCompile(
        _ densityFunction: any DensityFunction,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef,
        build: () throws -> LLVMValueRef
    ) throws -> LLVMValueRef {
        guard type(of: densityFunction) is AnyObject.Type else {
            return try build()
        }

        return try self.cachedCompileIdentity(
            ObjectIdentifier(densityFunction as AnyObject),
            x: x,
            y: y,
            z: z,
            build: build
        )
    }

    private func cachedCompileIdentity(
        _ identity: ObjectIdentifier,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef,
        build: () throws -> LLVMValueRef
    ) throws -> LLVMValueRef {
        let key = CompiledValueKey(
            functionIdentity: identity,
            x: UInt(bitPattern: x),
            y: UInt(bitPattern: y),
            z: UInt(bitPattern: z)
        )
        let currentBlock = LLVMGetInsertBlock(self.builder)
        if let cached = self.compiledValues[key], cached.block == nil || cached.block == currentBlock {
            return cached.value
        }

        let compiled = try build()
        let compiledBlock: LLVMBasicBlockRef?
        if LLVMIsAConstant(compiled) != nil {
            compiledBlock = nil
        } else {
            compiledBlock = LLVMGetInsertBlock(self.builder)
        }
        self.compiledValues[key] = CachedCompiledValue(value: compiled, block: compiledBlock)
        return compiled
    }

    func buildEntryAlloca(_ type: LLVMTypeRef, name: String) throws -> LLVMValueRef {
        let function = try currentFunction(in: self)
        guard let entryBlock = LLVMGetFirstBasicBlock(function) else {
            throw DensityFunctionCompilationError.llvmError("Failed to find function entry block for alloca.")
        }
        guard let builder = LLVMCreateBuilderInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create temporary LLVM builder for alloca.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        var insertionInstruction = LLVMGetFirstInstruction(entryBlock)
        while let instruction = insertionInstruction, LLVMIsAAllocaInst(instruction) != nil {
            insertionInstruction = LLVMGetNextInstruction(instruction)
        }

        if let insertionInstruction {
            LLVMPositionBuilderBefore(builder, insertionInstruction)
        } else {
            LLVMPositionBuilderAtEnd(builder, entryBlock)
        }

        guard let alloca = LLVMBuildAlloca(builder, type, name) else {
            throw DensityFunctionCompilationError.llvmError("Failed to build entry alloca \(name).")
        }
        return alloca
    }

    func initializeEntryValue(_ value: LLVMValueRef, into pointer: LLVMValueRef) throws {
        let function = try currentFunction(in: self)
        guard let entryBlock = LLVMGetFirstBasicBlock(function) else {
            throw DensityFunctionCompilationError.llvmError("Failed to find function entry block for initialization.")
        }
        guard let builder = LLVMCreateBuilderInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create temporary LLVM builder for initialization.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        var insertionInstruction = LLVMGetFirstInstruction(entryBlock)
        while let instruction = insertionInstruction, LLVMIsAAllocaInst(instruction) != nil {
            insertionInstruction = LLVMGetNextInstruction(instruction)
        }

        if let insertionInstruction {
            LLVMPositionBuilderBefore(builder, insertionInstruction)
        } else {
            LLVMPositionBuilderAtEnd(builder, entryBlock)
        }

        _ = LLVMBuildStore(builder, value, pointer)
    }

    func buildArrayElementPointer(
        _ arrayPointer: LLVMValueRef,
        elementType: LLVMTypeRef,
        count: Int,
        index: LLVMValueRef,
        name: String
    ) -> LLVMValueRef {
        let arrayType = LLVMArrayType(elementType, UInt32(count))!
        var indices: [LLVMValueRef?] = [self.int32Constant(0), index]
        return indices.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildInBoundsGEP2(self.builder, arrayType, arrayPointer, buffer.baseAddress, UInt32(buffer.count), name)
        }!
    }

    func initializeEntryArrayElements(
        _ arrayPointer: LLVMValueRef,
        elementType: LLVMTypeRef,
        count: Int,
        initialValue: LLVMValueRef,
        namePrefix: String
    ) throws {
        let function = try currentFunction(in: self)
        guard let entryBlock = LLVMGetFirstBasicBlock(function) else {
            throw DensityFunctionCompilationError.llvmError("Failed to find function entry block for array initialization.")
        }
        guard let builder = LLVMCreateBuilderInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create temporary LLVM builder for array initialization.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        var insertionInstruction = LLVMGetFirstInstruction(entryBlock)
        while let instruction = insertionInstruction, LLVMIsAAllocaInst(instruction) != nil {
            insertionInstruction = LLVMGetNextInstruction(instruction)
        }

        if let insertionInstruction {
            LLVMPositionBuilderBefore(builder, insertionInstruction)
        } else {
            LLVMPositionBuilderAtEnd(builder, entryBlock)
        }

        let arrayType = LLVMArrayType(elementType, UInt32(count))!
        for index in 0..<count {
            var indices: [LLVMValueRef?] = [self.int32Constant(0), self.int32Constant(Int32(index))]
            let elementPointer = indices.withUnsafeMutableBufferPointer { buffer in
                LLVMBuildInBoundsGEP2(builder, arrayType, arrayPointer, buffer.baseAddress, UInt32(buffer.count), "\(namePrefix)_\(index)")
            }!
            _ = LLVMBuildStore(builder, initialValue, elementPointer)
        }
    }

    private func buildCoordinate2DCacheStorage(prefix: String) throws -> Coordinate2DCacheStorage {
        guard let int1Type = LLVMInt1TypeInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i1 type.")
        }

        let valid = try self.buildEntryAlloca(int1Type, name: "\(prefix).valid")
        let x = try self.buildEntryAlloca(self.int32Type, name: "\(prefix).x")
        let z = try self.buildEntryAlloca(self.int32Type, name: "\(prefix).z")
        let value = try self.buildEntryAlloca(self.doubleType, name: "\(prefix).value")
        try self.initializeEntryValue(LLVMConstInt(int1Type, 0, 0), into: valid)
        return Coordinate2DCacheStorage(valid: valid, x: x, z: z, value: value)
    }

    func chunkInterpolatedCornerStorage(
        for cacheIdentity: ObjectIdentifier
    ) throws -> ChunkInterpolatedCornerStorage {
        if let storage = self.chunkInterpolatedCornerStorageByIdentity[cacheIdentity] {
            return storage
        }

        guard let int1Type = LLVMInt1TypeInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i1 type.")
        }

        let valid = try self.buildEntryAlloca(int1Type, name: "chunk_interpolated_cache.valid")
        let cellStartX = try self.buildEntryAlloca(self.int32Type, name: "chunk_interpolated_cache.cell_start_x")
        let cellStartY = try self.buildEntryAlloca(self.int32Type, name: "chunk_interpolated_cache.cell_start_y")
        let cellStartZ = try self.buildEntryAlloca(self.int32Type, name: "chunk_interpolated_cache.cell_start_z")
        let corners = try (0..<8).map { index in
            try self.buildEntryAlloca(self.doubleType, name: "chunk_interpolated_cache.corner_\(index)")
        }

        try self.initializeEntryValue(LLVMConstInt(int1Type, 0, 0), into: valid)

        let storage = ChunkInterpolatedCornerStorage(
            valid: valid,
            cellStartX: cellStartX,
            cellStartY: cellStartY,
            cellStartZ: cellStartZ,
            corners: corners
        )
        self.chunkInterpolatedCornerStorageByIdentity[cacheIdentity] = storage
        return storage
    }

    func coordinate2DCacheStorage(
        for cacheIdentity: ObjectIdentifier,
        prefix: String
    ) throws -> Coordinate2DCacheStorage {
        if let storage = self.coordinate2DCacheStorageByIdentity[cacheIdentity] {
            return storage
        }
        let storage = try self.buildCoordinate2DCacheStorage(prefix: prefix)
        self.coordinate2DCacheStorageByIdentity[cacheIdentity] = storage
        return storage
    }

    func chunk2DCacheStorage(
        for cacheIdentity: ObjectIdentifier,
        localColumnCount: Int
    ) throws -> Chunk2DCacheStorage {
        if let storage = self.chunk2DCacheStorageByIdentity[cacheIdentity] {
            return storage
        }

        guard let int1Type = LLVMInt1TypeInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i1 type.")
        }
        let localValid = try self.buildEntryAlloca(LLVMArrayType(int1Type, UInt32(localColumnCount))!, name: "chunk_cache_2d.local_valid")
        let localValues = try self.buildEntryAlloca(LLVMArrayType(self.doubleType, UInt32(localColumnCount))!, name: "chunk_cache_2d.local_values")
        try self.initializeEntryArrayElements(
            localValid,
            elementType: int1Type,
            count: localColumnCount,
            initialValue: LLVMConstInt(int1Type, 0, 0),
            namePrefix: "chunk_cache_2d.local_valid"
        )

        let storage = Chunk2DCacheStorage(
            localValid: localValid,
            localValues: localValues,
            outside: try self.buildCoordinate2DCacheStorage(prefix: "chunk_cache_2d.outside")
        )
        self.chunk2DCacheStorageByIdentity[cacheIdentity] = storage
        return storage
    }

    func chunkFlatCacheStorage(
        for cacheIdentity: ObjectIdentifier,
        startBiomeX: Int32,
        startBiomeZ: Int32,
        horizontalCacheSize: Int32
    ) throws -> ChunkFlatCacheStorage {
        if let storage = self.chunkFlatCacheStorageByIdentity[cacheIdentity] {
            return storage
        }

        guard let int1Type = LLVMInt1TypeInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i1 type.")
        }
        let elementCount = Int(horizontalCacheSize * horizontalCacheSize)
        let localValid = try self.buildEntryAlloca(LLVMArrayType(int1Type, UInt32(elementCount))!, name: "chunk_flat_cache.local_valid")
        let localValues = try self.buildEntryAlloca(LLVMArrayType(self.doubleType, UInt32(elementCount))!, name: "chunk_flat_cache.local_values")
        try self.initializeEntryArrayElements(
            localValid,
            elementType: int1Type,
            count: elementCount,
            initialValue: LLVMConstInt(int1Type, 0, 0),
            namePrefix: "chunk_flat_cache.local_valid"
        )

        let storage = ChunkFlatCacheStorage(
            localValid: localValid,
            localValues: localValues,
            startBiomeX: startBiomeX,
            startBiomeZ: startBiomeZ,
            horizontalCacheSize: horizontalCacheSize
        )
        self.chunkFlatCacheStorageByIdentity[cacheIdentity] = storage
        return storage
    }

    func bulkCoordinate2DCacheStorage(
        for cacheIdentity: ObjectIdentifier,
        localColumnCount: Int,
        prefix: String
    ) throws -> BulkCoordinate2DCacheStorage {
        if let storage = self.bulkCoordinate2DCacheStorageByIdentity[cacheIdentity] {
            return storage
        }

        guard let int1Type = LLVMInt1TypeInContext(self.llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i1 type.")
        }
        let localValid = try self.buildEntryAlloca(LLVMArrayType(int1Type, UInt32(localColumnCount))!, name: "\(prefix).local_valid")
        let localValues = try self.buildEntryAlloca(LLVMArrayType(self.doubleType, UInt32(localColumnCount))!, name: "\(prefix).local_values")
        try self.initializeEntryArrayElements(
            localValid,
            elementType: int1Type,
            count: localColumnCount,
            initialValue: LLVMConstInt(int1Type, 0, 0),
            namePrefix: "\(prefix).local_valid"
        )

        let storage = BulkCoordinate2DCacheStorage(
            localValid: localValid,
            localValues: localValues,
            outside: try self.buildCoordinate2DCacheStorage(prefix: "\(prefix).outside")
        )
        self.bulkCoordinate2DCacheStorageByIdentity[cacheIdentity] = storage
        return storage
    }

}

private typealias DensityFunctionSamplerThunk = @convention(c) (UInt64, Int32, Int32, Int32) -> Double
private typealias NoiseSamplerThunk = @convention(c) (UInt64, Double, Double, Double) -> Double
private typealias UnaryDoubleThunk = @convention(c) (Double) -> Double

@_cdecl("dpreader_sample_density_function")
private func dpreaderSampleDensityFunction(_ objectPointer: UInt64, _ x: Int32, _ y: Int32, _ z: Int32) -> Double {
    let rawPointer = UnsafeRawPointer(bitPattern: UInt(objectPointer))!
    let object = Unmanaged<AnyObject>.fromOpaque(rawPointer).takeUnretainedValue()
    let densityFunction = object as! any DensityFunction
    return densityFunction.sample(at: PosInt3D(x: x, y: y, z: z))
}

@_cdecl("dpreader_sample_noise")
private func dpreaderSampleNoise(_ boxPointer: UInt64, _ x: Double, _ y: Double, _ z: Double) -> Double {
    let rawPointer = UnsafeRawPointer(bitPattern: UInt(boxPointer))!
    let object = Unmanaged<AnyObject>.fromOpaque(rawPointer).takeUnretainedValue()
    let box = object as! NoiseRuntimeSamplerBox
    return box.noise.sample(x: x, y: y, z: z)
}

@_cdecl("dpreader_floor_double")
private func dpreaderFloorDouble(_ value: Double) -> Double {
    floor(value)
}

@inline(__always)
private func densityFunctionSamplerAddress() -> UInt64 {
    let function = dpreaderSampleDensityFunction as DensityFunctionSamplerThunk
    return UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
}

@inline(__always)
private func noiseSamplerAddress() -> UInt64 {
    let function = dpreaderSampleNoise as NoiseSamplerThunk
    return UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
}

@inline(__always)
private func floorDoubleAddress() -> UInt64 {
    let function = dpreaderFloorDouble as UnaryDoubleThunk
    return UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
}

@inline(__always)
private func opaquePointerBits(for object: AnyObject) -> UInt64 {
    UInt64(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
}

private func makeCompiledDensityFunctionBufferContextLLVMType(in llvmContext: LLVMContextRef) -> LLVMTypeRef? {
    guard let int32Type = LLVMInt32TypeInContext(llvmContext) else {
        return nil
    }
    var fields = [LLVMTypeRef?](repeating: int32Type, count: 6)
    return fields.withUnsafeMutableBufferPointer { buffer in
        LLVMStructTypeInContext(llvmContext, buffer.baseAddress, UInt32(buffer.count), 0)
    }
}

private func addEnumAttribute(
    named name: String,
    value: UInt64 = 0,
    to function: LLVMValueRef,
    index: LLVMAttributeIndex,
    in llvmContext: LLVMContextRef
) {
    let kind = LLVMGetEnumAttributeKindForName(name, name.utf8.count)
    guard kind != 0 else {
        return
    }
    LLVMAddAttributeAtIndex(function, index, LLVMCreateEnumAttribute(llvmContext, kind, value))
}

private func optimize(_ module: LLVMModuleRef) throws {
    let options = LLVMCreatePassBuilderOptions()
    defer {
        LLVMDisposePassBuilderOptions(options)
    }

    LLVMPassBuilderOptionsSetVerifyEach(options, 0)

    try throwIfLLVMError(
        LLVMRunPasses(module, "default<O3>", nil, options),
        prefix: "Failed to optimize density function module"
    )
}

private func buildRawBulkSamplingLoop(
    root: any CompilableDensityFunction,
    bufferContext: CompiledDensityFunctionBufferContext,
    context: DensityFunctionCompilationContext,
    baseX: LLVMValueRef,
    baseY: LLVMValueRef,
    baseZ: LLVMValueRef,
    outputBuffer: LLVMValueRef,
    startBlock: LLVMBasicBlockRef,
    returnBlock: LLVMBasicBlockRef
) throws {
    let builder = context.builder
    let doubleType = context.doubleType
    let bufferPointerType = LLVMPointerType(doubleType, 0)!

    LLVMPositionBuilderAtEnd(builder, startBlock)
    let zHeaderBlock = try appendBlock("density_buffer.z.header", in: context)
    let xHeaderBlock = try appendBlock("density_buffer.x.header", in: context)
    let yHeaderBlock = try appendBlock("density_buffer.y.header", in: context)
    let xAdvanceBlock = try appendBlock("density_buffer.x.advance", in: context)
    let zAdvanceBlock = try appendBlock("density_buffer.z.advance", in: context)
    let entryEndBlock = LLVMGetInsertBlock(builder)!

    LLVMBuildBr(builder, zHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, zHeaderBlock)
    let zIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.z.index")!
    let zCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.z.coord")!
    let zOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.z.output_pointer")!
    LLVMBuildBr(builder, xHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, xHeaderBlock)
    let xIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.x.index")!
    let xCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.x.coord")!
    let xOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.x.output_pointer")!
    LLVMBuildBr(builder, yHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, yHeaderBlock)
    let yIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.y.index")!
    let yCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.y.coord")!
    let yOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.y.output_pointer")!

    let sampledValue = try root.compile(inContext: context, x: xCoord, y: yCoord, z: zCoord)
    let store = LLVMBuildStore(builder, sampledValue, yOutputPointer)!
    LLVMSetAlignment(store, UInt32(doublePointerAlignmentBytes))

    var nextOutputIndices: [LLVMValueRef?] = [context.int64Constant(1)]
    let nextOutputPointer = nextOutputIndices.withUnsafeMutableBufferPointer { buffer in
        LLVMBuildInBoundsGEP2(builder, doubleType, yOutputPointer, buffer.baseAddress, UInt32(buffer.count), "density_buffer.output_pointer.next")
    }!
    let nextYCoord = LLVMBuildAdd(builder, yCoord, context.int32Constant(bufferContext.yStep), "density_buffer.y.coord.next")!
    let nextYIndex = LLVMBuildAdd(builder, yIndex, context.int32Constant(1), "density_buffer.y.index.next")!
    let continueYLoop = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextYIndex,
        context.int32Constant(bufferContext.yCount),
        "density_buffer.y.continue"
    )!
    LLVMBuildCondBr(builder, continueYLoop, yHeaderBlock, xAdvanceBlock)
    let yEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, xAdvanceBlock)
    let nextXCoord = LLVMBuildAdd(builder, xCoord, context.int32Constant(bufferContext.xStep), "density_buffer.x.coord.next")!
    let nextXIndex = LLVMBuildAdd(builder, xIndex, context.int32Constant(1), "density_buffer.x.index.next")!
    let continueXLoop = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextXIndex,
        context.int32Constant(bufferContext.xCount),
        "density_buffer.x.continue"
    )!
    LLVMBuildCondBr(builder, continueXLoop, xHeaderBlock, zAdvanceBlock)
    let xEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, zAdvanceBlock)
    let nextZCoord = LLVMBuildAdd(builder, zCoord, context.int32Constant(bufferContext.zStep), "density_buffer.z.coord.next")!
    let nextZIndex = LLVMBuildAdd(builder, zIndex, context.int32Constant(1), "density_buffer.z.index.next")!
    let continueZLoop = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextZIndex,
        context.int32Constant(bufferContext.zCount),
        "density_buffer.z.continue"
    )!
    LLVMBuildCondBr(builder, continueZLoop, zHeaderBlock, returnBlock)
    let zEndBlock = LLVMGetInsertBlock(builder)!

    addIncoming(phi: zIndex, values: [context.int32Constant(0), nextZIndex], blocks: [entryEndBlock, zEndBlock])
    addIncoming(phi: zCoord, values: [baseZ, nextZCoord], blocks: [entryEndBlock, zEndBlock])
    addIncoming(phi: zOutputPointer, values: [outputBuffer, nextOutputPointer], blocks: [entryEndBlock, zEndBlock])
    addIncoming(phi: xIndex, values: [context.int32Constant(0), nextXIndex], blocks: [zHeaderBlock, xEndBlock])
    addIncoming(phi: xCoord, values: [baseX, nextXCoord], blocks: [zHeaderBlock, xEndBlock])
    addIncoming(phi: xOutputPointer, values: [zOutputPointer, nextOutputPointer], blocks: [zHeaderBlock, xEndBlock])
    addIncoming(phi: yIndex, values: [context.int32Constant(0), nextYIndex], blocks: [xHeaderBlock, yEndBlock])
    addIncoming(phi: yCoord, values: [baseY, nextYCoord], blocks: [xHeaderBlock, yEndBlock])
    addIncoming(phi: yOutputPointer, values: [xOutputPointer, nextOutputPointer], blocks: [xHeaderBlock, yEndBlock])
}

private func buildGenerationCellBulkSamplingLoop(
    root: any CompilableDensityFunction,
    bufferContext: CompiledDensityFunctionBufferContext,
    cellCounts: BulkGenerationCellCounts,
    context: DensityFunctionCompilationContext,
    baseX: LLVMValueRef,
    baseY: LLVMValueRef,
    baseZ: LLVMValueRef,
    outputBuffer: LLVMValueRef,
    startBlock: LLVMBasicBlockRef,
    returnBlock: LLVMBasicBlockRef
) throws {
    let builder = context.builder
    let xCellCount = bufferContext.xCount / cellCounts.horizontal
    let yCellCount = bufferContext.yCount / cellCounts.vertical
    let zCellCount = bufferContext.zCount / cellCounts.horizontal
    let planeStride = Int64(bufferContext.xCount) * Int64(bufferContext.yCount)
    let rowStride = Int64(bufferContext.yCount)
    let cellXPointerStride = Int64(cellCounts.horizontal) * rowStride
    let cellZPointerStride = Int64(cellCounts.horizontal) * planeStride
    let bufferPointerType = LLVMTypeOf(outputBuffer)

    func buildPointerAdvance(_ pointer: LLVMValueRef, by offset: Int64, name: String) -> LLVMValueRef {
        var indices: [LLVMValueRef?] = [context.int64Constant(UInt64(offset))]
        return indices.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildInBoundsGEP2(builder, context.doubleType, pointer, buffer.baseAddress, UInt32(buffer.count), name)
        }!
    }

    LLVMPositionBuilderAtEnd(builder, startBlock)
    let cellZHeaderBlock = try appendBlock("density_buffer.cell_z.header", in: context)
    let cellXHeaderBlock = try appendBlock("density_buffer.cell_x.header", in: context)
    let cellYHeaderBlock = try appendBlock("density_buffer.cell_y.header", in: context)
    let localZHeaderBlock = try appendBlock("density_buffer.local_z.header", in: context)
    let localXHeaderBlock = try appendBlock("density_buffer.local_x.header", in: context)
    let localYHeaderBlock = try appendBlock("density_buffer.local_y.header", in: context)
    let localXAdvanceBlock = try appendBlock("density_buffer.local_x.advance", in: context)
    let localZAdvanceBlock = try appendBlock("density_buffer.local_z.advance", in: context)
    let cellYAdvanceBlock = try appendBlock("density_buffer.cell_y.advance", in: context)
    let cellXAdvanceBlock = try appendBlock("density_buffer.cell_x.advance", in: context)
    let cellZAdvanceBlock = try appendBlock("density_buffer.cell_z.advance", in: context)
    let startEndBlock = LLVMGetInsertBlock(builder)!

    LLVMBuildBr(builder, cellZHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, cellZHeaderBlock)
    let cellZIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_z.index")!
    let cellBaseZ = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_z.base")!
    let cellZOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.cell_z.output_pointer")!
    LLVMBuildBr(builder, cellXHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, cellXHeaderBlock)
    let cellXIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_x.index")!
    let cellBaseX = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_x.base")!
    let cellXOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.cell_x.output_pointer")!
    LLVMBuildBr(builder, cellYHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, cellYHeaderBlock)
    let cellYIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_y.index")!
    let cellBaseY = LLVMBuildPhi(builder, context.int32Type, "density_buffer.cell_y.base")!
    let cellYOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.cell_y.output_pointer")!
    LLVMBuildBr(builder, localZHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, localZHeaderBlock)
    let localZIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_z.index")!
    let zCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_z.coord")!
    let localZOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.local_z.output_pointer")!
    LLVMBuildBr(builder, localXHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, localXHeaderBlock)
    let localXIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_x.index")!
    let xCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_x.coord")!
    let localXOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.local_x.output_pointer")!
    LLVMBuildBr(builder, localYHeaderBlock)

    LLVMPositionBuilderAtEnd(builder, localYHeaderBlock)
    let localYIndex = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_y.index")!
    let yCoord = LLVMBuildPhi(builder, context.int32Type, "density_buffer.local_y.coord")!
    let localYOutputPointer = LLVMBuildPhi(builder, bufferPointerType, "density_buffer.local_y.output_pointer")!

    let previousBulkGenerationCellState = context.bulkGenerationCellState
    context.bulkGenerationCellState = DensityFunctionCompilationContext.BulkGenerationCellState(
        cellXIndex: cellXIndex,
        cellYIndex: cellYIndex,
        cellZIndex: cellZIndex,
        cellStartX: cellBaseX,
        cellStartY: cellBaseY,
        cellStartZ: cellBaseZ,
        localXIndex: localXIndex,
        localYIndex: localYIndex,
        localZIndex: localZIndex,
        horizontalCount: cellCounts.horizontal,
        verticalCount: cellCounts.vertical
    )
    defer {
        context.bulkGenerationCellState = previousBulkGenerationCellState
    }
    let sampledValue = try root.compile(inContext: context, x: xCoord, y: yCoord, z: zCoord)
    let store = LLVMBuildStore(builder, sampledValue, localYOutputPointer)!
    LLVMSetAlignment(store, UInt32(doublePointerAlignmentBytes))

    let nextLocalYIndex = LLVMBuildAdd(builder, localYIndex, context.int32Constant(1), "density_buffer.local_y.index.next")!
    let nextYCoord = LLVMBuildAdd(builder, yCoord, context.int32Constant(1), "density_buffer.local_y.coord.next")!
    let nextLocalYOutputPointer = buildPointerAdvance(localYOutputPointer, by: 1, name: "density_buffer.local_y.output_pointer.next")
    let continueLocalY = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextLocalYIndex,
        context.int32Constant(cellCounts.vertical),
        "density_buffer.local_y.continue"
    )!
    LLVMBuildCondBr(builder, continueLocalY, localYHeaderBlock, localXAdvanceBlock)
    let localYEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, localXAdvanceBlock)
    let nextLocalXIndex = LLVMBuildAdd(builder, localXIndex, context.int32Constant(1), "density_buffer.local_x.index.next")!
    let nextXCoord = LLVMBuildAdd(builder, xCoord, context.int32Constant(1), "density_buffer.local_x.coord.next")!
    let nextLocalXOutputPointer = buildPointerAdvance(localXOutputPointer, by: rowStride, name: "density_buffer.local_x.output_pointer.next")
    let continueLocalX = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextLocalXIndex,
        context.int32Constant(cellCounts.horizontal),
        "density_buffer.local_x.continue"
    )!
    LLVMBuildCondBr(builder, continueLocalX, localXHeaderBlock, localZAdvanceBlock)
    let localXEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, localZAdvanceBlock)
    let nextLocalZIndex = LLVMBuildAdd(builder, localZIndex, context.int32Constant(1), "density_buffer.local_z.index.next")!
    let nextZCoord = LLVMBuildAdd(builder, zCoord, context.int32Constant(1), "density_buffer.local_z.coord.next")!
    let nextLocalZOutputPointer = buildPointerAdvance(localZOutputPointer, by: planeStride, name: "density_buffer.local_z.output_pointer.next")
    let continueLocalZ = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextLocalZIndex,
        context.int32Constant(cellCounts.horizontal),
        "density_buffer.local_z.continue"
    )!
    LLVMBuildCondBr(builder, continueLocalZ, localZHeaderBlock, cellYAdvanceBlock)
    let localZEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, cellYAdvanceBlock)
    let nextCellYIndex = LLVMBuildAdd(builder, cellYIndex, context.int32Constant(1), "density_buffer.cell_y.index.next")!
    let nextCellBaseY = LLVMBuildAdd(builder, cellBaseY, context.int32Constant(cellCounts.vertical), "density_buffer.cell_y.base.next")!
    let nextCellYOutputPointer = buildPointerAdvance(cellYOutputPointer, by: Int64(cellCounts.vertical), name: "density_buffer.cell_y.output_pointer.next")
    let continueCellY = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextCellYIndex,
        context.int32Constant(yCellCount),
        "density_buffer.cell_y.continue"
    )!
    LLVMBuildCondBr(builder, continueCellY, cellYHeaderBlock, cellXAdvanceBlock)
    let cellYEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, cellXAdvanceBlock)
    let nextCellXIndex = LLVMBuildAdd(builder, cellXIndex, context.int32Constant(1), "density_buffer.cell_x.index.next")!
    let nextCellBaseX = LLVMBuildAdd(builder, cellBaseX, context.int32Constant(cellCounts.horizontal), "density_buffer.cell_x.base.next")!
    let nextCellXOutputPointer = buildPointerAdvance(cellXOutputPointer, by: cellXPointerStride, name: "density_buffer.cell_x.output_pointer.next")
    let continueCellX = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextCellXIndex,
        context.int32Constant(xCellCount),
        "density_buffer.cell_x.continue"
    )!
    LLVMBuildCondBr(builder, continueCellX, cellXHeaderBlock, cellZAdvanceBlock)
    let cellXEndBlock = LLVMGetInsertBlock(builder)!

    LLVMPositionBuilderAtEnd(builder, cellZAdvanceBlock)
    let nextCellZIndex = LLVMBuildAdd(builder, cellZIndex, context.int32Constant(1), "density_buffer.cell_z.index.next")!
    let nextCellBaseZ = LLVMBuildAdd(builder, cellBaseZ, context.int32Constant(cellCounts.horizontal), "density_buffer.cell_z.base.next")!
    let nextCellZOutputPointer = buildPointerAdvance(cellZOutputPointer, by: cellZPointerStride, name: "density_buffer.cell_z.output_pointer.next")
    let continueCellZ = LLVMBuildICmp(
        builder,
        LLVMIntSLT,
        nextCellZIndex,
        context.int32Constant(zCellCount),
        "density_buffer.cell_z.continue"
    )!
    LLVMBuildCondBr(builder, continueCellZ, cellZHeaderBlock, returnBlock)
    let cellZEndBlock = LLVMGetInsertBlock(builder)!

    addIncoming(phi: cellZIndex, values: [context.int32Constant(0), nextCellZIndex], blocks: [startEndBlock, cellZEndBlock])
    addIncoming(phi: cellBaseZ, values: [baseZ, nextCellBaseZ], blocks: [startEndBlock, cellZEndBlock])
    addIncoming(phi: cellZOutputPointer, values: [outputBuffer, nextCellZOutputPointer], blocks: [startEndBlock, cellZEndBlock])
    addIncoming(phi: cellXIndex, values: [context.int32Constant(0), nextCellXIndex], blocks: [cellZHeaderBlock, cellXEndBlock])
    addIncoming(phi: cellBaseX, values: [baseX, nextCellBaseX], blocks: [cellZHeaderBlock, cellXEndBlock])
    addIncoming(phi: cellXOutputPointer, values: [cellZOutputPointer, nextCellXOutputPointer], blocks: [cellZHeaderBlock, cellXEndBlock])
    addIncoming(phi: cellYIndex, values: [context.int32Constant(0), nextCellYIndex], blocks: [cellXHeaderBlock, cellYEndBlock])
    addIncoming(phi: cellBaseY, values: [baseY, nextCellBaseY], blocks: [cellXHeaderBlock, cellYEndBlock])
    addIncoming(phi: cellYOutputPointer, values: [cellXOutputPointer, nextCellYOutputPointer], blocks: [cellXHeaderBlock, cellYEndBlock])
    addIncoming(phi: localZIndex, values: [context.int32Constant(0), nextLocalZIndex], blocks: [cellYHeaderBlock, localZEndBlock])
    addIncoming(phi: zCoord, values: [cellBaseZ, nextZCoord], blocks: [cellYHeaderBlock, localZEndBlock])
    addIncoming(phi: localZOutputPointer, values: [cellYOutputPointer, nextLocalZOutputPointer], blocks: [cellYHeaderBlock, localZEndBlock])
    addIncoming(phi: localXIndex, values: [context.int32Constant(0), nextLocalXIndex], blocks: [localZHeaderBlock, localXEndBlock])
    addIncoming(phi: xCoord, values: [cellBaseX, nextXCoord], blocks: [localZHeaderBlock, localXEndBlock])
    addIncoming(phi: localXOutputPointer, values: [localZOutputPointer, nextLocalXOutputPointer], blocks: [localZHeaderBlock, localXEndBlock])
    addIncoming(phi: localYIndex, values: [context.int32Constant(0), nextLocalYIndex], blocks: [localXHeaderBlock, localYEndBlock])
    addIncoming(phi: yCoord, values: [cellBaseY, nextYCoord], blocks: [localXHeaderBlock, localYEndBlock])
    addIncoming(phi: localYOutputPointer, values: [localXOutputPointer, nextLocalYOutputPointer], blocks: [localXHeaderBlock, localYEndBlock])
}

private func lowerDensityFunctionIR(
    _ program: DensityFunctionIRProgram,
    in context: DensityFunctionCompilationContext,
    inputs: [LLVMValueRef]
) -> LLVMValueRef {
    var values = inputs
    values.reserveCapacity(inputs.count + program.instructions.count)

    for instruction in program.instructions {
        let result: LLVMValueRef
        switch instruction {
        case .constant(let value):
            result = context.constant(value)
        case .constantInt32(let value):
            result = context.int32Constant(value)
        case .constantInt64(let value):
            result = context.int64Constant(UInt64(bitPattern: value))
        case .convertSignedIntToDouble(let input):
            result = LLVMBuildSIToFP(context.builder, values[input], context.doubleType, "density_ir.sitofp")!
        case .convertDoubleToSignedInt64(let input):
            result = LLVMBuildFPToSI(context.builder, values[input], context.int64Type, "density_ir.fptosi")!
        case .add(let lhs, let rhs):
            result = LLVMBuildFAdd(context.builder, values[lhs], values[rhs], "density_ir.add")!
        case .subtract(let lhs, let rhs):
            result = LLVMBuildFSub(context.builder, values[lhs], values[rhs], "density_ir.sub")!
        case .multiply(let lhs, let rhs):
            result = LLVMBuildFMul(context.builder, values[lhs], values[rhs], "density_ir.mul")!
        case .divide(let lhs, let rhs):
            result = LLVMBuildFDiv(context.builder, values[lhs], values[rhs], "density_ir.div")!
        case .negate(let input):
            result = LLVMBuildFNeg(context.builder, values[input], "density_ir.neg")!
        case .compare(let comparison, let lhs, let rhs):
            let predicate: LLVMRealPredicate = switch comparison {
            case .equal: LLVMRealOEQ
            case .lessThan: LLVMRealOLT
            case .lessThanOrEqual: LLVMRealOLE
            case .greaterThan: LLVMRealOGT
            case .greaterThanOrEqual: LLVMRealOGE
            }
            result = LLVMBuildFCmp(context.builder, predicate, values[lhs], values[rhs], "density_ir.compare")!
        case .and(let lhs, let rhs):
            result = LLVMBuildAnd(context.builder, values[lhs], values[rhs], "density_ir.and")!
        case .select(let condition, let whenTrue, let whenFalse):
            result = LLVMBuildSelect(
                context.builder,
                values[condition],
                values[whenTrue],
                values[whenFalse],
                "density_ir.select"
            )!
        case .sampleDensity(let index, let sampleX, let sampleY, let sampleZ):
            result = context.buildRuntimeDensitySampleCall(
                program.densityFunctions[index] as AnyObject,
                x: values[sampleX],
                y: values[sampleY],
                z: values[sampleZ],
                name: "density_ir.sample_density"
            )
        case .sampleNoise(let index, let sampleX, let sampleY, let sampleZ):
            result = context.buildRuntimeNoiseSampleCall(
                program.noises[index],
                x: values[sampleX],
                y: values[sampleY],
                z: values[sampleZ],
                name: "density_ir.sample_noise"
            )
        case .searchBiome(let index, let point):
            result = lowerBiomeSearchIR(
                program.biomeSearchTrees[index],
                point: point.map { values[$0] },
                in: context
            )
        }
        values.append(result)
    }
    return values[program.output]
}

private func lowerBiomeSearchIR(
    _ tree: BiomeSearchIRTree,
    point: [LLVMValueRef],
    in context: DensityFunctionCompilationContext
) -> LLVMValueRef {
    precondition(point.count == 7)
    let root = tree.nodes[tree.rootIndex]
    if root.isLeaf {
        return context.int32Constant(root.valueIndex)
    }

    let builder = context.builder
    let function = LLVMGetBasicBlockParent(LLVMGetInsertBlock(builder))!
    let bestDistancePointer = LLVMBuildAlloca(builder, context.int64Type, "biome.best_distance")!
    let bestIndexPointer = LLVMBuildAlloca(builder, context.int32Type, "biome.best_index")!
    LLVMBuildStore(builder, context.int64Constant(UInt64(Int64.max)), bestDistancePointer)
    LLVMBuildStore(builder, context.int32Constant(-1), bestIndexPointer)

    let earlyExitBlock = LLVMAppendBasicBlockInContext(context.llvmContext, function, "biome.zero_distance")!
    let mergeBlock = LLVMAppendBasicBlockInContext(context.llvmContext, function, "biome.merge")!
    var blockNumber = 0

    func makeBlock(_ name: String) -> LLVMBasicBlockRef {
        defer { blockNumber += 1 }
        return LLVMAppendBasicBlockInContext(context.llvmContext, function, "\(name).\(blockNumber)")!
    }

    func buildSquaredDistance(_ node: BiomeSearchIRNode, name: String) -> LLVMValueRef {
        var sum = context.int64Constant(0)
        for dimension in [2, 3, 5, 4, 0, 1, 6] {
            let minimum = context.int64Constant(UInt64(bitPattern: node.minimums[dimension]))
            let maximum = context.int64Constant(UInt64(bitPattern: node.maximums[dimension]))
            let below = LLVMBuildICmp(builder, LLVMIntSLT, point[dimension], minimum, "\(name).below")!
            let above = LLVMBuildICmp(builder, LLVMIntSGT, point[dimension], maximum, "\(name).above")!
            let belowDistance = LLVMBuildSub(builder, minimum, point[dimension], "\(name).below_distance")!
            let aboveDistance = LLVMBuildSub(builder, point[dimension], maximum, "\(name).above_distance")!
            let upperOrZero = LLVMBuildSelect(
                builder,
                above,
                aboveDistance,
                context.int64Constant(0),
                "\(name).upper_or_zero"
            )!
            let distance = LLVMBuildSelect(builder, below, belowDistance, upperOrZero, "\(name).distance")!
            let squared = LLVMBuildMul(builder, distance, distance, "\(name).squared")!
            sum = LLVMBuildAdd(builder, sum, squared, "\(name).sum")!
        }
        return sum
    }

    func emitVisit(_ nodeIndex: Int, continuation: LLVMBasicBlockRef) {
        let node = tree.nodes[nodeIndex]
        if node.isLeaf {
            let distance = buildSquaredDistance(node, name: "biome.leaf_\(nodeIndex)")
            let bestDistance = LLVMBuildLoad2(builder, context.int64Type, bestDistancePointer, "biome.best_distance.load")!
            let isBetter = LLVMBuildICmp(builder, LLVMIntSLE, distance, bestDistance, "biome.leaf.is_better")!
            let updateBlock = makeBlock("biome.leaf.update")
            LLVMBuildCondBr(builder, isBetter, updateBlock, continuation)

            LLVMPositionBuilderAtEnd(builder, updateBlock)
            LLVMBuildStore(builder, distance, bestDistancePointer)
            LLVMBuildStore(builder, context.int32Constant(node.valueIndex), bestIndexPointer)
            let isZero = LLVMBuildICmp(builder, LLVMIntEQ, distance, context.int64Constant(0), "biome.leaf.is_zero")!
            LLVMBuildCondBr(builder, isZero, earlyExitBlock, continuation)
            return
        }

        let childEnd = node.childIndexStart + node.childCount
        for childIndex in node.childIndexStart..<childEnd {
            let child = tree.nodes[childIndex]
            let distance = buildSquaredDistance(child, name: "biome.node_\(childIndex)")
            let bestDistance = LLVMBuildLoad2(builder, context.int64Type, bestDistancePointer, "biome.best_distance.load")!
            let shouldVisit = LLVMBuildICmp(builder, LLVMIntSLE, distance, bestDistance, "biome.node.should_visit")!
            let visitBlock = makeBlock("biome.node.visit")
            let nextBlock = makeBlock("biome.node.next")
            LLVMBuildCondBr(builder, shouldVisit, visitBlock, nextBlock)

            LLVMPositionBuilderAtEnd(builder, visitBlock)
            emitVisit(childIndex, continuation: nextBlock)
            LLVMPositionBuilderAtEnd(builder, nextBlock)
        }
        LLVMBuildBr(builder, continuation)
    }

    emitVisit(tree.rootIndex, continuation: mergeBlock)
    LLVMPositionBuilderAtEnd(builder, earlyExitBlock)
    LLVMBuildBr(builder, mergeBlock)
    LLVMPositionBuilderAtEnd(builder, mergeBlock)
    return LLVMBuildLoad2(builder, context.int32Type, bestIndexPointer, "biome.result")!
}

private func compileDensityFunctionIRWithLLVM(
    _ program: DensityFunctionIRProgram,
    registry: Registry<DensityFunction>
) throws -> CompiledDensityFunction {
    try JITCompiler.shared.withLock {
        for function in program.densityFunctions {
            JITCompiler.shared.retain(function as AnyObject)
        }
        JITCompiler.shared.retain(registry)

        guard let llvmContext = LLVMContextCreate() else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM context.")
        }
        var shouldDisposeContext = true
        defer {
            if shouldDisposeContext {
                LLVMContextDispose(llvmContext)
            }
        }

        let moduleName = "density_module_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let functionName = "density_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        guard let module = LLVMModuleCreateWithNameInContext(moduleName, llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM module.")
        }
        var shouldDisposeModule = true
        defer {
            if shouldDisposeModule {
                LLVMDisposeModule(module)
            }
        }

        guard let doubleType = LLVMDoubleTypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM double type.")
        }
        guard let int32Type = LLVMInt32TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i32 type.")
        }
        guard let int64Type = LLVMInt64TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i64 type.")
        }

        var parameterTypes: [LLVMTypeRef?] = [int32Type, int32Type, int32Type]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(doubleType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let function = LLVMAddFunction(module, functionName, functionType)
        guard let entryBlock = LLVMAppendBasicBlockInContext(llvmContext, function, "entry") else {
            throw DensityFunctionCompilationError.llvmError("Failed to create buffered compilation entry block.")
        }

        guard let builder = LLVMCreateBuilderInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM builder.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        LLVMPositionBuilderAtEnd(builder, entryBlock)
        let context = DensityFunctionCompilationContext(
            llvmContext: llvmContext,
            builder: builder,
            doubleType: doubleType,
            int32Type: int32Type,
            int64Type: int64Type,
            densityFunctionRegistry: registry
        )

        let result = lowerDensityFunctionIR(
            program,
            in: context,
            inputs: [
                LLVMGetParam(function, 0),
                LLVMGetParam(function, 1),
                LLVMGetParam(function, 2)
            ]
        )
        LLVMBuildRet(builder, result)

        try verify(module)
        try optimize(module)
        try verify(module)

        let threadSafeContext = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(llvmContext)
        shouldDisposeContext = false
        let threadSafeModule = LLVMOrcCreateNewThreadSafeModule(module, threadSafeContext)
        shouldDisposeModule = false
        LLVMOrcDisposeThreadSafeContext(threadSafeContext)

        var shouldDisposeThreadSafeModule = true
        defer {
            if shouldDisposeThreadSafeModule {
                LLVMOrcDisposeThreadSafeModule(threadSafeModule)
            }
        }

        try throwIfLLVMError(
            LLVMOrcLLJITAddLLVMIRModule(
                JITCompiler.shared.jit,
                LLVMOrcLLJITGetMainJITDylib(JITCompiler.shared.jit),
                threadSafeModule
            ),
            prefix: "Failed to add density function module to JIT"
        )
        shouldDisposeThreadSafeModule = false

        var address: LLVMOrcExecutorAddress = 0
        try throwIfLLVMError(
            LLVMOrcLLJITLookup(JITCompiler.shared.jit, &address, functionName),
            prefix: "Failed to resolve compiled density function"
        )

        let nativeFunction = unsafeBitCast(address, to: NativeCompiledDensityFunction.self)
        return CompiledDensityFunction(strategy: .llvm) { x, y, z in
            nativeFunction(x, y, z)
        }
    }
}

func compileBiomeSearchIRWithLLVM(
    _ program: DensityFunctionIRProgram,
    biomes: [RegistryKey<Biome>]
) throws -> CompiledBiomeSearchTree {
    try JITCompiler.shared.withLock {
        guard let llvmContext = LLVMContextCreate() else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM context.")
        }
        var shouldDisposeContext = true
        defer {
            if shouldDisposeContext { LLVMContextDispose(llvmContext) }
        }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let moduleName = "biome_search_module_\(suffix)"
        let functionName = "biome_search_\(suffix)"
        guard let module = LLVMModuleCreateWithNameInContext(moduleName, llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM module.")
        }
        var shouldDisposeModule = true
        defer {
            if shouldDisposeModule { LLVMDisposeModule(module) }
        }

        guard let doubleType = LLVMDoubleTypeInContext(llvmContext),
              let int32Type = LLVMInt32TypeInContext(llvmContext),
              let int64Type = LLVMInt64TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM primitive types.")
        }
        var parameterTypes: [LLVMTypeRef?] = Array(repeating: doubleType, count: 6)
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(int32Type, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let function = LLVMAddFunction(module, functionName, functionType)
        guard let entryBlock = LLVMAppendBasicBlockInContext(llvmContext, function, "entry"),
              let builder = LLVMCreateBuilderInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create biome search function.")
        }
        defer { LLVMDisposeBuilder(builder) }

        LLVMPositionBuilderAtEnd(builder, entryBlock)
        let context = DensityFunctionCompilationContext(
            llvmContext: llvmContext,
            builder: builder,
            doubleType: doubleType,
            int32Type: int32Type,
            int64Type: int64Type,
            densityFunctionRegistry: Registry<DensityFunction>()
        )
        let inputs = (0..<6).map { LLVMGetParam(function, UInt32($0))! }
        let result = lowerDensityFunctionIR(program, in: context, inputs: inputs)
        LLVMBuildRet(builder, result)

        try verify(module)
        try optimize(module)
        try verify(module)

        let threadSafeContext = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(llvmContext)
        shouldDisposeContext = false
        let threadSafeModule = LLVMOrcCreateNewThreadSafeModule(module, threadSafeContext)
        shouldDisposeModule = false
        LLVMOrcDisposeThreadSafeContext(threadSafeContext)

        var shouldDisposeThreadSafeModule = true
        defer {
            if shouldDisposeThreadSafeModule { LLVMOrcDisposeThreadSafeModule(threadSafeModule) }
        }
        try throwIfLLVMError(
            LLVMOrcLLJITAddLLVMIRModule(
                JITCompiler.shared.jit,
                LLVMOrcLLJITGetMainJITDylib(JITCompiler.shared.jit),
                threadSafeModule
            ),
            prefix: "Failed to add biome search module to JIT"
        )
        shouldDisposeThreadSafeModule = false

        var address: LLVMOrcExecutorAddress = 0
        try throwIfLLVMError(
            LLVMOrcLLJITLookup(JITCompiler.shared.jit, &address, functionName),
            prefix: "Failed to resolve compiled biome search"
        )
        let nativeFunction = unsafeBitCast(address, to: NativeCompiledBiomeSearch.self)
        return CompiledBiomeSearchTree(strategy: .llvm, biomes: biomes) {
            temperature, humidity, continentalness, erosion, weirdness, depth in
            nativeFunction(temperature, humidity, continentalness, erosion, weirdness, depth)
        }
    }
}

public func compile(
    densityFunction root: any DensityFunction,
    bufferContext: CompiledDensityFunctionBufferContext,
    strategy: CompilationBackend = .llvm,
    registry: Registry<DensityFunction> = Registry(),
    options: BufferedDensityFunctionCompilationOptions = BufferedDensityFunctionCompilationOptions()
) throws -> CompiledDensityFunctionBuffer {
    guard strategy == .llvm else {
        throw DensityFunctionCompilationError.unsupportedCompilationStrategy(strategy)
    }
    _ = try validateCompiledDensityFunctionBufferContext(bufferContext)

    if options.profilingState != nil {
        return try compileBufferedViaSwiftEvaluator(
            densityFunction: root,
            bufferContext: bufferContext,
            registry: registry,
            options: options
        )
    }

    guard let compilableRoot = root as? any CompilableDensityFunction else {
        return try compileBufferedViaSwiftEvaluator(
            densityFunction: root,
            bufferContext: bufferContext,
            registry: registry,
            options: options
        )
    }

    do {
        return try JITCompiler.shared.withLock {
            if type(of: compilableRoot) is AnyObject.Type {
                JITCompiler.shared.retain(compilableRoot as AnyObject)
            }
            JITCompiler.shared.retain(registry)

        guard let llvmContext = LLVMContextCreate() else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM context.")
        }
        var shouldDisposeContext = true
        defer {
            if shouldDisposeContext {
                LLVMContextDispose(llvmContext)
            }
        }

        let moduleName = "density_buffer_module_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let functionName = "density_buffer_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        guard let module = LLVMModuleCreateWithNameInContext(moduleName, llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM module.")
        }
        var shouldDisposeModule = true
        defer {
            if shouldDisposeModule {
                LLVMDisposeModule(module)
            }
        }

        guard let doubleType = LLVMDoubleTypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM double type.")
        }
        guard let int32Type = LLVMInt32TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i32 type.")
        }
        guard let int64Type = LLVMInt64TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i64 type.")
        }
        guard let voidType = LLVMVoidTypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM void type.")
        }
        guard
            let runtimeBufferContextType = makeCompiledDensityFunctionBufferContextLLVMType(in: llvmContext),
            let runtimeBufferContextPointerType = LLVMPointerType(runtimeBufferContextType, 0),
            let bufferPointerType = LLVMPointerType(doubleType, 0)
        else {
            throw DensityFunctionCompilationError.llvmError("Failed to create buffered compilation parameter types.")
        }

        var parameterTypes: [LLVMTypeRef?] = [
            runtimeBufferContextPointerType,
            int32Type,
            int32Type,
            int32Type,
            bufferPointerType
        ]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(voidType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let function = LLVMAddFunction(module, functionName, functionType)!
        addEnumAttribute(named: "noalias", to: function, index: 5, in: llvmContext)
        addEnumAttribute(named: "nocapture", to: function, index: 5, in: llvmContext)
        addEnumAttribute(named: "writeonly", to: function, index: 5, in: llvmContext)
        addEnumAttribute(named: "align", value: doublePointerAlignmentBytes, to: function, index: 5, in: llvmContext)
        guard let entryBlock = LLVMAppendBasicBlockInContext(llvmContext, function, "entry") else {
            throw DensityFunctionCompilationError.llvmError("Failed to create buffered compilation entry block.")
        }

        guard let builder = LLVMCreateBuilderInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM builder.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        let baseX = LLVMGetParam(function, 1)!
        let baseY = LLVMGetParam(function, 2)!
        let baseZ = LLVMGetParam(function, 3)!
        let outputBuffer = LLVMGetParam(function, 4)!
        LLVMPositionBuilderAtEnd(builder, entryBlock)
        let context = DensityFunctionCompilationContext(
            llvmContext: llvmContext,
            builder: builder,
            doubleType: doubleType,
            int32Type: int32Type,
            int64Type: int64Type,
            densityFunctionRegistry: registry,
            bulkInitialY: baseY,
            bulkBaseX: baseX,
            bulkBaseZ: baseZ,
            bulkBufferContext: bufferContext
        )
        let outputIsNull = LLVMBuildIsNull(builder, outputBuffer, "density_buffer.output_is_null")!
        let returnBlock = try appendBlock("density_buffer.return", in: context)

        let preferredCellCounts = findPreferredBulkGenerationCellCounts(in: root, registry: registry)
        let canUseGenerationCells = preferredCellCounts != nil
            && bufferContext.xStep == 1
            && bufferContext.yStep == 1
            && bufferContext.zStep == 1
            && bufferContext.xCount % preferredCellCounts!.horizontal == 0
            && bufferContext.yCount % preferredCellCounts!.vertical == 0
            && bufferContext.zCount % preferredCellCounts!.horizontal == 0

        if canUseGenerationCells, let preferredCellCounts {
            let dispatchBlock = try appendBlock("density_buffer.dispatch", in: context)
            let rawStartBlock = try appendBlock("density_buffer.raw.start", in: context)
            let cellStartBlock = try appendBlock("density_buffer.cell.start", in: context)
            LLVMBuildCondBr(builder, outputIsNull, returnBlock, dispatchBlock)

            LLVMPositionBuilderAtEnd(builder, dispatchBlock)
            let xRemainder = LLVMBuildSRem(builder, baseX, context.int32Constant(preferredCellCounts.horizontal), "density_buffer.cell_alignment.x_remainder")!
            let yRemainder = LLVMBuildSRem(builder, baseY, context.int32Constant(preferredCellCounts.vertical), "density_buffer.cell_alignment.y_remainder")!
            let zRemainder = LLVMBuildSRem(builder, baseZ, context.int32Constant(preferredCellCounts.horizontal), "density_buffer.cell_alignment.z_remainder")!
            let xAligned = LLVMBuildICmp(builder, LLVMIntEQ, xRemainder, context.int32Constant(0), "density_buffer.cell_alignment.x")!
            let yAligned = LLVMBuildICmp(builder, LLVMIntEQ, yRemainder, context.int32Constant(0), "density_buffer.cell_alignment.y")!
            let zAligned = LLVMBuildICmp(builder, LLVMIntEQ, zRemainder, context.int32Constant(0), "density_buffer.cell_alignment.z")!
            let xyAligned = context.buildAnd(xAligned, yAligned, name: "density_buffer.cell_alignment.xy")
            let useGenerationCells = context.buildAnd(xyAligned, zAligned, name: "density_buffer.cell_alignment.xyz")
            LLVMBuildCondBr(builder, useGenerationCells, cellStartBlock, rawStartBlock)

            try buildGenerationCellBulkSamplingLoop(
                root: compilableRoot,
                bufferContext: bufferContext,
                cellCounts: preferredCellCounts,
                context: context,
                baseX: baseX,
                baseY: baseY,
                baseZ: baseZ,
                outputBuffer: outputBuffer,
                startBlock: cellStartBlock,
                returnBlock: returnBlock
            )
            try buildRawBulkSamplingLoop(
                root: compilableRoot,
                bufferContext: bufferContext,
                context: context,
                baseX: baseX,
                baseY: baseY,
                baseZ: baseZ,
                outputBuffer: outputBuffer,
                startBlock: rawStartBlock,
                returnBlock: returnBlock
            )
        } else {
            let rawStartBlock = try appendBlock("density_buffer.raw.start", in: context)
            LLVMBuildCondBr(builder, outputIsNull, returnBlock, rawStartBlock)
            try buildRawBulkSamplingLoop(
                root: compilableRoot,
                bufferContext: bufferContext,
                context: context,
                baseX: baseX,
                baseY: baseY,
                baseZ: baseZ,
                outputBuffer: outputBuffer,
                startBlock: rawStartBlock,
                returnBlock: returnBlock
            )
        }

        LLVMPositionBuilderAtEnd(builder, returnBlock)
        LLVMBuildRetVoid(builder)

        try verify(module)
        try optimize(module)
        try verify(module)

        let threadSafeContext = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(llvmContext)
        shouldDisposeContext = false
        let threadSafeModule = LLVMOrcCreateNewThreadSafeModule(module, threadSafeContext)
        shouldDisposeModule = false
        LLVMOrcDisposeThreadSafeContext(threadSafeContext)

        var shouldDisposeThreadSafeModule = true
        defer {
            if shouldDisposeThreadSafeModule {
                LLVMOrcDisposeThreadSafeModule(threadSafeModule)
            }
        }

        try throwIfLLVMError(
            LLVMOrcLLJITAddLLVMIRModule(
                JITCompiler.shared.jit,
                LLVMOrcLLJITGetMainJITDylib(JITCompiler.shared.jit),
                threadSafeModule
            ),
            prefix: "Failed to add buffered density function module to JIT"
        )
        shouldDisposeThreadSafeModule = false

        var address: LLVMOrcExecutorAddress = 0
        try throwIfLLVMError(
            LLVMOrcLLJITLookup(JITCompiler.shared.jit, &address, functionName),
            prefix: "Failed to resolve compiled buffered density function"
        )

            return unsafeBitCast(address, to: CompiledDensityFunctionBuffer.self)
        }
    } catch DensityFunctionCompilationError.nonCompilableDensityFunction {
        return try compileBufferedViaSwiftEvaluator(
            densityFunction: root,
            bufferContext: bufferContext,
            registry: registry,
            options: options
        )
    }
}

private func compileBufferedViaSwiftEvaluator(
    densityFunction root: any DensityFunction,
    bufferContext: CompiledDensityFunctionBufferContext,
    registry: Registry<DensityFunction>,
    options: BufferedDensityFunctionCompilationOptions
) throws -> CompiledDensityFunctionBuffer {
    let plan = BufferedCompiledDensityFunctionPlan(
        root: root,
        registry: registry,
        bufferContext: bufferContext,
        options: options
    )
    return try compileBufferedRuntimePlan(plan, registry: registry)
}

func compileBufferedRuntimePlan(
    _ plan: any BufferedDensityFunctionRuntimePlan,
    registry: Registry<DensityFunction>
) throws -> CompiledDensityFunctionBuffer {
    try JITCompiler.shared.withLock {
        JITCompiler.shared.retain(plan)

        guard let llvmContext = LLVMContextCreate() else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM context.")
        }
        var shouldDisposeContext = true
        defer {
            if shouldDisposeContext {
                LLVMContextDispose(llvmContext)
            }
        }

        let moduleName = "density_buffer_module_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let functionName = "density_buffer_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        guard let module = LLVMModuleCreateWithNameInContext(moduleName, llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM module.")
        }
        var shouldDisposeModule = true
        defer {
            if shouldDisposeModule {
                LLVMDisposeModule(module)
            }
        }

        guard let doubleType = LLVMDoubleTypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM double type.")
        }
        guard let int32Type = LLVMInt32TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i32 type.")
        }
        guard let int64Type = LLVMInt64TypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM i64 type.")
        }
        guard let voidType = LLVMVoidTypeInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM void type.")
        }
        guard
            let runtimeBufferContextType = makeCompiledDensityFunctionBufferContextLLVMType(in: llvmContext),
            let runtimeBufferContextPointerType = LLVMPointerType(runtimeBufferContextType, 0),
            let bufferPointerType = LLVMPointerType(doubleType, 0)
        else {
            throw DensityFunctionCompilationError.llvmError("Failed to create buffered compilation parameter types.")
        }

        var parameterTypes: [LLVMTypeRef?] = [
            runtimeBufferContextPointerType,
            int32Type,
            int32Type,
            int32Type,
            bufferPointerType
        ]
        let functionType = parameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(voidType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let function = LLVMAddFunction(module, functionName, functionType)
        guard let entryBlock = LLVMAppendBasicBlockInContext(llvmContext, function, "entry") else {
            throw DensityFunctionCompilationError.llvmError("Failed to create buffered compilation entry block.")
        }

        guard let builder = LLVMCreateBuilderInContext(llvmContext) else {
            throw DensityFunctionCompilationError.llvmError("Failed to create LLVM builder.")
        }
        defer {
            LLVMDisposeBuilder(builder)
        }

        let baseX = LLVMGetParam(function, 1)
        let baseY = LLVMGetParam(function, 2)
        let baseZ = LLVMGetParam(function, 3)
        let outputBuffer = LLVMGetParam(function, 4)
        LLVMPositionBuilderAtEnd(builder, entryBlock)
        let context = DensityFunctionCompilationContext(
            llvmContext: llvmContext,
            builder: builder,
            doubleType: doubleType,
            int32Type: int32Type,
            int64Type: int64Type,
            densityFunctionRegistry: registry
        )
        var evaluatorParameterTypes: [LLVMTypeRef?] = [
            int64Type,
            runtimeBufferContextPointerType,
            int32Type,
            int32Type,
            int32Type,
            bufferPointerType
        ]
        let evaluatorFunctionType = evaluatorParameterTypes.withUnsafeMutableBufferPointer { buffer in
            LLVMFunctionType(voidType, buffer.baseAddress, UInt32(buffer.count), 0)
        }
        let evaluatorFunctionPointer = LLVMConstIntToPtr(
            context.int64Constant(bufferedDensityFunctionEvaluatorAddress()),
            LLVMPointerType(evaluatorFunctionType, 0)
        )
        var arguments: [LLVMValueRef?] = [
            context.int64Constant(opaquePointerBits(for: plan)),
            LLVMGetParam(function, 0),
            baseX,
            baseY,
            baseZ,
            outputBuffer
        ]
        let _ = arguments.withUnsafeMutableBufferPointer { buffer in
            LLVMBuildCall2(builder, evaluatorFunctionType, evaluatorFunctionPointer, buffer.baseAddress, UInt32(buffer.count), "")
        }
        LLVMBuildRetVoid(builder)

        try verify(module)

        let threadSafeContext = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(llvmContext)
        shouldDisposeContext = false
        let threadSafeModule = LLVMOrcCreateNewThreadSafeModule(module, threadSafeContext)
        shouldDisposeModule = false
        LLVMOrcDisposeThreadSafeContext(threadSafeContext)

        var shouldDisposeThreadSafeModule = true
        defer {
            if shouldDisposeThreadSafeModule {
                LLVMOrcDisposeThreadSafeModule(threadSafeModule)
            }
        }

        try throwIfLLVMError(
            LLVMOrcLLJITAddLLVMIRModule(
                JITCompiler.shared.jit,
                LLVMOrcLLJITGetMainJITDylib(JITCompiler.shared.jit),
                threadSafeModule
            ),
            prefix: "Failed to add buffered density function module to JIT"
        )
        shouldDisposeThreadSafeModule = false

        var address: LLVMOrcExecutorAddress = 0
        try throwIfLLVMError(
            LLVMOrcLLJITLookup(JITCompiler.shared.jit, &address, functionName),
            prefix: "Failed to resolve compiled buffered density function"
        )

        return unsafeBitCast(address, to: CompiledDensityFunctionBuffer.self)
    }
}

private func verify(_ module: LLVMModuleRef) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard LLVMVerifyModule(module, LLVMReturnStatusAction, &errorMessage) != 0 else {
        return
    }

    let message = errorMessage.map { String(cString: $0) } ?? "Unknown verification failure."
    if let errorMessage {
        LLVMDisposeMessage(errorMessage)
    }
    throw DensityFunctionCompilationError.llvmError("Failed to verify density function module: \(message)")
}

private func throwIfLLVMError(_ error: LLVMErrorRef?, prefix: String) throws {
    guard let error else {
        return
    }
    throw DensityFunctionCompilationError.llvmError("\(prefix): \(takeLLVMErrorMessage(error))")
}

private func takeLLVMErrorMessage(_ error: LLVMErrorRef) -> String {
    guard let message = LLVMGetErrorMessage(error) else {
        return "Unknown LLVM error."
    }
    defer {
        LLVMDisposeErrorMessage(message)
    }
    return String(cString: message)
}

private func currentFunction(in context: DensityFunctionCompilationContext) throws -> LLVMValueRef {
    guard let insertBlock = LLVMGetInsertBlock(context.builder), let function = LLVMGetBasicBlockParent(insertBlock) else {
        throw DensityFunctionCompilationError.llvmError("Builder is not positioned inside a function.")
    }
    return function
}

private func appendBlock(_ name: String, in context: DensityFunctionCompilationContext) throws -> LLVMBasicBlockRef {
    let function = try currentFunction(in: context)
    guard let block = LLVMAppendBasicBlockInContext(context.llvmContext, function, name) else {
        throw DensityFunctionCompilationError.llvmError("Failed to append LLVM block \(name).")
    }
    return block
}

private func addIncoming(
    phi: LLVMValueRef,
    values: [LLVMValueRef],
    blocks: [LLVMBasicBlockRef]
) {
    let count = UInt32(values.count)
    var incomingValues = values.map(Optional.some)
    var incomingBlocks = blocks.map(Optional.some)
    incomingValues.withUnsafeMutableBufferPointer { valueBuffer in
        incomingBlocks.withUnsafeMutableBufferPointer { blockBuffer in
            LLVMAddIncoming(phi, valueBuffer.baseAddress, blockBuffer.baseAddress, count)
        }
    }
}

private func densityFunctionInstancesMatch(_ lhs: any DensityFunction, _ rhs: any DensityFunction) -> Bool {
    guard type(of: lhs) is AnyObject.Type, type(of: rhs) is AnyObject.Type else {
        return false
    }
    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
}

private func compileUnaryOperation(
    _ operation: UnaryDensityFunction.OperationType,
    operand: LLVMValueRef,
    in context: DensityFunctionCompilationContext,
    name: String
) -> LLVMValueRef {
    switch operation {
    case .ABS:
        return context.buildAbs(operand, name: name)
    case .SQUARE:
        return LLVMBuildFMul(context.builder, operand, operand, name)
    case .CUBE:
        let squared = LLVMBuildFMul(context.builder, operand, operand, "\(name).square")
        return LLVMBuildFMul(context.builder, operand, squared, name)
    case .HALF_NEGATIVE:
        let isNegative = LLVMBuildFCmp(context.builder, LLVMRealOLT, operand, context.constant(0.0), "\(name).is_negative")
        let halved = LLVMBuildFMul(context.builder, operand, context.constant(0.5), "\(name).halved")
        return LLVMBuildSelect(context.builder, isNegative, halved, operand, name)
    case .QUARTER_NEGATIVE:
        let isNegative = LLVMBuildFCmp(context.builder, LLVMRealOLT, operand, context.constant(0.0), "\(name).is_negative")
        let quartered = LLVMBuildFMul(context.builder, operand, context.constant(0.25), "\(name).quartered")
        return LLVMBuildSelect(context.builder, isNegative, quartered, operand, name)
    case .SQUEEZE:
        let clampedHigh = context.buildMin(operand, context.constant(1.0), name: "\(name).clamped_high")
        let clamped = context.buildMax(clampedHigh, context.constant(-1.0), name: "\(name).clamped")
        let half = LLVMBuildFMul(context.builder, clamped, context.constant(0.5), "\(name).half")
        let squared = LLVMBuildFMul(context.builder, clamped, clamped, "\(name).square")
        let cubed = LLVMBuildFMul(context.builder, clamped, squared, "\(name).cube")
        let correction = LLVMBuildFDiv(context.builder, cubed, context.constant(24.0), "\(name).correction")
        return LLVMBuildFSub(context.builder, half, correction, name)
    case .INVERT:
        return LLVMBuildFDiv(context.builder, context.constant(1.0), operand, name)
    }
}

private func compileBinaryOperation(
    _ operation: BinaryDensityFunction.OperationType,
    first: LLVMValueRef,
    second: LLVMValueRef,
    in context: DensityFunctionCompilationContext,
    name: String
) -> LLVMValueRef {
    switch operation {
    case .ADD:
        return LLVMBuildFAdd(context.builder, first, second, name)
    case .MULTIPLY:
        return LLVMBuildFMul(context.builder, first, second, name)
    case .MINIMUM:
        return context.buildMin(first, second, name: name)
    case .MAXIMUM:
        return context.buildMax(first, second, name: name)
    }
}

private func compileRangeChoiceBranch(
    _ branch: any DensityFunction,
    inputChoice: any DensityFunction,
    inputValue: LLVMValueRef,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    y: LLVMValueRef,
    z: LLVMValueRef
) throws -> LLVMValueRef {
    if densityFunctionInstancesMatch(branch, inputChoice) {
        return inputValue
    }
    if let constant = branch as? ConstantDensityFunction {
        return context.constant(constant.constantValue)
    }
    if let unary = branch as? UnaryDensityFunction, densityFunctionInstancesMatch(unary.inputOperand, inputChoice) {
        return compileUnaryOperation(unary.operationType, operand: inputValue, in: context, name: "range_choice.branch.unary")
    }
    if let clampFunction = branch as? ClampDensityFunction, densityFunctionInstancesMatch(clampFunction.clampedInput, inputChoice) {
        let clampedHigh = context.buildMin(inputValue, context.constant(clampFunction.maximumValue), name: "range_choice.branch.clamp_high")
        return context.buildMax(clampedHigh, context.constant(clampFunction.minimumValue), name: "range_choice.branch.clamp")
    }
    if let binary = branch as? BinaryDensityFunction {
        let leftIsInput = densityFunctionInstancesMatch(binary.firstOperand, inputChoice)
        let rightIsInput = densityFunctionInstancesMatch(binary.secondOperand, inputChoice)
        if leftIsInput || rightIsInput {
            let otherOperand = leftIsInput ? binary.secondOperand : binary.firstOperand
            if let constant = otherOperand as? ConstantDensityFunction {
                return compileBinaryOperation(
                    binary.operationType,
                    first: inputValue,
                    second: context.constant(constant.constantValue),
                    in: context,
                    name: "range_choice.branch.binary_constant"
                )
            }

            let otherLowerBound = context.constant(otherOperand.lowerBoundValue())
            let otherUpperBound = context.constant(otherOperand.upperBoundValue())
            switch binary.operationType {
            case .ADD:
                guard let compilableOther = otherOperand as? any CompilableDensityFunction else {
                    throw DensityFunctionCompilationError.nonCompilableDensityFunction
                }
                let otherValue = try compilableOther.compile(inContext: context, x: x, y: y, z: z)
                return LLVMBuildFAdd(context.builder, inputValue, otherValue, "range_choice.branch.add")
            case .MULTIPLY:
                guard let compilableOther = otherOperand as? any CompilableDensityFunction else {
                    throw DensityFunctionCompilationError.nonCompilableDensityFunction
                }
                let isZero = LLVMBuildFCmp(context.builder, LLVMRealOEQ, inputValue, context.constant(0.0), "range_choice.branch.mul_is_zero")
                let otherValue = try compilableOther.compile(inContext: context, x: x, y: y, z: z)
                let multiplied = LLVMBuildFMul(context.builder, inputValue, otherValue, "range_choice.branch.mul")!
                return LLVMBuildSelect(context.builder, isZero, context.constant(0.0), multiplied, "range_choice.branch.mul_select")
            case .MINIMUM:
                let shortCircuit = LLVMBuildFCmp(context.builder, LLVMRealOLT, inputValue, otherLowerBound, "range_choice.branch.min_short_circuit")
                guard let compilableOther = otherOperand as? any CompilableDensityFunction else {
                    throw DensityFunctionCompilationError.nonCompilableDensityFunction
                }
                let otherValue = try compilableOther.compile(inContext: context, x: x, y: y, z: z)
                let result = context.buildMin(inputValue, otherValue, name: "range_choice.branch.min")
                return LLVMBuildSelect(context.builder, shortCircuit, inputValue, result, "range_choice.branch.min_select")
            case .MAXIMUM:
                let shortCircuit = LLVMBuildFCmp(context.builder, LLVMRealOGT, inputValue, otherUpperBound, "range_choice.branch.max_short_circuit")
                guard let compilableOther = otherOperand as? any CompilableDensityFunction else {
                    throw DensityFunctionCompilationError.nonCompilableDensityFunction
                }
                let otherValue = try compilableOther.compile(inContext: context, x: x, y: y, z: z)
                let result = context.buildMax(inputValue, otherValue, name: "range_choice.branch.max")
                return LLVMBuildSelect(context.builder, shortCircuit, inputValue, result, "range_choice.branch.max_select")
            }
        }
    }

    guard let compilableBranch = branch as? any CompilableDensityFunction else {
        throw DensityFunctionCompilationError.nonCompilableDensityFunction
    }
    return try compilableBranch.compile(inContext: context, x: x, y: y, z: z)
}

private func compileWeirdScale(
    _ type: WeirdScaledSampler.ScalingType,
    input: LLVMValueRef,
    in context: DensityFunctionCompilationContext
) -> LLVMValueRef {
    switch type {
    case .scaleTunnels:
        let ltNegHalf = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(-0.5), "weird_scaled_sampler.lt_neg_half")
        let ltZero = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(0.0), "weird_scaled_sampler.lt_zero")
        let ltHalf = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(0.5), "weird_scaled_sampler.lt_half")

        let aboveZero = LLVMBuildSelect(context.builder, ltHalf, context.constant(1.5), context.constant(2.0), "weird_scaled_sampler.above_zero")
        let nonNegative = LLVMBuildSelect(context.builder, ltZero, context.constant(1.0), aboveZero, "weird_scaled_sampler.non_negative")
        return LLVMBuildSelect(context.builder, ltNegHalf, context.constant(0.75), nonNegative, "weird_scaled_sampler.scale")
    case .scaleCaves:
        let ltNegThreeQuarters = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(-0.75), "weird_scaled_sampler.lt_neg_three_quarters")
        let ltNegHalf = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(-0.5), "weird_scaled_sampler.lt_neg_half")
        let ltHalf = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(0.5), "weird_scaled_sampler.lt_half")
        let ltThreeQuarters = LLVMBuildFCmp(context.builder, LLVMRealOLT, input, context.constant(0.75), "weird_scaled_sampler.lt_three_quarters")

        let upper = LLVMBuildSelect(context.builder, ltThreeQuarters, context.constant(2.0), context.constant(3.0), "weird_scaled_sampler.upper")
        let middle = LLVMBuildSelect(context.builder, ltHalf, context.constant(1.0), upper, "weird_scaled_sampler.middle")
        let negative = LLVMBuildSelect(context.builder, ltNegHalf, context.constant(0.75), middle, "weird_scaled_sampler.negative")
        return LLVMBuildSelect(context.builder, ltNegThreeQuarters, context.constant(0.5), negative, "weird_scaled_sampler.scale")
    }
}

private func compileSplineSegmentFloat(
    _ segment: SplineSegment,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    y: LLVMValueRef,
    z: LLVMValueRef
) throws -> LLVMValueRef {
    switch segment {
    case .number(let value):
        return context.floatConstant(value)
    case .object(let object):
        return try compileSplineObjectFloat(object, in: context, x: x, y: y, z: z)
    }
}

private func compileSplineOutsideRangeFloat(
    point: LLVMValueRef,
    location: Float,
    value: LLVMValueRef,
    derivative: Float,
    in context: DensityFunctionCompilationContext,
    name: String
) -> LLVMValueRef {
    if derivative == 0.0 {
        return value
    }

    let derivativeValue = context.floatConstant(derivative)
    let pointDelta = LLVMBuildFSub(context.builder, point, context.floatConstant(location), "\(name).delta")
    let scaledDelta = LLVMBuildFMul(context.builder, derivativeValue, pointDelta, "\(name).scaled_delta")
    return LLVMBuildFAdd(context.builder, value, scaledDelta, name)
}

private func compileSplineInterpolatedSegmentFloat(
    point: LLVMValueRef,
    lowerLocation: Float,
    upperLocation: Float,
    lowerDerivative: Float,
    upperDerivative: Float,
    lowerValue: LLVMValueRef,
    upperValue: LLVMValueRef,
    in context: DensityFunctionCompilationContext,
    name: String
) -> LLVMValueRef {
    let lowerLocationValue = context.floatConstant(lowerLocation)
    let locationDelta = upperLocation - lowerLocation
    let locationDeltaValue = context.floatConstant(locationDelta)
    let locationDeltaReciprocal = context.floatConstant(1.0 / locationDelta)
    let slope = LLVMBuildFMul(
        context.builder,
        LLVMBuildFSub(context.builder, point, lowerLocationValue, "\(name).point_delta"),
        locationDeltaReciprocal,
        "\(name).slope"
    )
    let valueDelta = LLVMBuildFSub(context.builder, upperValue, lowerValue, "\(name).value_delta")
    let p = LLVMBuildFSub(
        context.builder,
        LLVMBuildFMul(context.builder, context.floatConstant(lowerDerivative), locationDeltaValue, "\(name).p_scaled_derivative"),
        valueDelta,
        "\(name).p"
    )
    let q = LLVMBuildFAdd(
        context.builder,
        LLVMBuildFNeg(
            context.builder,
            LLVMBuildFMul(context.builder, context.floatConstant(upperDerivative), locationDeltaValue, "\(name).q_scaled_derivative"),
            "\(name).q_negated_derivative"
        ),
        valueDelta,
        "\(name).q"
    )
    let lerpedValue = LLVMBuildFAdd(
        context.builder,
        lowerValue,
        LLVMBuildFMul(context.builder, slope, valueDelta, "\(name).lerped_delta"),
        "\(name).lerped_value"
    )
    let lerpedTangent = LLVMBuildFAdd(
        context.builder,
        p,
        LLVMBuildFMul(
            context.builder,
            slope,
            LLVMBuildFSub(context.builder, q, p, "\(name).tangent_delta"),
            "\(name).tangent_lerp_delta"
        ),
        "\(name).lerped_tangent"
    )
    let slopeProduct = LLVMBuildFMul(
        context.builder,
        slope,
        LLVMBuildFSub(context.builder, context.floatConstant(1.0), slope, "\(name).one_minus_slope"),
        "\(name).slope_product"
    )
    return LLVMBuildFAdd(
        context.builder,
        lerpedValue,
        LLVMBuildFMul(context.builder, slopeProduct, lerpedTangent, "\(name).tangent_term"),
        name
    )
}

private func compileSplineIntervalSearchEntry(
    intervalRange: Range<Int>,
    point: LLVMValueRef,
    locations: [Float],
    intervalBlocks: [LLVMBasicBlockRef],
    in context: DensityFunctionCompilationContext
) throws -> LLVMBasicBlockRef {
    precondition(!intervalRange.isEmpty, "Spline interval search requires a non-empty interval range.")
    if intervalRange.count == 1 {
        return intervalBlocks[intervalRange.lowerBound]
    }

    let searchBlock = try appendBlock("spline.search", in: context)
    let splitIndex = intervalRange.lowerBound + intervalRange.count / 2
    let lowerEntry = try compileSplineIntervalSearchEntry(
        intervalRange: intervalRange.lowerBound..<splitIndex,
        point: point,
        locations: locations,
        intervalBlocks: intervalBlocks,
        in: context
    )
    let upperEntry = try compileSplineIntervalSearchEntry(
        intervalRange: splitIndex..<intervalRange.upperBound,
        point: point,
        locations: locations,
        intervalBlocks: intervalBlocks,
        in: context
    )

    LLVMPositionBuilderAtEnd(context.builder, searchBlock)
    let isBeforeSplit = LLVMBuildFCmp(
        context.builder,
        LLVMRealOLT,
        point,
        context.floatConstant(locations[splitIndex]),
        "spline.search.before_split"
    )
    LLVMBuildCondBr(context.builder, isBeforeSplit, lowerEntry, upperEntry)
    return searchBlock
}

private func compileSplineObjectFloat(
    _ object: SplineObject,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    y: LLVMValueRef,
    z: LLVMValueRef
) throws -> LLVMValueRef {
    let locations = object.pointLocations
    let values = object.pointValues
    let derivatives = object.pointDerivatives

    guard !locations.isEmpty else {
        throw DensityFunctionCompilationError.badDensityFunction("Spline must have at least one point.")
    }
    guard locations.count == values.count, values.count == derivatives.count else {
        throw DensityFunctionCompilationError.badDensityFunction("Spline point arrays have mismatched lengths.")
    }
    guard let input = object.inputFunction as? any CompilableDensityFunction else {
        throw DensityFunctionCompilationError.nonCompilableDensityFunction
    }

    let point = context.buildFloatTrunc(
        try input.compile(inContext: context, x: x, y: y, z: z),
        name: "spline.point"
    )
    let entryBlock = LLVMGetInsertBlock(context.builder)!

    let mergeBlock = try appendBlock("spline.merge", in: context)
    let leftBlock = try appendBlock("spline.left", in: context)
    let rightBlock = try appendBlock("spline.right", in: context)
    let intervalBlocks = try (0..<max(0, locations.count - 1)).map { _ in try appendBlock("spline.interval", in: context) }
    let interiorEntryBlock: LLVMBasicBlockRef?
    if locations.count > 1 {
        interiorEntryBlock = try compileSplineIntervalSearchEntry(
            intervalRange: 0..<(locations.count - 1),
            point: point,
            locations: locations,
            intervalBlocks: intervalBlocks,
            in: context
        )
    } else {
        interiorEntryBlock = nil
    }
    let nonLeftBlock = try appendBlock("spline.non_left", in: context)
    LLVMPositionBuilderAtEnd(context.builder, entryBlock)

    let isLeft = LLVMBuildFCmp(context.builder, LLVMRealOLT, point, context.floatConstant(locations[0]), "spline.is_left")
    LLVMBuildCondBr(context.builder, isLeft, leftBlock, nonLeftBlock)

    var incomingValues: [LLVMValueRef] = []
    var incomingBlocks: [LLVMBasicBlockRef] = []

    LLVMPositionBuilderAtEnd(context.builder, nonLeftBlock)
    if let interiorEntryBlock {
        let isBeforeRight = LLVMBuildFCmp(
            context.builder,
            LLVMRealOLT,
            point,
            context.floatConstant(locations[locations.count - 1]),
            "spline.is_before_right"
        )
        LLVMBuildCondBr(context.builder, isBeforeRight, interiorEntryBlock, rightBlock)
    } else {
        LLVMBuildBr(context.builder, rightBlock)
    }

    LLVMPositionBuilderAtEnd(context.builder, leftBlock)
    let leftValue = try compileSplineSegmentFloat(values[0], in: context, x: x, y: y, z: z)
    let leftResult = compileSplineOutsideRangeFloat(
        point: point,
        location: locations[0],
        value: leftValue,
        derivative: derivatives[0],
        in: context,
        name: "spline.left_value"
    )
    LLVMBuildBr(context.builder, mergeBlock)
    incomingValues.append(leftResult)
    incomingBlocks.append(LLVMGetInsertBlock(context.builder)!)

    for index in 0..<intervalBlocks.count {
        let intervalBlock = intervalBlocks[index]
        LLVMPositionBuilderAtEnd(context.builder, intervalBlock)
        let lowerValue = try compileSplineSegmentFloat(values[index], in: context, x: x, y: y, z: z)
        let upperValue = try compileSplineSegmentFloat(values[index + 1], in: context, x: x, y: y, z: z)
        let intervalResult = compileSplineInterpolatedSegmentFloat(
            point: point,
            lowerLocation: locations[index],
            upperLocation: locations[index + 1],
            lowerDerivative: derivatives[index],
            upperDerivative: derivatives[index + 1],
            lowerValue: lowerValue,
            upperValue: upperValue,
            in: context,
            name: "spline.interval_value"
        )
        LLVMBuildBr(context.builder, mergeBlock)
        incomingValues.append(intervalResult)
        incomingBlocks.append(LLVMGetInsertBlock(context.builder)!)
    }

    LLVMPositionBuilderAtEnd(context.builder, rightBlock)
    let lastIndex = locations.count - 1
    let rightValue = try compileSplineSegmentFloat(values[lastIndex], in: context, x: x, y: y, z: z)
    let rightResult = compileSplineOutsideRangeFloat(
        point: point,
        location: locations[lastIndex],
        value: rightValue,
        derivative: derivatives[lastIndex],
        in: context,
        name: "spline.right_value"
    )
    LLVMBuildBr(context.builder, mergeBlock)
    incomingValues.append(rightResult)
    incomingBlocks.append(LLVMGetInsertBlock(context.builder)!)

    LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
    let phi = LLVMBuildPhi(context.builder, LLVMFloatTypeInContext(context.llvmContext), "spline.result")!
    addIncoming(phi: phi, values: incomingValues, blocks: incomingBlocks)
    return phi
}

protocol CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef
}

extension DensityFunctionWrapperIntrospectable where Self: DensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        return try wrapped.compile(inContext: context, x: x, y: y, z: z)
    }
}

extension WorldScaleCache2D: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        return try compileWorldScaleCache2DValue(
            cacheIdentity: ObjectIdentifier(self),
            wrapped: wrapped,
            in: context,
            x: x,
            y: y,
            z: z,
            prefix: "world_scale_cache_2d"
        )
    }
}

extension ChunkCache2D: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        return try compileWorldScaleCache2DValue(
            cacheIdentity: ObjectIdentifier(self),
            wrapped: wrapped,
            in: context,
            x: x,
            y: y,
            z: z,
            prefix: "chunk_cache_2d"
        )
    }
}

extension WorldScaleFlatCache: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        return try compileWorldScaleFlatCacheValue(
            cacheIdentity: ObjectIdentifier(self),
            wrapped: wrapped,
            in: context,
            x: x,
            z: z,
            prefix: "world_scale_flat_cache"
        )
    }
}

extension ChunkFlatCache: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        return try compileWorldScaleFlatCacheValue(
            cacheIdentity: ObjectIdentifier(self),
            wrapped: wrapped,
            in: context,
            x: x,
            z: z,
            prefix: "chunk_flat_cache"
        )
    }
}

extension ChunkInterpolatedCache: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }

        let bounds = self.bufferedSamplingBounds
        let isInsideX = context.buildIntInHalfOpenRange(x, lowerBound: bounds.minX, upperBound: bounds.maxXExclusive, name: "chunk_interpolated_cache.inside_x")
        let isInsideY = context.buildIntInHalfOpenRange(y, lowerBound: bounds.minY, upperBound: bounds.maxYExclusive, name: "chunk_interpolated_cache.inside_y")
        let isInsideZ = context.buildIntInHalfOpenRange(z, lowerBound: bounds.minZ, upperBound: bounds.maxZExclusive, name: "chunk_interpolated_cache.inside_z")
        let isInsideXY = context.buildAnd(isInsideX, isInsideY, name: "chunk_interpolated_cache.inside_xy")
        let isInside = context.buildAnd(isInsideXY, isInsideZ, name: "chunk_interpolated_cache.is_inside")

        let insideValue = try compileChunkInterpolatedValue(
            wrapped,
            cacheIdentity: ObjectIdentifier(self),
            inContext: context,
            x: x,
            y: y,
            z: z,
            horizontalCellBlockCount: self.bufferedHorizontalCellBlockCount,
            verticalCellBlockCount: self.bufferedVerticalCellBlockCount,
            name: "chunk_interpolated_cache.inside"
        )
        let outsideValue = try wrapped.compile(inContext: context, x: x, y: y, z: z)
        return LLVMBuildSelect(context.builder, isInside, insideValue, outsideValue, "chunk_interpolated_cache")!
    }
}

extension CacheMarker: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let wrapped = self.wrappedDensityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        switch self.type {
        case .cache2D:
            return try compileWorldScaleCache2DValue(
                cacheIdentity: ObjectIdentifier(self),
                wrapped: wrapped,
                in: context,
                x: x,
                y: y,
                z: z,
                prefix: "cache_marker_cache_2d"
            )
        case .flatCache:
            return try compileWorldScaleFlatCacheValue(
                cacheIdentity: ObjectIdentifier(self),
                wrapped: wrapped,
                in: context,
                x: x,
                z: z,
                prefix: "cache_marker_flat_cache"
            )
        case .cacheOnce, .cacheAllInCell, .interpolated:
            return try context.cachedCompile(self, x: x, y: y, z: z) {
                try wrapped.compile(inContext: context, x: x, y: y, z: z)
            }
        }
    }
}

private func compileCoordinate2DCacheValue(
    storage: DensityFunctionCompilationContext.Coordinate2DCacheStorage,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    z: LLVMValueRef,
    name: String,
    buildValue: () throws -> LLVMValueRef
) throws -> LLVMValueRef {
    let reuseBlock = try appendBlock("\(name).reuse", in: context)
    let computeBlock = try appendBlock("\(name).compute", in: context)
    let mergeBlock = try appendBlock("\(name).merge", in: context)

    let cachedValid = LLVMBuildLoad2(
        context.builder,
        LLVMInt1TypeInContext(context.llvmContext),
        storage.valid,
        "\(name).valid"
    )!
    let cachedX = LLVMBuildLoad2(context.builder, context.int32Type, storage.x, "\(name).x")!
    let cachedZ = LLVMBuildLoad2(context.builder, context.int32Type, storage.z, "\(name).z")!
    let sameX = LLVMBuildICmp(context.builder, LLVMIntEQ, x, cachedX, "\(name).same_x")!
    let sameZ = LLVMBuildICmp(context.builder, LLVMIntEQ, z, cachedZ, "\(name).same_z")!
    let sameXZ = context.buildAnd(sameX, sameZ, name: "\(name).same_xz")
    let canReuse = context.buildAnd(cachedValid, sameXZ, name: "\(name).can_reuse")
    LLVMBuildCondBr(context.builder, canReuse, reuseBlock, computeBlock)

    LLVMPositionBuilderAtEnd(context.builder, reuseBlock)
    let reusedValue = LLVMBuildLoad2(context.builder, context.doubleType, storage.value, "\(name).reused_value")!
    LLVMBuildBr(context.builder, mergeBlock)
    let reuseEndBlock = LLVMGetInsertBlock(context.builder)!

    LLVMPositionBuilderAtEnd(context.builder, computeBlock)
    let computedValue = try buildValue()
    LLVMBuildStore(context.builder, x, storage.x)
    LLVMBuildStore(context.builder, z, storage.z)
    LLVMBuildStore(context.builder, computedValue, storage.value)
    LLVMBuildStore(context.builder, LLVMConstInt(LLVMInt1TypeInContext(context.llvmContext), 1, 0), storage.valid)
    LLVMBuildBr(context.builder, mergeBlock)
    let computeEndBlock = LLVMGetInsertBlock(context.builder)!

    LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
    let phi = LLVMBuildPhi(context.builder, context.doubleType, "\(name).result")!
    addIncoming(phi: phi, values: [reusedValue, computedValue], blocks: [reuseEndBlock, computeEndBlock])
    return phi
}

private func compileWorldScaleCache2DValue(
    cacheIdentity: ObjectIdentifier,
    wrapped: any CompilableDensityFunction,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    y: LLVMValueRef,
    z: LLVMValueRef,
    prefix: String
) throws -> LLVMValueRef {
    if let bulkBufferContext = context.bulkBufferContext,
       bulkBufferContext.xStep == 1,
       bulkBufferContext.zStep == 1,
       let bulkCell = context.bulkGenerationCellState {
        let width = bulkBufferContext.xCount
        let depth = bulkBufferContext.zCount
        let localColumnCount = Int(width * depth)
        let storage = try context.bulkCoordinate2DCacheStorage(
            for: cacheIdentity,
            localColumnCount: localColumnCount,
            prefix: prefix
        )
        let localXBase = LLVMBuildMul(
            context.builder,
            bulkCell.cellXIndex,
            context.int32Constant(bulkCell.horizontalCount),
            "\(prefix).local_x_base"
        )!
        let localX = LLVMBuildAdd(context.builder, localXBase, bulkCell.localXIndex, "\(prefix).local_x")!
        let localZBase = LLVMBuildMul(
            context.builder,
            bulkCell.cellZIndex,
            context.int32Constant(bulkCell.horizontalCount),
            "\(prefix).local_z_base"
        )!
        let localZ = LLVMBuildAdd(context.builder, localZBase, bulkCell.localZIndex, "\(prefix).local_z")!
        let localColumnIndex = LLVMBuildAdd(
            context.builder,
            LLVMBuildMul(context.builder, localZ, context.int32Constant(width), "\(prefix).local_z_scaled")!,
            localX,
            "\(prefix).local_column_index"
        )!
        let localValuePointer = context.buildArrayElementPointer(
            storage.localValues,
            elementType: context.doubleType,
            count: localColumnCount,
            index: localColumnIndex,
            name: "\(prefix).local_value_pointer"
        )
        let hasCachedColumnValue = LLVMBuildOr(
            context.builder,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.cellYIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_column_value.cell_y"
            )!,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.localYIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_column_value.local_y"
            )!,
            "\(prefix).has_cached_column_value"
        )!
        let reuseBlock = try appendBlock("\(prefix).reuse", in: context)
        let computeBlock = try appendBlock("\(prefix).compute", in: context)
        let mergeBlock = try appendBlock("\(prefix).merge", in: context)
        LLVMBuildCondBr(context.builder, hasCachedColumnValue, reuseBlock, computeBlock)

        LLVMPositionBuilderAtEnd(context.builder, reuseBlock)
        let reusedValue = LLVMBuildLoad2(context.builder, context.doubleType, localValuePointer, "\(prefix).reused_value")!
        LLVMBuildBr(context.builder, mergeBlock)
        let reuseEndBlock = LLVMGetInsertBlock(context.builder)!

        LLVMPositionBuilderAtEnd(context.builder, computeBlock)
        let computedValue = try wrapped.compile(inContext: context, x: x, y: context.bulkInitialY ?? y, z: z)
        LLVMBuildStore(context.builder, computedValue, localValuePointer)
        LLVMBuildBr(context.builder, mergeBlock)
        let computeEndBlock = LLVMGetInsertBlock(context.builder)!

        LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
        let result = LLVMBuildPhi(context.builder, context.doubleType, "\(prefix).result")!
        addIncoming(
            phi: result,
            values: [reusedValue, computedValue],
            blocks: [reuseEndBlock, computeEndBlock]
        )
        return result
    }

    let storage = try context.coordinate2DCacheStorage(for: cacheIdentity, prefix: prefix)
    return try compileCoordinate2DCacheValue(
        storage: storage,
        in: context,
        x: x,
        z: z,
        name: prefix
    ) {
        try wrapped.compile(inContext: context, x: x, y: context.bulkInitialY ?? y, z: z)
    }
}

private func compileWorldScaleFlatCacheValue(
    cacheIdentity: ObjectIdentifier,
    wrapped: any CompilableDensityFunction,
    in context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    z: LLVMValueRef,
    prefix: String
) throws -> LLVMValueRef {
    let columnX: LLVMValueRef
    let columnZ: LLVMValueRef
    let sampleX: LLVMValueRef
    let sampleZ: LLVMValueRef
    if let bulkCell = context.bulkGenerationCellState, bulkCell.horizontalCount == 4 {
        columnX = context.buildFloorDiv(bulkCell.cellStartX, by: 4, name: "\(prefix).bulk_column_x")
        columnZ = context.buildFloorDiv(bulkCell.cellStartZ, by: 4, name: "\(prefix).bulk_column_z")
        sampleX = bulkCell.cellStartX
        sampleZ = bulkCell.cellStartZ
    } else {
        columnX = context.buildFloorDiv(x, by: 4, name: "\(prefix).column_x")
        columnZ = context.buildFloorDiv(z, by: 4, name: "\(prefix).column_z")
        sampleX = LLVMBuildMul(context.builder, columnX, context.int32Constant(4), "\(prefix).sample_x")!
        sampleZ = LLVMBuildMul(context.builder, columnZ, context.int32Constant(4), "\(prefix).sample_z")!
    }

    if let bulkBufferContext = context.bulkBufferContext,
       bulkBufferContext.xStep == 1,
       bulkBufferContext.zStep == 1,
       let bulkCell = context.bulkGenerationCellState {
        let width = bulkBufferContext.xCount / bulkCell.horizontalCount
        let depth = bulkBufferContext.zCount / bulkCell.horizontalCount
        let localColumnCount = Int(width * depth)
        let storage = try context.bulkCoordinate2DCacheStorage(
            for: cacheIdentity,
            localColumnCount: localColumnCount,
            prefix: prefix
        )
        let localColumnIndex = LLVMBuildAdd(
            context.builder,
            LLVMBuildMul(context.builder, bulkCell.cellZIndex, context.int32Constant(width), "\(prefix).local_column_z_scaled")!,
            bulkCell.cellXIndex,
            "\(prefix).local_column_index"
        )!
        let localValuePointer = context.buildArrayElementPointer(
            storage.localValues,
            elementType: context.doubleType,
            count: localColumnCount,
            index: localColumnIndex,
            name: "\(prefix).local_value_pointer"
        )
        let hasCachedCellValueZY = LLVMBuildOr(
            context.builder,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.cellYIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_cell_value.cell_y"
            )!,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.localZIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_cell_value.local_z"
            )!,
            "\(prefix).has_cached_cell_value.zy"
        )!
        let hasCachedCellValueXY = LLVMBuildOr(
            context.builder,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.localXIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_cell_value.local_x"
            )!,
            LLVMBuildICmp(
                context.builder,
                LLVMIntNE,
                bulkCell.localYIndex,
                context.int32Constant(0),
                "\(prefix).has_cached_cell_value.local_y"
            )!,
            "\(prefix).has_cached_cell_value.xy"
        )!
        let hasCachedCellValue = LLVMBuildOr(
            context.builder,
            hasCachedCellValueZY,
            hasCachedCellValueXY,
            "\(prefix).has_cached_cell_value"
        )!
        let reuseBlock = try appendBlock("\(prefix).reuse", in: context)
        let computeBlock = try appendBlock("\(prefix).compute", in: context)
        let mergeBlock = try appendBlock("\(prefix).merge", in: context)
        LLVMBuildCondBr(context.builder, hasCachedCellValue, reuseBlock, computeBlock)

        LLVMPositionBuilderAtEnd(context.builder, reuseBlock)
        let reusedValue = LLVMBuildLoad2(context.builder, context.doubleType, localValuePointer, "\(prefix).reused_value")!
        LLVMBuildBr(context.builder, mergeBlock)
        let reuseEndBlock = LLVMGetInsertBlock(context.builder)!

        LLVMPositionBuilderAtEnd(context.builder, computeBlock)
        let computedValue = try wrapped.compile(inContext: context, x: sampleX, y: context.int32Constant(0), z: sampleZ)
        LLVMBuildStore(context.builder, computedValue, localValuePointer)
        LLVMBuildBr(context.builder, mergeBlock)
        let computeEndBlock = LLVMGetInsertBlock(context.builder)!

        LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
        let result = LLVMBuildPhi(context.builder, context.doubleType, "\(prefix).result")!
        addIncoming(
            phi: result,
            values: [reusedValue, computedValue],
            blocks: [reuseEndBlock, computeEndBlock]
        )
        return result
    }

    let storage = try context.coordinate2DCacheStorage(for: cacheIdentity, prefix: prefix)
    return try compileCoordinate2DCacheValue(
        storage: storage,
        in: context,
        x: columnX,
        z: columnZ,
        name: prefix
    ) {
        try wrapped.compile(inContext: context, x: sampleX, y: context.int32Constant(0), z: sampleZ)
    }
}

private func compileChunkInterpolatedValue(
    _ wrapped: any CompilableDensityFunction,
    cacheIdentity: ObjectIdentifier,
    inContext context: DensityFunctionCompilationContext,
    x: LLVMValueRef,
    y: LLVMValueRef,
    z: LLVMValueRef,
    horizontalCellBlockCount: Int32,
    verticalCellBlockCount: Int32,
    name: String
) throws -> LLVMValueRef {
    let alignedBulkCellState = context.bulkGenerationCellState.flatMap { bulkCell in
        if bulkCell.horizontalCount == horizontalCellBlockCount, bulkCell.verticalCount == verticalCellBlockCount {
            return bulkCell
        }
        return nil
    }

    let cellStartX: LLVMValueRef
    let cellStartY: LLVMValueRef
    let cellStartZ: LLVMValueRef
    let deltaX: LLVMValueRef
    let deltaY: LLVMValueRef
    let deltaZ: LLVMValueRef
    let horizontalReciprocal = context.constant(1.0 / Double(horizontalCellBlockCount))
    let verticalReciprocal = context.constant(1.0 / Double(verticalCellBlockCount))

    if let bulkCell = alignedBulkCellState {
        cellStartX = bulkCell.cellStartX
        cellStartY = bulkCell.cellStartY
        cellStartZ = bulkCell.cellStartZ
        deltaX = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, bulkCell.localXIndex, context.doubleType, "\(name).delta_x.fp")!,
            horizontalReciprocal,
            "\(name).delta_x"
        )!
        deltaY = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, bulkCell.localYIndex, context.doubleType, "\(name).delta_y.fp")!,
            verticalReciprocal,
            "\(name).delta_y"
        )!
        deltaZ = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, bulkCell.localZIndex, context.doubleType, "\(name).delta_z.fp")!,
            horizontalReciprocal,
            "\(name).delta_z"
        )!
    } else {
        cellStartX = LLVMBuildMul(
            context.builder,
            context.buildFloorDiv(x, by: horizontalCellBlockCount, name: "\(name).cell_start_x.floor_div"),
            context.int32Constant(horizontalCellBlockCount),
            "\(name).cell_start_x"
        )!
        cellStartY = LLVMBuildMul(
            context.builder,
            context.buildFloorDiv(y, by: verticalCellBlockCount, name: "\(name).cell_start_y.floor_div"),
            context.int32Constant(verticalCellBlockCount),
            "\(name).cell_start_y"
        )!
        cellStartZ = LLVMBuildMul(
            context.builder,
            context.buildFloorDiv(z, by: horizontalCellBlockCount, name: "\(name).cell_start_z.floor_div"),
            context.int32Constant(horizontalCellBlockCount),
            "\(name).cell_start_z"
        )!

        let deltaXNumerator = LLVMBuildSub(context.builder, x, cellStartX, "\(name).delta_x.numerator")!
        let deltaYNumerator = LLVMBuildSub(context.builder, y, cellStartY, "\(name).delta_y.numerator")!
        let deltaZNumerator = LLVMBuildSub(context.builder, z, cellStartZ, "\(name).delta_z.numerator")!

        deltaX = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, deltaXNumerator, context.doubleType, "\(name).delta_x.fp")!,
            horizontalReciprocal,
            "\(name).delta_x"
        )!
        deltaY = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, deltaYNumerator, context.doubleType, "\(name).delta_y.fp")!,
            verticalReciprocal,
            "\(name).delta_y"
        )!
        deltaZ = LLVMBuildFMul(
            context.builder,
            LLVMBuildSIToFP(context.builder, deltaZNumerator, context.doubleType, "\(name).delta_z.fp")!,
            horizontalReciprocal,
            "\(name).delta_z"
        )!
    }

    let cellEndX = LLVMBuildAdd(context.builder, cellStartX, context.int32Constant(horizontalCellBlockCount), "\(name).cell_end_x")!
    let cellEndY = LLVMBuildAdd(context.builder, cellStartY, context.int32Constant(verticalCellBlockCount), "\(name).cell_end_y")!
    let cellEndZ = LLVMBuildAdd(context.builder, cellStartZ, context.int32Constant(horizontalCellBlockCount), "\(name).cell_end_z")!

    let corners: [LLVMValueRef]
    if let bulkCell = alignedBulkCellState {
        let storage = try context.chunkInterpolatedCornerStorage(for: cacheIdentity)
        let reuseBlock = try appendBlock("\(name).bulk_cell.reuse", in: context)
        let recomputeBlock = try appendBlock("\(name).bulk_cell.recompute", in: context)
        let mergeBlock = try appendBlock("\(name).bulk_cell.merge", in: context)

        let isFirstX = LLVMBuildICmp(context.builder, LLVMIntEQ, bulkCell.localXIndex, context.int32Constant(0), "\(name).bulk_cell.first_x")!
        let isFirstY = LLVMBuildICmp(context.builder, LLVMIntEQ, bulkCell.localYIndex, context.int32Constant(0), "\(name).bulk_cell.first_y")!
        let isFirstZ = LLVMBuildICmp(context.builder, LLVMIntEQ, bulkCell.localZIndex, context.int32Constant(0), "\(name).bulk_cell.first_z")!
        let isFirstXY = context.buildAnd(isFirstX, isFirstY, name: "\(name).bulk_cell.first_xy")
        let isFirstSample = context.buildAnd(isFirstXY, isFirstZ, name: "\(name).bulk_cell.first_sample")
        LLVMBuildCondBr(context.builder, isFirstSample, recomputeBlock, reuseBlock)

        LLVMPositionBuilderAtEnd(context.builder, reuseBlock)
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, recomputeBlock)
        let recomputedCorners = try [
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellEndZ)
        ]
        for (index, corner) in recomputedCorners.enumerated() {
            LLVMBuildStore(context.builder, corner, storage.corners[index])
        }
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
        corners = storage.corners.enumerated().map { index, pointer in
            LLVMBuildLoad2(context.builder, context.doubleType, pointer, "\(name).bulk_cell.corner_\(index)")!
        }
    } else if context.bulkInitialY != nil {
        let storage = try context.chunkInterpolatedCornerStorage(for: cacheIdentity)
        let reuseBlock = try appendBlock("\(name).corner_cache.reuse", in: context)
        let recomputeBlock = try appendBlock("\(name).corner_cache.recompute", in: context)
        let mergeBlock = try appendBlock("\(name).corner_cache.merge", in: context)

        let cachedValid = LLVMBuildLoad2(
            context.builder,
            LLVMInt1TypeInContext(context.llvmContext),
            storage.valid,
            "\(name).corner_cache.valid"
        )!
        let cachedCellStartX = LLVMBuildLoad2(context.builder, context.int32Type, storage.cellStartX, "\(name).corner_cache.cell_start_x")!
        let cachedCellStartY = LLVMBuildLoad2(context.builder, context.int32Type, storage.cellStartY, "\(name).corner_cache.cell_start_y")!
        let cachedCellStartZ = LLVMBuildLoad2(context.builder, context.int32Type, storage.cellStartZ, "\(name).corner_cache.cell_start_z")!
        let sameX = LLVMBuildICmp(context.builder, LLVMIntEQ, cellStartX, cachedCellStartX, "\(name).corner_cache.same_x")!
        let sameY = LLVMBuildICmp(context.builder, LLVMIntEQ, cellStartY, cachedCellStartY, "\(name).corner_cache.same_y")!
        let sameZ = LLVMBuildICmp(context.builder, LLVMIntEQ, cellStartZ, cachedCellStartZ, "\(name).corner_cache.same_z")!
        let sameXY = context.buildAnd(sameX, sameY, name: "\(name).corner_cache.same_xy")
        let sameXYZ = context.buildAnd(sameXY, sameZ, name: "\(name).corner_cache.same_xyz")
        let canReuse = context.buildAnd(cachedValid, sameXYZ, name: "\(name).corner_cache.can_reuse")
        LLVMBuildCondBr(context.builder, canReuse, reuseBlock, recomputeBlock)

        LLVMPositionBuilderAtEnd(context.builder, reuseBlock)
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, recomputeBlock)
        let recomputedCorners = try [
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellEndZ)
        ]
        for (index, corner) in recomputedCorners.enumerated() {
            LLVMBuildStore(context.builder, corner, storage.corners[index])
        }
        LLVMBuildStore(context.builder, cellStartX, storage.cellStartX)
        LLVMBuildStore(context.builder, cellStartY, storage.cellStartY)
        LLVMBuildStore(context.builder, cellStartZ, storage.cellStartZ)
        LLVMBuildStore(context.builder, LLVMConstInt(LLVMInt1TypeInContext(context.llvmContext), 1, 0), storage.valid)
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
        corners = storage.corners.enumerated().map { index, pointer in
            LLVMBuildLoad2(context.builder, context.doubleType, pointer, "\(name).corner_cache.corner_\(index)")!
        }
    } else {
        corners = try [
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellStartZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellStartY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellStartX, y: cellEndY, z: cellEndZ),
            wrapped.compile(inContext: context, x: cellEndX, y: cellEndY, z: cellEndZ)
        ]
    }

    let x0y0 = context.buildLerp(deltaX, start: corners[0], end: corners[1], name: "\(name).x0y0")
    let x1y0 = context.buildLerp(deltaX, start: corners[2], end: corners[3], name: "\(name).x1y0")
    let x0y1 = context.buildLerp(deltaX, start: corners[4], end: corners[5], name: "\(name).x0y1")
    let x1y1 = context.buildLerp(deltaX, start: corners[6], end: corners[7], name: "\(name).x1y1")
    let z0 = context.buildLerp(deltaY, start: x0y0, end: x1y0, name: "\(name).z0")
    let z1 = context.buildLerp(deltaY, start: x0y1, end: x1y1, name: "\(name).z1")
    return context.buildLerp(deltaZ, start: z0, end: z1, name: "\(name).result")
}

extension ConstantDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        context.constant(self.value)
    }
}

extension UnaryDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            guard let operand = self.operand as? any CompilableDensityFunction else {
                throw DensityFunctionCompilationError.nonCompilableDensityFunction
            }
            let compiledOperand = try operand.compile(inContext: context, x: x, y: y, z: z)
            return compileUnaryOperation(self.operation, operand: compiledOperand, in: context, name: "unary")
        }
    }
}

extension BinaryDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            let firstFunction: any DensityFunction
            let secondFunction: any DensityFunction
            switch self.operation {
            case .MINIMUM:
                if self.second.lowerBoundValue() > self.first.lowerBoundValue() {
                    firstFunction = self.first
                    secondFunction = self.second
                } else {
                    firstFunction = self.second
                    secondFunction = self.first
                }
            case .MAXIMUM:
                if self.second.upperBoundValue() < self.first.upperBoundValue() {
                    firstFunction = self.first
                    secondFunction = self.second
                } else {
                    firstFunction = self.second
                    secondFunction = self.first
                }
            case .MULTIPLY:
                let firstCanBeZero = self.first.lowerBoundValue() <= 0.0 && self.first.upperBoundValue() >= 0.0
                let secondCanBeZero = self.second.lowerBoundValue() <= 0.0 && self.second.upperBoundValue() >= 0.0
                if firstCanBeZero == secondCanBeZero {
                    firstFunction = self.first
                    secondFunction = self.second
                } else if firstCanBeZero {
                    firstFunction = self.first
                    secondFunction = self.second
                } else {
                    firstFunction = self.second
                    secondFunction = self.first
                }
            case .ADD:
                firstFunction = self.first
                secondFunction = self.second
            }

            guard let firstOperand = firstFunction as? any CompilableDensityFunction else {
                throw DensityFunctionCompilationError.nonCompilableDensityFunction
            }
            guard let secondOperand = secondFunction as? any CompilableDensityFunction else {
                throw DensityFunctionCompilationError.nonCompilableDensityFunction
            }

            switch self.operation {
            case .ADD:
                if let firstConstant = firstFunction as? ConstantDensityFunction, firstConstant.constantValue == 0.0 {
                    return try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                }
                if let secondConstant = secondFunction as? ConstantDensityFunction, secondConstant.constantValue == 0.0 {
                    return try firstOperand.compile(inContext: context, x: x, y: y, z: z)
                }
            case .MULTIPLY:
                if let firstConstant = firstFunction as? ConstantDensityFunction {
                    if firstConstant.constantValue == 0.0 {
                        return context.constant(0.0)
                    }
                    if firstConstant.constantValue == 1.0 {
                        return try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                    }
                }
                if let secondConstant = secondFunction as? ConstantDensityFunction {
                    if secondConstant.constantValue == 0.0 {
                        return context.constant(0.0)
                    }
                    if secondConstant.constantValue == 1.0 {
                        return try firstOperand.compile(inContext: context, x: x, y: y, z: z)
                    }
                }
            case .MINIMUM:
                if firstFunction.upperBoundValue() <= secondFunction.lowerBoundValue() {
                    return try firstOperand.compile(inContext: context, x: x, y: y, z: z)
                }
                if secondFunction.upperBoundValue() <= firstFunction.lowerBoundValue() {
                    return try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                }
            case .MAXIMUM:
                if firstFunction.lowerBoundValue() >= secondFunction.upperBoundValue() {
                    return try firstOperand.compile(inContext: context, x: x, y: y, z: z)
                }
                if secondFunction.lowerBoundValue() >= firstFunction.upperBoundValue() {
                    return try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                }
            }

            let firstValue = try firstOperand.compile(inContext: context, x: x, y: y, z: z)
            if densityFunctionInstancesMatch(firstFunction, secondFunction) {
                switch self.operation {
                case .ADD:
                    return LLVMBuildFAdd(context.builder, firstValue, firstValue, "binary.same.add")
                case .MULTIPLY:
                    return LLVMBuildFMul(context.builder, firstValue, firstValue, "binary.same.mul")
                case .MINIMUM, .MAXIMUM:
                    return firstValue
                }
            }

            switch self.operation {
            case .MULTIPLY:
                let zeroBlock = try appendBlock("binary.multiply.zero", in: context)
                let multiplyBlock = try appendBlock("binary.multiply.compute", in: context)
                let mergeBlock = try appendBlock("binary.multiply.merge", in: context)
                let isZero = LLVMBuildFCmp(context.builder, LLVMRealOEQ, firstValue, context.constant(0.0), "binary.multiply.is_zero")!
                LLVMBuildCondBr(context.builder, isZero, zeroBlock, multiplyBlock)

                LLVMPositionBuilderAtEnd(context.builder, zeroBlock)
                LLVMBuildBr(context.builder, mergeBlock)
                let zeroEndBlock = LLVMGetInsertBlock(context.builder)!

                LLVMPositionBuilderAtEnd(context.builder, multiplyBlock)
                let secondValue = try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                let multiplied = LLVMBuildFMul(context.builder, firstValue, secondValue, "binary.multiply.value")!
                LLVMBuildBr(context.builder, mergeBlock)
                let multiplyEndBlock = LLVMGetInsertBlock(context.builder)!

                LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
                let phi = LLVMBuildPhi(context.builder, context.doubleType, "binary.multiply.result")!
                addIncoming(phi: phi, values: [context.constant(0.0), multiplied], blocks: [zeroEndBlock, multiplyEndBlock])
                return phi

            case .MINIMUM:
                let shortCircuitValue = secondFunction.lowerBoundValue()
                if shortCircuitValue.isFinite {
                    let shortCircuitBlock = try appendBlock("binary.minimum.short_circuit", in: context)
                    let evaluateBlock = try appendBlock("binary.minimum.compute", in: context)
                    let mergeBlock = try appendBlock("binary.minimum.merge", in: context)
                    let shouldShortCircuit = LLVMBuildFCmp(
                        context.builder,
                        LLVMRealOLT,
                        firstValue,
                        context.constant(shortCircuitValue),
                        "binary.minimum.should_short_circuit"
                    )!
                    LLVMBuildCondBr(context.builder, shouldShortCircuit, shortCircuitBlock, evaluateBlock)

                    LLVMPositionBuilderAtEnd(context.builder, shortCircuitBlock)
                    LLVMBuildBr(context.builder, mergeBlock)
                    let shortCircuitEndBlock = LLVMGetInsertBlock(context.builder)!

                    LLVMPositionBuilderAtEnd(context.builder, evaluateBlock)
                    let secondValue = try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                    let minimum = context.buildMin(firstValue, secondValue, name: "binary.minimum.value")
                    LLVMBuildBr(context.builder, mergeBlock)
                    let evaluateEndBlock = LLVMGetInsertBlock(context.builder)!

                    LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
                    let phi = LLVMBuildPhi(context.builder, context.doubleType, "binary.minimum.result")!
                    addIncoming(phi: phi, values: [firstValue, minimum], blocks: [shortCircuitEndBlock, evaluateEndBlock])
                    return phi
                }

            case .MAXIMUM:
                let shortCircuitValue = secondFunction.upperBoundValue()
                if shortCircuitValue.isFinite {
                    let shortCircuitBlock = try appendBlock("binary.maximum.short_circuit", in: context)
                    let evaluateBlock = try appendBlock("binary.maximum.compute", in: context)
                    let mergeBlock = try appendBlock("binary.maximum.merge", in: context)
                    let shouldShortCircuit = LLVMBuildFCmp(
                        context.builder,
                        LLVMRealOGT,
                        firstValue,
                        context.constant(shortCircuitValue),
                        "binary.maximum.should_short_circuit"
                    )!
                    LLVMBuildCondBr(context.builder, shouldShortCircuit, shortCircuitBlock, evaluateBlock)

                    LLVMPositionBuilderAtEnd(context.builder, shortCircuitBlock)
                    LLVMBuildBr(context.builder, mergeBlock)
                    let shortCircuitEndBlock = LLVMGetInsertBlock(context.builder)!

                    LLVMPositionBuilderAtEnd(context.builder, evaluateBlock)
                    let secondValue = try secondOperand.compile(inContext: context, x: x, y: y, z: z)
                    let maximum = context.buildMax(firstValue, secondValue, name: "binary.maximum.value")
                    LLVMBuildBr(context.builder, mergeBlock)
                    let evaluateEndBlock = LLVMGetInsertBlock(context.builder)!

                    LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
                    let phi = LLVMBuildPhi(context.builder, context.doubleType, "binary.maximum.result")!
                    addIncoming(phi: phi, values: [firstValue, maximum], blocks: [shortCircuitEndBlock, evaluateEndBlock])
                    return phi
                }

            case .ADD:
                break
            }

            let secondValue = try secondOperand.compile(inContext: context, x: x, y: y, z: z)
            return compileBinaryOperation(self.operation, first: firstValue, second: secondValue, in: context, name: "binary")
        }
    }
}

extension ReferenceDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            try context.withResolvedReference(self) { resolved in
                try resolved.compile(inContext: context, x: x, y: y, z: z)
            }
        }
    }
}

extension ClampDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let input = self.clampedInput as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        let value = try input.compile(inContext: context, x: x, y: y, z: z)
        let clampedHigh = context.buildMin(value, context.constant(self.maximumValue), name: "clamp.high")
        return context.buildMax(clampedHigh, context.constant(self.minimumValue), name: "clamp")
    }
}

extension YClampedGradient: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        let lowerBound = context.constant(self.minimumOutputValue)
        let upperBound = context.constant(self.maximumOutputValue)
        let yValue = LLVMBuildSIToFP(context.builder, y, context.doubleType, "y_clamped_gradient.y")
        let fromY = context.constant(Double(self.testingAttributes.fromY))
        let reciprocalRange = context.constant(1.0 / Double(self.testingAttributes.toY - self.testingAttributes.fromY))
        let progress = LLVMBuildFMul(
            context.builder,
            LLVMBuildFSub(context.builder, yValue, fromY, "y_clamped_gradient.offset"),
            reciprocalRange,
            "y_clamped_gradient.progress"
        )
        let outputDelta = LLVMBuildFSub(context.builder, upperBound, lowerBound, "y_clamped_gradient.delta")
        let interpolated = LLVMBuildFAdd(
            context.builder,
            lowerBound,
            LLVMBuildFMul(
                context.builder,
                progress,
                outputDelta,
                "y_clamped_gradient.scaled_delta"
            ),
            "y_clamped_gradient.interpolated"
        )
        let belowRange = LLVMBuildFCmp(context.builder, LLVMRealOLE, progress, context.constant(0.0), "y_clamped_gradient.below_range")
        let aboveRange = LLVMBuildFCmp(context.builder, LLVMRealOGE, progress, context.constant(1.0), "y_clamped_gradient.above_range")
        let clampedBelow = LLVMBuildSelect(context.builder, belowRange, lowerBound, interpolated, "y_clamped_gradient.clamped_below")
        return LLVMBuildSelect(context.builder, aboveRange, upperBound, clampedBelow, "y_clamped_gradient")
    }
}

extension RangeChoice: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let inputChoice = self.inputChoiceFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }

        return try context.cachedCompile(self, x: x, y: y, z: z) {
            let inputLowerBound = self.inputChoiceFunction.lowerBoundValue()
            let inputUpperBound = self.inputChoiceFunction.upperBoundValue()
            if inputLowerBound >= self.minimumInclusive && inputUpperBound < self.maximumExclusive {
                return try compileRangeChoiceBranch(
                    self.whenInRangeOutput,
                    inputChoice: self.inputChoiceFunction,
                    inputValue: try inputChoice.compile(inContext: context, x: x, y: y, z: z),
                    in: context,
                    x: x,
                    y: y,
                    z: z
                )
            }
            if inputUpperBound < self.minimumInclusive || inputLowerBound >= self.maximumExclusive {
                return try compileRangeChoiceBranch(
                    self.whenOutOfRangeOutput,
                    inputChoice: self.inputChoiceFunction,
                    inputValue: try inputChoice.compile(inContext: context, x: x, y: y, z: z),
                    in: context,
                    x: x,
                    y: y,
                    z: z
                )
            }

            let inputValue = try inputChoice.compile(inContext: context, x: x, y: y, z: z)
            let isAtLeastMin = LLVMBuildFCmp(context.builder, LLVMRealOGE, inputValue, context.constant(self.minimumInclusive), "range_choice.at_least_min")
            let isBelowMax = LLVMBuildFCmp(context.builder, LLVMRealOLT, inputValue, context.constant(self.maximumExclusive), "range_choice.below_max")
            let isInRange = LLVMBuildAnd(context.builder, isAtLeastMin, isBelowMax, "range_choice.is_in_range")

            let inRangeBlock = try appendBlock("range_choice.in_range", in: context)
            let outOfRangeBlock = try appendBlock("range_choice.out_of_range", in: context)
            let mergeBlock = try appendBlock("range_choice.merge", in: context)
            LLVMBuildCondBr(context.builder, isInRange, inRangeBlock, outOfRangeBlock)

            LLVMPositionBuilderAtEnd(context.builder, inRangeBlock)
            let inRangeValue = try compileRangeChoiceBranch(
                self.whenInRangeOutput,
                inputChoice: self.inputChoiceFunction,
                inputValue: inputValue,
                in: context,
                x: x,
                y: y,
                z: z
            )
            LLVMBuildBr(context.builder, mergeBlock)
            let inRangeEndBlock = LLVMGetInsertBlock(context.builder)!

            LLVMPositionBuilderAtEnd(context.builder, outOfRangeBlock)
            let outOfRangeValue = try compileRangeChoiceBranch(
                self.whenOutOfRangeOutput,
                inputChoice: self.inputChoiceFunction,
                inputValue: inputValue,
                in: context,
                x: x,
                y: y,
                z: z
            )
            LLVMBuildBr(context.builder, mergeBlock)
            let outOfRangeEndBlock = LLVMGetInsertBlock(context.builder)!

            LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
            let phi = LLVMBuildPhi(context.builder, context.doubleType, "range_choice.result")!
            addIncoming(phi: phi, values: [inRangeValue, outOfRangeValue], blocks: [inRangeEndBlock, outOfRangeEndBlock])
            return phi
        }
    }
}

extension ShiftDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            context.buildRuntimeDensitySampleCall(self, x: x, y: y, z: z, name: "shift")
        }
    }
}

extension NoiseDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            let sampleX = LLVMBuildFMul(
                context.builder,
                LLVMBuildSIToFP(context.builder, x, context.doubleType, "noise.x")!,
                context.constant(self.xzScaleValue),
                "noise.sample_x"
            )!
            let sampleY = LLVMBuildFMul(
                context.builder,
                LLVMBuildSIToFP(context.builder, y, context.doubleType, "noise.y")!,
                context.constant(self.yScaleValue),
                "noise.sample_y"
            )!
            let sampleZ = LLVMBuildFMul(
                context.builder,
                LLVMBuildSIToFP(context.builder, z, context.doubleType, "noise.z")!,
                context.constant(self.xzScaleValue),
                "noise.sample_z"
            )!
            return context.buildRuntimeNoiseSampleCall(self.noiseSampler, x: sampleX, y: sampleY, z: sampleZ, name: "noise")
        }
    }
}

extension ShiftedNoise: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            guard let shiftX = self.shiftXFunction as? any CompilableDensityFunction,
                  let shiftY = self.shiftYFunction as? any CompilableDensityFunction,
                  let shiftZ = self.shiftZFunction as? any CompilableDensityFunction else {
                throw DensityFunctionCompilationError.nonCompilableDensityFunction
            }

            let shiftXValue = try shiftX.compile(inContext: context, x: x, y: y, z: z)
            let shiftYValue = try shiftY.compile(inContext: context, x: x, y: y, z: z)
            let shiftZValue = try shiftZ.compile(inContext: context, x: x, y: y, z: z)
            let sampleX = LLVMBuildFAdd(
                context.builder,
                LLVMBuildFMul(
                    context.builder,
                    LLVMBuildSIToFP(context.builder, x, context.doubleType, "shifted_noise.x")!,
                    context.constant(self.xzScaleValue),
                    "shifted_noise.scaled_x"
                )!,
                shiftXValue,
                "shifted_noise.sample_x"
            )!
            let sampleY = LLVMBuildFAdd(
                context.builder,
                LLVMBuildFMul(
                    context.builder,
                    LLVMBuildSIToFP(context.builder, y, context.doubleType, "shifted_noise.y")!,
                    context.constant(self.yScaleValue),
                    "shifted_noise.scaled_y"
                )!,
                shiftYValue,
                "shifted_noise.sample_y"
            )!
            let sampleZ = LLVMBuildFAdd(
                context.builder,
                LLVMBuildFMul(
                    context.builder,
                    LLVMBuildSIToFP(context.builder, z, context.doubleType, "shifted_noise.z")!,
                    context.constant(self.xzScaleValue),
                    "shifted_noise.scaled_z"
                )!,
                shiftZValue,
                "shifted_noise.sample_z"
            )!
            return context.buildRuntimeNoiseSampleCall(
                self.noiseSampler,
                x: sampleX,
                y: sampleY,
                z: sampleZ,
                name: "shifted_noise"
            )
        }
    }
}

extension BlendAlpha: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        context.constant(1.0)
    }
}

extension BlendOffset: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        context.constant(0.0)
    }
}

extension BlendDensity: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            guard let argument = self.argumentFunction as? any CompilableDensityFunction else {
                throw DensityFunctionCompilationError.nonCompilableDensityFunction
            }
            return try argument.compile(inContext: context, x: x, y: y, z: z)
        }
    }
}

extension BeardifierMarker: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        context.constant(0.0)
    }
}

extension EndIslandsDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            context.buildRuntimeDensitySampleCall(self, x: x, y: y, z: z, name: "end_islands")
        }
    }
}

extension WeirdScaledSampler: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let input = self.inputFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }

        let inputValue = try input.compile(inContext: context, x: x, y: y, z: z)
        let scaledValue = compileWeirdScale(self.scalingType, input: inputValue, in: context)
        let sampleX: LLVMValueRef = LLVMBuildFDiv(context.builder, LLVMBuildSIToFP(context.builder, x, context.doubleType, "weird_scaled_sampler.x")!, scaledValue, "weird_scaled_sampler.sample_x")
        let sampleY: LLVMValueRef = LLVMBuildFDiv(context.builder, LLVMBuildSIToFP(context.builder, y, context.doubleType, "weird_scaled_sampler.y")!, scaledValue, "weird_scaled_sampler.sample_y")
        let sampleZ: LLVMValueRef = LLVMBuildFDiv(context.builder, LLVMBuildSIToFP(context.builder, z, context.doubleType, "weird_scaled_sampler.z")!, scaledValue, "weird_scaled_sampler.sample_z")
        let noiseValue = context.buildRuntimeNoiseSampleCall(self.noiseSampler, x: sampleX, y: sampleY, z: sampleZ, name: "weird_scaled_sampler.noise")
        let absoluteNoise = context.buildAbs(noiseValue, name: "weird_scaled_sampler.abs_noise")
        return LLVMBuildFMul(context.builder, scaledValue, absoluteNoise, "weird_scaled_sampler")
    }
}

extension SplineDensityFunction: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        try context.cachedCompile(self, x: x, y: y, z: z) {
            context.buildFloatExtend(
                try compileSplineSegmentFloat(self.splineSegment, in: context, x: x, y: y, z: z),
                name: "spline.result.double"
            )
        }
    }
}

extension FindTopSurface: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        guard let density = self.densityFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        guard let upperBound = self.upperBoundFunction as? any CompilableDensityFunction else {
            throw DensityFunctionCompilationError.nonCompilableDensityFunction
        }
        guard let lowerBound = Int32(exactly: self.lowerBoundHeight) else {
            throw DensityFunctionCompilationError.badDensityFunction("FindTopSurface lower bound is out of Int32 range.")
        }
        guard let cellHeight = Int32(exactly: self.cellHeightValue), cellHeight > 0 else {
            throw DensityFunctionCompilationError.badDensityFunction("FindTopSurface cell height must be a positive Int32.")
        }

        let upperBoundValue = try upperBound.compile(inContext: context, x: x, y: y, z: z)
        let cellHeightDouble = context.constant(Double(cellHeight))
        let startingYDouble = LLVMBuildFMul(
            context.builder,
            context.buildFloorCall(
                LLVMBuildFDiv(context.builder, upperBoundValue, cellHeightDouble, "find_top_surface.upper_div"),
                name: "find_top_surface.upper_floor"
            ),
            cellHeightDouble,
            "find_top_surface.starting_y_double"
        )
        let startingY: LLVMValueRef = LLVMBuildFPToSI(context.builder, startingYDouble, context.int32Type, "find_top_surface.starting_y")
        let lowerBoundValue = context.int32Constant(lowerBound)
        let lowerBoundDouble = context.constant(Double(lowerBound))

        let immediateReturnBlock = try appendBlock("find_top_surface.immediate_return", in: context)
        let loopHeaderBlock = try appendBlock("find_top_surface.loop_header", in: context)
        let continueBlock = try appendBlock("find_top_surface.continue", in: context)
        let foundBlock = try appendBlock("find_top_surface.found", in: context)
        let noMatchBlock = try appendBlock("find_top_surface.no_match", in: context)
        let mergeBlock = try appendBlock("find_top_surface.merge", in: context)
        let preheaderBlock = LLVMGetInsertBlock(context.builder)!

        let startsBelowLowerBound = LLVMBuildICmp(
            context.builder,
            LLVMIntSLE,
            startingY,
            lowerBoundValue,
            "find_top_surface.starts_below_lower_bound"
        )
        LLVMBuildCondBr(context.builder, startsBelowLowerBound, immediateReturnBlock, loopHeaderBlock)

        LLVMPositionBuilderAtEnd(context.builder, immediateReturnBlock)
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, loopHeaderBlock)
        let currentY = LLVMBuildPhi(context.builder, context.int32Type, "find_top_surface.current_y")!
        addIncoming(phi: currentY, values: [startingY], blocks: [preheaderBlock])
        let densityValue = try density.compile(inContext: context, x: x, y: currentY, z: z)
        let isPositive = LLVMBuildFCmp(context.builder, LLVMRealOGT, densityValue, context.constant(0.0), "find_top_surface.is_positive")
        LLVMBuildCondBr(context.builder, isPositive, foundBlock, continueBlock)

        LLVMPositionBuilderAtEnd(context.builder, foundBlock)
        let foundValue: LLVMValueRef = LLVMBuildSIToFP(context.builder, currentY, context.doubleType, "find_top_surface.found_value")
        LLVMBuildBr(context.builder, mergeBlock)

        LLVMPositionBuilderAtEnd(context.builder, continueBlock)
        let nextY: LLVMValueRef = LLVMBuildSub(context.builder, currentY, context.int32Constant(cellHeight), "find_top_surface.next_y")
        let shouldContinue = LLVMBuildICmp(context.builder, LLVMIntSGE, nextY, lowerBoundValue, "find_top_surface.should_continue")
        LLVMBuildCondBr(context.builder, shouldContinue, loopHeaderBlock, noMatchBlock)

        LLVMPositionBuilderAtEnd(context.builder, noMatchBlock)
        LLVMBuildBr(context.builder, mergeBlock)

        addIncoming(phi: currentY, values: [nextY], blocks: [continueBlock])

        LLVMPositionBuilderAtEnd(context.builder, mergeBlock)
        let result = LLVMBuildPhi(context.builder, context.doubleType, "find_top_surface.result")!
        addIncoming(
            phi: result,
            values: [lowerBoundDouble, foundValue, lowerBoundDouble],
            blocks: [immediateReturnBlock, foundBlock, noMatchBlock]
        )
        return result
    }
}

extension InterpolatedNoise: CompilableDensityFunction {
    func compile(
        inContext context: DensityFunctionCompilationContext,
        x: LLVMValueRef,
        y: LLVMValueRef,
        z: LLVMValueRef
    ) throws -> LLVMValueRef {
        context.buildRuntimeDensitySampleCall(self, x: x, y: y, z: z, name: "old_blended_noise")
    }
}

extension ChunkPositionCache: CompilableDensityFunction {}
#else
public func compile(
    densityFunction root: any DensityFunction,
    bufferContext: CompiledDensityFunctionBufferContext,
    strategy: CompilationBackend = .llvm,
    registry: Registry<DensityFunction> = Registry(),
    options: BufferedDensityFunctionCompilationOptions = BufferedDensityFunctionCompilationOptions()
) throws -> CompiledDensityFunctionBuffer {
    throw DensityFunctionCompilationError.unsupportedCompilationStrategy(strategy)
}
#endif
