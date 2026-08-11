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

    func search(_ point: [Int64]) -> Int32 {
        precondition(point.count == 7)
        if self.nodes[self.rootIndex].isLeaf {
            return self.nodes[self.rootIndex].valueIndex
        }
        var bestIndex: Int32 = -1
        var bestDistance = Int64.max

        @inline(__always)
        func visit(_ nodeIndex: Int) -> Bool {
            let node = self.nodes[nodeIndex]
            if node.isLeaf {
                let candidateDistance = self.squaredDistance(nodeIndex: nodeIndex, point: point)
                if candidateDistance <= bestDistance {
                    bestDistance = candidateDistance
                    bestIndex = node.valueIndex
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
        return bestIndex
    }
}

/// A stateless biome selector lowered through the same IR and backend pipeline as compiled density functions.
/// Ties follow deterministic tree order, equivalent to looking up after `BiomeSearchTree.resetAlternative()`.
public final class CompiledBiomeSearchTree: @unchecked Sendable {
    public let strategy: CompilationBackend
    /// A module exporting `search(f64, f64, f64, f64, f64, f64) -> i32`, present for WASM compilation.
    public let wasmModule: [UInt8]?
    /// Maps the `i32` result exported by `wasmModule` to biome keys.
    public let biomes: [RegistryKey<Biome>]
    private let implementation: @Sendable (Double, Double, Double, Double, Double, Double) -> Int32

    init(
        strategy: CompilationBackend,
        wasmModule: [UInt8]? = nil,
        biomes: [RegistryKey<Biome>],
        implementation: @escaping @Sendable (Double, Double, Double, Double, Double, Double) -> Int32
    ) {
        self.strategy = strategy
        self.wasmModule = wasmModule
        self.biomes = biomes
        self.implementation = implementation
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
        let index = self.implementation(temperature, humidity, continentalness, erosion, weirdness, depth)
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

func buildBiomeSearchIR(tree: BiomeSearchIRTree) -> DensityFunctionIRProgram {
    let inputTypes: [DensityFunctionIRValueType] = Array(repeating: .f64, count: 6)
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
    let output = append(.searchBiome(index: 0, point: point))
    return DensityFunctionIRProgram(
        inputTypes: inputTypes,
        instructions: instructions,
        output: output,
        densityFunctions: [],
        noises: [],
        biomeSearchTrees: [tree]
    )
}

/// Compiles a biome search tree using the requested density-function compiler backend.
public func compile(
    biomeSearchTree tree: BiomeSearchTree,
    strategy: CompilationBackend = .llvm,
    runtime: (any WASMRuntime)? = nil
) throws -> CompiledBiomeSearchTree {
    let snapshot = tree.makeCompilerSnapshot()
    let program = buildBiomeSearchIR(tree: snapshot.tree)
    switch strategy {
    case .wasm:
        let module = try buildDensityFunctionWASMModule(program, exportName: "search")
        if let runtime {
            let implementation = try runtime.instantiateBiomeSearch(module: module, exportName: "search")
            return CompiledBiomeSearchTree(
                strategy: .wasm,
                wasmModule: module,
                biomes: snapshot.biomes,
                implementation: implementation
            )
        }
        #if os(WASI) || arch(wasm32)
        throw DensityFunctionCompilationError.wasmRuntimeUnavailable
        #else
        return CompiledBiomeSearchTree(strategy: .wasm, wasmModule: module, biomes: snapshot.biomes) {
            temperature, humidity, continentalness, erosion, weirdness, depth in
            evaluateBiomeSearchIR(
                program,
                point: NoisePoint(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth
                )
            )
        }
        #endif
    case .llvm:
        #if canImport(CLLVM)
        return try compileBiomeSearchIRWithLLVM(program, biomes: snapshot.biomes)
        #else
        throw DensityFunctionCompilationError.unsupportedCompilationStrategy(.llvm)
        #endif
    }
}

public extension BiomeSearchTree {
    /// Compiles this tree with the requested shared compiler backend.
    func compile(
        strategy: CompilationBackend = .llvm,
        runtime: (any WASMRuntime)? = nil
    ) throws -> CompiledBiomeSearchTree {
        try DPReader.compile(biomeSearchTree: self, strategy: strategy, runtime: runtime)
    }
}
