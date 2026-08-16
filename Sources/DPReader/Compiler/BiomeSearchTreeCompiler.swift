import Foundation

struct BiomeSearchIRNode: Sendable {
    let valueIndex: Int32
    let childIndexStart: Int
    let childCount: Int
    let minimums: [Int64]
    let maximums: [Int64]

    var isLeaf: Bool { self.valueIndex >= 0 }
}

final class BiomeSearchIRTree: @unchecked Sendable {
    let nodes: [BiomeSearchIRNode]
    let rootIndex: Int

    init(nodes: [BiomeSearchIRNode], rootIndex: Int) {
        self.nodes = nodes
        self.rootIndex = rootIndex
    }

    @inline(__always)
    func squaredDistance(nodeIndex: Int, point: [Int64]) -> Int64 {
        let node = self.nodes[nodeIndex]
        var result: Int64 = 0
        // Keep the same high-selectivity ordering as the interpreted tree.
        for dimension in [2, 3, 5, 4, 0, 1, 6] {
            let distance: Int64
            if point[dimension] > node.maximums[dimension] {
                distance = point[dimension] &- node.maximums[dimension]
            } else if point[dimension] < node.minimums[dimension] {
                distance = node.minimums[dimension] &- point[dimension]
            } else {
                distance = 0
            }
            result &+= distance &* distance
        }
        return result
    }

    @inline(__always)
    func squaredDistance(
        nodeIndex: Int,
        temperature: Int64,
        humidity: Int64,
        continentalness: Int64,
        erosion: Int64,
        weirdness: Int64,
        depth: Int64
    ) -> Int64 {
        let node = self.nodes[nodeIndex]
        var result: Int64 = 0

        @inline(__always)
        func accumulate(_ value: Int64, dimension: Int) {
            let distance: Int64
            if value > node.maximums[dimension] {
                distance = value &- node.maximums[dimension]
            } else if value < node.minimums[dimension] {
                distance = node.minimums[dimension] &- value
            } else {
                return
            }
            result &+= distance &* distance
        }

        accumulate(continentalness, dimension: 2)
        accumulate(erosion, dimension: 3)
        accumulate(weirdness, dimension: 5)
        accumulate(depth, dimension: 4)
        accumulate(temperature, dimension: 0)
        accumulate(humidity, dimension: 1)
        accumulate(0, dimension: 6)
        return result
    }

    func search(
        _ point: [Int64],
        initialBestDistance: Int64 = Int64.max,
        initialBestNode: Int32 = -1,
        returnNodeIndex: Bool = false
    ) -> Int32 {
        precondition(point.count == 7)
        if self.nodes[self.rootIndex].isLeaf {
            return returnNodeIndex ? Int32(self.rootIndex) : self.nodes[self.rootIndex].valueIndex
        }
        let hasValidInitialNode = initialBestNode >= 0
            && Int(initialBestNode) < self.nodes.count
            && self.nodes[Int(initialBestNode)].isLeaf
        var bestNode = hasValidInitialNode ? initialBestNode : -1
        var bestDistance = hasValidInitialNode ? initialBestDistance : Int64.max

        @inline(__always)
        func visit(_ nodeIndex: Int) -> Bool {
            let node = self.nodes[nodeIndex]
            if node.isLeaf {
                let candidateDistance = self.squaredDistance(nodeIndex: nodeIndex, point: point)
                if candidateDistance <= bestDistance {
                    bestDistance = candidateDistance
                    bestNode = Int32(nodeIndex)
                }
                return bestDistance == 0
            }
            let end = node.childIndexStart + node.childCount
            for childIndex in node.childIndexStart..<end {
                if self.squaredDistance(nodeIndex: childIndex, point: point) > bestDistance {
                    continue
                }
                if visit(childIndex) {
                    return true
                }
            }
            return false
        }

        _ = visit(self.rootIndex)
        guard bestNode >= 0 else { return -1 }
        return returnNodeIndex ? bestNode : self.nodes[Int(bestNode)].valueIndex
    }
}

private final class CompiledBiomeSearchAlternativeState: @unchecked Sendable {
    let lock = NSLock()
    var nodeIndex: Int32 = -1
}

/// A biome selector lowered through the same IR and backend pipeline as compiled density functions.
public final class CompiledBiomeSearchTree: @unchecked Sendable {
    public let strategy: CompilationBackend
    /// A module exporting `search(f64, f64, f64, f64, f64, f64, i64, i32) -> i32`,
    /// present for WASM compilation. The final inputs are the optional alternative's distance and node index.
    public let wasmModule: [UInt8]?
    /// Maps the `i32` result exported by `wasmModule` to biome keys.
    public let biomes: [RegistryKey<Biome>]
    /// Whether this tree reuses its previous winning leaf as the next search's initial candidate.
    public let usesAlternativeNode: Bool
    private let tree: BiomeSearchIRTree
    private let alternativeState: CompiledBiomeSearchAlternativeState?
    private let implementation: @Sendable (
        Double, Double, Double, Double, Double, Double, Int64, Int32
    ) -> Int32

    init(
        strategy: CompilationBackend,
        wasmModule: [UInt8]? = nil,
        biomes: [RegistryKey<Biome>],
        tree: BiomeSearchIRTree,
        useAlternativeNode: Bool,
        implementation: @escaping @Sendable (
            Double, Double, Double, Double, Double, Double, Int64, Int32
        ) -> Int32
    ) {
        self.strategy = strategy
        self.wasmModule = wasmModule
        self.biomes = biomes
        self.tree = tree
        self.usesAlternativeNode = useAlternativeNode
        self.alternativeState = useAlternativeNode ? CompiledBiomeSearchAlternativeState() : nil
        self.implementation = implementation
    }

    /// Clears the previous winning leaf used as the alternative candidate.
    public func resetAlternative() {
        guard let alternativeState else { return }
        alternativeState.lock.withLock {
            alternativeState.nodeIndex = -1
        }
    }

    @inline(__always)
    public func callAsFunction(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double
    ) -> RegistryKey<Biome> {
        let invoke: (Int64, Int32) -> Int32 = { initialBestDistance, initialBestNode in
            self.implementation(
                temperature,
                humidity,
                continentalness,
                erosion,
                weirdness,
                depth,
                initialBestDistance,
                initialBestNode
            )
        }
        let index: Int32
        if let alternativeState {
            let initialNode = alternativeState.lock.withLock { alternativeState.nodeIndex }
            let initialDistance = initialNode >= 0
                ? self.tree.squaredDistance(
                    nodeIndex: Int(initialNode),
                    temperature: Int64(temperature * 10_000.0),
                    humidity: Int64(humidity * 10_000.0),
                    continentalness: Int64(continentalness * 10_000.0),
                    erosion: Int64(erosion * 10_000.0),
                    weirdness: Int64(weirdness * 10_000.0),
                    depth: Int64(depth * 10_000.0)
                )
                : Int64.max
            let nodeIndex = invoke(initialDistance, initialNode)
            precondition(
                nodeIndex >= 0 && Int(nodeIndex) < self.tree.nodes.count && self.tree.nodes[Int(nodeIndex)].isLeaf,
                "Compiled biome search returned an invalid node index."
            )
            alternativeState.lock.withLock {
                alternativeState.nodeIndex = nodeIndex
            }
            index = self.tree.nodes[Int(nodeIndex)].valueIndex
        } else {
            index = invoke(Int64.max, -1)
        }
        precondition(index >= 0 && Int(index) < self.biomes.count, "Compiled biome search returned an invalid biome index.")
        return self.biomes[Int(index)]
    }

    @inline(__always)
    public func callAsFunction(_ point: NoisePoint) -> RegistryKey<Biome> {
        self(
            temperature: point.temperature,
            humidity: point.humidity,
            continentalness: point.continentalness,
            erosion: point.erosion,
            weirdness: point.weirdness,
            depth: point.depth
        )
    }
}

func buildBiomeSearchIR(tree: BiomeSearchIRTree, useAlternativeNode: Bool = false) -> DensityFunctionIRProgram {
    let inputTypes: [DensityFunctionIRValueType] = Array(repeating: .f64, count: 6) + [.i64, .i32]
    var instructions: [DensityFunctionIRInstruction] = []

    @inline(__always)
    func append(_ instruction: DensityFunctionIRInstruction) -> Int {
        let result = inputTypes.count + instructions.count
        instructions.append(instruction)
        return result
    }

    let scale = append(.constant(10_000.0))
    let scaledInputs = (0..<6).map { input -> Int in
        append(.convertDoubleToSignedInt64(append(.multiply(input, scale))))
    }
    let offset = append(.constantInt64(0))
    let point = [
        scaledInputs[0],
        scaledInputs[1],
        scaledInputs[2],
        scaledInputs[3],
        scaledInputs[5],
        scaledInputs[4],
        offset
    ]
    let output = append(.searchBiome(
        index: 0,
        point: point,
        initialBestDistance: useAlternativeNode ? 6 : nil,
        initialBestNode: useAlternativeNode ? 7 : nil,
        returnNodeIndex: useAlternativeNode
    ))
    return DensityFunctionIRProgram(
        inputTypes: inputTypes,
        instructions: instructions,
        output: output,
        densityFunctions: [],
        noises: [],
        biomeSearchTrees: [tree]
    )
}

/// Builds one x/y/z program whose first six outputs are the climate point and whose final
/// f64 output is the biome index. Keeping the search in the same program lets WASM bulk
/// execution cross the embedding boundary once for the complete volume.
func buildClimateBiomeIR(
    densityFunctions: [any DensityFunction],
    registry: Registry<DensityFunction>,
    tree: BiomeSearchIRTree,
    includeClimateOutputs: Bool = true
) throws -> DensityFunctionIRProgram {
    precondition(densityFunctions.count == 6, "A climate-biome program requires six density functions.")
    let climate = try buildDensityFunctionIR(densityFunctions: densityFunctions, registry: registry)
    var instructions = climate.instructions

    @inline(__always)
    func append(_ instruction: DensityFunctionIRInstruction) -> Int {
        let result = climate.inputTypes.count + instructions.count
        instructions.append(instruction)
        return result
    }

    let scale = append(.constant(10_000.0))
    let scaledClimate = climate.outputs.map { output in
        append(.convertDoubleToSignedInt64(append(.multiply(output, scale))))
    }
    let offset = append(.constantInt64(0))
    let point = [
        scaledClimate[0],
        scaledClimate[1],
        scaledClimate[2],
        scaledClimate[3],
        scaledClimate[5],
        scaledClimate[4],
        offset
    ]
    let biomeIndex = append(.searchBiome(
        index: 0,
        point: point,
        initialBestDistance: nil,
        initialBestNode: nil,
        returnNodeIndex: false
    ))
    let outputs: [Int]
    if includeClimateOutputs {
        outputs = climate.outputs + [append(.convertSignedIntToDouble(biomeIndex))]
    } else {
        outputs = [biomeIndex]
    }
    return DensityFunctionIRProgram(
        inputTypes: climate.inputTypes,
        instructions: instructions,
        outputs: outputs,
        densityFunctions: climate.densityFunctions,
        noises: climate.noises,
        biomeSearchTrees: [tree]
    )
}

/// Integer palette indices for a fixed z/x/y-ordered biome volume, plus the palette
/// which maps each index to its biome key.
public struct CompiledBiomeIDVolume {
    public let biomeIDs: [Int32]
    public let palette: [RegistryKey<Biome>]

    public init(biomeIDs: [Int32], palette: [RegistryKey<Biome>]) {
        self.biomeIDs = biomeIDs
        self.palette = palette
    }
}

/// A fixed-shape program combining all six climate functions in a noise router with
/// its biome search tree. Each invocation crosses the backend boundary once.
public final class CompiledNoiseRouterBiomeBulkSampler: @unchecked Sendable {
    public let strategy: CompilationBackend
    public let bufferContext: CompiledDensityFunctionBufferContext
    public let palette: [RegistryKey<Biome>]
    private let stateLock = NSLock()
    private var storedWasmModule: [UInt8]?
    private var implementation: WASMBiomeIDBulkInvocation

    /// A module exporting `sample_bulk` and `memory`, present for WASM compilation.
    public var wasmModule: [UInt8]? {
        self.stateLock.withLock { self.storedWasmModule }
    }

    init(
        strategy: CompilationBackend,
        wasmModule: [UInt8]? = nil,
        bufferContext: CompiledDensityFunctionBufferContext,
        palette: [RegistryKey<Biome>],
        implementation: @escaping WASMBiomeIDBulkInvocation
    ) {
        self.strategy = strategy
        self.storedWasmModule = wasmModule
        self.bufferContext = bufferContext
        self.palette = palette
        self.implementation = implementation
    }

    func replaceImplementation(with replacement: CompiledNoiseRouterBiomeBulkSampler) {
        precondition(self.strategy == replacement.strategy)
        precondition(self.palette == replacement.palette)
        precondition(
            self.bufferContext.xCount == replacement.bufferContext.xCount
                && self.bufferContext.yCount == replacement.bufferContext.yCount
                && self.bufferContext.zCount == replacement.bufferContext.zCount
                && self.bufferContext.xStep == replacement.bufferContext.xStep
                && self.bufferContext.yStep == replacement.bufferContext.yStep
                && self.bufferContext.zStep == replacement.bufferContext.zStep
        )
        let state = replacement.stateLock.withLock {
            (replacement.storedWasmModule, replacement.implementation)
        }
        self.stateLock.withLock {
            self.storedWasmModule = state.0
            self.implementation = state.1
        }
    }

    /// Evaluates the fixed volume in z/x/y order.
    public func callAsFunction(at basePosition: PosInt3D) -> CompiledBiomeIDVolume {
        let implementation = self.stateLock.withLock { self.implementation }
        var biomeIDs = [Int32](repeating: 0, count: self.bufferContext.sampleCount)
        biomeIDs.withUnsafeMutableBufferPointer { output in
            guard let baseAddress = output.baseAddress else { return }
            implementation(basePosition.x, basePosition.y, basePosition.z, baseAddress)
        }
        for biomeID in biomeIDs {
            precondition(
                biomeID >= 0 && Int(biomeID) < self.palette.count,
                "Compiled biome program returned an invalid palette index."
            )
        }
        return CompiledBiomeIDVolume(biomeIDs: biomeIDs, palette: self.palette)
    }
}

#if !os(WASI) && !arch(wasm32)
private func makeBiomeIDIRFallbackInvocation(
    program: DensityFunctionIRProgram,
    bufferContext: CompiledDensityFunctionBufferContext
) -> WASMBiomeIDBulkInvocation {
    return { baseX, baseY, baseZ, output in
        var outputIndex = 0
        for zOffset in 0..<bufferContext.zCount {
            let z = baseZ + zOffset * bufferContext.zStep
            for xOffset in 0..<bufferContext.xCount {
                let x = baseX + xOffset * bufferContext.xStep
                for yOffset in 0..<bufferContext.yCount {
                    let y = baseY + yOffset * bufferContext.yStep
                    output[outputIndex] = evaluateBiomeIDIR(program, x: x, y: y, z: z)
                    outputIndex += 1
                }
            }
        }
    }
}
#endif

/// Compiles a noise router's six climate functions and a biome search tree into one
/// fixed-volume program. The returned IDs index directly into the result's palette.
public func compile(
    noiseRouter: NoiseRouter,
    biomeSearchTree: BiomeSearchTree,
    bufferContext: CompiledDensityFunctionBufferContext,
    strategy: CompilationBackend = .llvm,
    useAlternativeNode: Bool = false,
    registry: Registry<DensityFunction> = Registry(),
    runtime: (any WASMRuntime)? = nil
) throws -> CompiledNoiseRouterBiomeBulkSampler {
    _ = try validateCompiledDensityFunctionBufferContext(bufferContext)
    let snapshot = biomeSearchTree.makeCompilerSnapshot()
    let climateFunctions: [any DensityFunction] = [
        noiseRouter.temperature,
        noiseRouter.humidity,
        noiseRouter.continents,
        noiseRouter.erosion,
        noiseRouter.weirdness,
        noiseRouter.depth
    ]
    let program = try buildClimateBiomeIR(
        densityFunctions: climateFunctions,
        registry: registry,
        tree: snapshot.tree,
        includeClimateOutputs: false
    )

    switch strategy {
    case .llvm:
        #if canImport(CLLVM)
        let implementation = try compileDensityFunctionIRBulkWithLLVM(
            program,
            bufferContext: bufferContext,
            registry: registry,
            useAlternativeNode: useAlternativeNode
        )
        return CompiledNoiseRouterBiomeBulkSampler(
            strategy: .llvm,
            bufferContext: bufferContext,
            palette: snapshot.biomes,
            implementation: implementation
        )
        #else
        throw DensityFunctionCompilationError.unsupportedCompilationStrategy(.llvm)
        #endif
    case .wasm:
        let module = try buildDensityFunctionWASMModule(
            program,
            bulkContext: bufferContext,
            useBiomeSearchAlternative: useAlternativeNode
        )
        let implementation: WASMBiomeIDBulkInvocation
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
            implementation = try runtime.instantiateBiomeIDBulk(
                module: module,
                exportName: "sample_bulk",
                memoryExportName: "memory",
                sampleCount: bufferContext.sampleCount,
                imports: imports
            )
        } else {
            #if os(WASI) || arch(wasm32)
            throw DensityFunctionCompilationError.wasmRuntimeUnavailable
            #else
            implementation = makeBiomeIDIRFallbackInvocation(program: program, bufferContext: bufferContext)
            #endif
        }
        return CompiledNoiseRouterBiomeBulkSampler(
            strategy: .wasm,
            wasmModule: module,
            bufferContext: bufferContext,
            palette: snapshot.biomes,
            implementation: implementation
        )
    }
}

/// Compiles a biome search tree using the requested density-function compiler backend.
public func compile(
    biomeSearchTree tree: BiomeSearchTree,
    strategy: CompilationBackend = .llvm,
    useAlternativeNode: Bool = false,
    runtime: (any WASMRuntime)? = nil
) throws -> CompiledBiomeSearchTree {
    let snapshot = tree.makeCompilerSnapshot()
    let program = buildBiomeSearchIR(tree: snapshot.tree, useAlternativeNode: useAlternativeNode)
    switch strategy {
    case .wasm:
        let module = try buildDensityFunctionWASMModule(program, exportName: "search")
        if let runtime {
            let implementation = try runtime.instantiateBiomeSearch(module: module, exportName: "search")
            return CompiledBiomeSearchTree(
                strategy: .wasm,
                wasmModule: module,
                biomes: snapshot.biomes,
                tree: snapshot.tree,
                useAlternativeNode: useAlternativeNode,
                implementation: implementation
            )
        }
        #if os(WASI) || arch(wasm32)
        throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        #else
        return CompiledBiomeSearchTree(
            strategy: .wasm,
            wasmModule: module,
            biomes: snapshot.biomes,
            tree: snapshot.tree,
            useAlternativeNode: useAlternativeNode
        ) { temperature, humidity, continentalness, erosion, weirdness, depth, initialBestDistance, initialBestNode in
            evaluateBiomeSearchIR(
                program,
                point: NoisePoint(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth
                ),
                initialBestDistance: initialBestDistance,
                initialBestNode: initialBestNode
            )
        }
        #endif
    case .llvm:
        #if canImport(CLLVM)
        return try compileBiomeSearchIRWithLLVM(
            program,
            tree: snapshot.tree,
            biomes: snapshot.biomes,
            useAlternativeNode: useAlternativeNode
        )
        #else
        throw DensityFunctionCompilationError.unsupportedCompilationStrategy(.llvm)
        #endif
    }
}

public extension BiomeSearchTree {
    /// Compiles this tree with the requested shared compiler backend.
    func compile(
        strategy: CompilationBackend = .llvm,
        useAlternativeNode: Bool = false,
        runtime: (any WASMRuntime)? = nil
    ) throws -> CompiledBiomeSearchTree {
        try DPReader.compile(
            biomeSearchTree: self,
            strategy: strategy,
            useAlternativeNode: useAlternativeNode,
            runtime: runtime
        )
    }
}
