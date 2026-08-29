import Foundation
import Testing
@testable import DPReader

private struct HostRuntimeTestNoise: DensityFunctionNoise {
    let key = RegistryKey<NoiseDefinition>(referencing: "test:host_runtime")

    func sample(x: Double, y: Double, z: Double) -> Double {
        x * 0.25 + y * 0.5 - z * 0.75
    }
}

private struct TestHostWASMRuntime: WASMRuntime {
    let supportsClimateFunctions = true

    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        precondition(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
        precondition(exportName == "sample")
        return { x, y, z in
            Double(x + y + z) + imports.sampleNoise(0, Double(x), Double(y), Double(z))
        }
    }

    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        precondition(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
        precondition(exportName == "search")
        return { temperature, _, _, _, _, _, _, _ in temperature < 0 ? 0 : 1 }
    }

    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        precondition(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
        precondition(exportName == "sample_climate")
        return { x, y, z in
            WASMClimateSample(
                temperature: Double(x),
                humidity: Double(y),
                continentalness: Double(z),
                erosion: Double(x + y),
                weirdness: Double(y + z),
                depth: Double(x + z)
            )
        }
    }
}

private final class CapturingClimateWASMRuntime: WASMRuntime, @unchecked Sendable {
    let supportsClimateFunctions = true
    private let lock = NSLock()
    private var densityInstantiationCount = 0
    private var climateModules: [[UInt8]] = []

    func instantiateDensityFunction(
        module _: [UInt8],
        exportName _: String,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        self.lock.withLock { self.densityInstantiationCount += 1 }
        return { _, _, _ in 0 }
    }

    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports _: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        precondition(exportName == "sample_climate")
        self.lock.withLock { self.climateModules.append(module) }
        return { _, _, _ in
            WASMClimateSample(
                temperature: 0,
                humidity: 0,
                continentalness: 0,
                erosion: 0,
                weirdness: 0,
                depth: 0
            )
        }
    }

    func instantiateBiomeSearch(
        module _: [UInt8],
        exportName _: String
    ) throws -> WASMBiomeSearchInvocation {
        { _, _, _, _, _, _, _, _ in 0 }
    }

    var snapshot: (densityCount: Int, climateModules: [[UInt8]]) {
        self.lock.withLock { (self.densityInstantiationCount, self.climateModules) }
    }
}

private final class BulkInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.withLock { self.value += 1 }
    }

    var count: Int {
        self.lock.withLock { self.value }
    }
}

private final class BiomeAlternativeInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInputs: [(distance: Int64, node: Int32)] = []
    let returnedNode: Int32

    init(returnedNode: Int32) {
        self.returnedNode = returnedNode
    }

    func invoke(initialDistance: Int64, initialNode: Int32) -> Int32 {
        self.lock.withLock {
            self.storedInputs.append((initialDistance, initialNode))
        }
        return self.returnedNode
    }

    var inputs: [(distance: Int64, node: Int32)] {
        self.lock.withLock { self.storedInputs }
    }
}

@Test func testWASMBackendUsesHostRuntimeForDensityInvocation() throws {
    let densityFunction = ShiftDensityFunction(noise: HostRuntimeTestNoise(), shiftType: .SHIFT_XZ)
    let compiled = try compile(
        densityFunction: densityFunction,
        strategy: .wasm,
        runtime: TestHostWASMRuntime()
    )

    let expected = Double(2 + 3 + 4) + HostRuntimeTestNoise().sample(x: 2, y: 3, z: 4)
    #expect(compiled(2, 3, 4) == expected)
}

@Test func testWASMBackendUsesHostRuntimeForBiomeInvocation() throws {
    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    let zero = ParameterRange(min: 0, max: 0)
    let tree = try BiomeSearchTree(entries: [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -1),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyA
        ),
        (
            NoiseHypercube(
                temperature: ParameterRange(min: 0, max: 10_000),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyB
        )
    ])
    let compiled = try tree.compile(strategy: .wasm, runtime: TestHostWASMRuntime())

    #expect(compiled(NoisePoint(
        temperature: -0.5,
        humidity: 0,
        continentalness: 0,
        erosion: 0,
        weirdness: 0,
        depth: 0
    )) == keyA)
    #expect(compiled(NoisePoint(
        temperature: 0.5,
        humidity: 0,
        continentalness: 0,
        erosion: 0,
        weirdness: 0,
        depth: 0
    )) == keyB)
}

@Test func testCompiledBiomeSearchAlternativeIsStoredPerTreeAndThreadSafe() throws {
    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    let zero = ParameterRange(min: 0, max: 0)
    let tree = try BiomeSearchTree(entries: [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -1),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyA
        ),
        (
            NoiseHypercube(
                temperature: ParameterRange(min: 0, max: 10_000),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyB
        )
    ])
    let snapshot = tree.makeCompilerSnapshot()
    let leafIndex = try #require(snapshot.tree.nodes.indices.first {
        snapshot.tree.nodes[$0].isLeaf && snapshot.tree.nodes[$0].valueIndex == 0
    })
    let recorder = BiomeAlternativeInvocationRecorder(returnedNode: Int32(leafIndex))
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, _ in { _, _, _ in 0 } },
        instantiateBiomeSearch: { _, _ in
            { _, _, _, _, _, _, initialDistance, initialNode in
                recorder.invoke(initialDistance: initialDistance, initialNode: initialNode)
            }
        }
    )
    let compiled = try tree.compile(
        strategy: .wasm,
        useAlternativeNode: true,
        runtime: runtime
    )
    let point = NoisePoint(
        temperature: -0.5,
        humidity: 0,
        continentalness: 0,
        erosion: 0,
        weirdness: 0,
        depth: 0
    )

    #expect(compiled.usesAlternativeNode)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        _ = compiled(point)
    }
    let concurrentInputs = recorder.inputs
    #expect(concurrentInputs.count == 32)
    #expect(concurrentInputs.contains { $0.node == -1 && $0.distance == Int64.max })
    #expect(concurrentInputs.allSatisfy {
        ($0.node == -1 && $0.distance == Int64.max)
            || ($0.node == Int32(leafIndex) && $0.distance == 0)
    })

    compiled.resetAlternative()
    #expect(compiled(point) == keyA)
    #expect(recorder.inputs.last?.node == -1)

    let secondRecorder = BiomeAlternativeInvocationRecorder(returnedNode: Int32(leafIndex))
    let secondRuntime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, _ in { _, _, _ in 0 } },
        instantiateBiomeSearch: { _, _ in
            { _, _, _, _, _, _, initialDistance, initialNode in
                secondRecorder.invoke(initialDistance: initialDistance, initialNode: initialNode)
            }
        }
    )
    let secondCompiled = try tree.compile(
        strategy: .wasm,
        useAlternativeNode: true,
        runtime: secondRuntime
    )
    #expect(secondCompiled(point) == keyA)
    #expect(secondRecorder.inputs.first?.node == -1)
}

@Test func testGeneratedWASMBiomeSearchUsesAlternativeNodeInputs() throws {
    let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    guard let nodePath = nodeCandidates.first(where: FileManager.default.fileExists(atPath:)) else { return }

    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    let zero = ParameterRange(min: 0, max: 0)
    let tree = try BiomeSearchTree(entries: [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -1), humidity: zero,
                continentalness: zero, erosion: zero, depth: zero, weirdness: zero, offset: zero
            ),
            keyA
        ),
        (
            NoiseHypercube(
                temperature: ParameterRange(min: 0, max: 10_000), humidity: zero,
                continentalness: zero, erosion: zero, depth: zero, weirdness: zero, offset: zero
            ),
            keyB
        )
    ])
    let snapshot = tree.makeCompilerSnapshot()
    let nodeA = try #require(snapshot.tree.nodes.indices.first {
        snapshot.tree.nodes[$0].isLeaf && snapshot.tree.nodes[$0].valueIndex == 0
    })
    let nodeB = try #require(snapshot.tree.nodes.indices.first {
        snapshot.tree.nodes[$0].isLeaf && snapshot.tree.nodes[$0].valueIndex == 1
    })
    let compiled = try tree.compile(strategy: .wasm, useAlternativeNode: true)
    let moduleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpreader-biome-alternative-\(UUID().uuidString).wasm")
    try Data(try #require(compiled.wasmModule)).write(to: moduleURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: moduleURL) }

    let script = """
    const fs = require('fs');
    WebAssembly.instantiate(fs.readFileSync(process.argv[1])).then(({ instance }) => {
      const search = instance.exports.search;
      const none = 9223372036854775807n;
      const a = search(-0.5, 0, 0, 0, 0, 0, none, -1);
      const b = search(0.5, 0, 0, 0, 0, 0, 25010001n, a);
      if (a !== \(nodeA) || b !== \(nodeB)) {
        throw new Error(`unexpected alternative search nodes: ${a}, ${b}`);
      }
    });
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodePath)
    process.arguments = ["-e", script, moduleURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "Node WASM biome search failed: \(errorOutput)")
}

@Test func testWASMBakedNoiseStaysInsideGeneratedModule() throws {
    var random = XoroshiroRandom(seed: 0x1234_5678_9abc_def0)
    let sampler = DoublePerlinNoise(
        random: &random,
        firstOctave: -5,
        amplitudes: [1.0, 0.5, 0.0, 0.25],
        useModernInitialization: true
    )
    let bakedNoise = BakedNoise(
        fromKey: RegistryKey(referencing: "test:embedded_wasm_noise"),
        withSampler: sampler
    )
    let densityFunction = NoiseDensityFunction(noise: bakedNoise, scaleXZ: 0.125, scaleY: 0.25)
    let compiled = try compile(densityFunction: densityFunction, strategy: .wasm)
    let module = try #require(compiled.wasmModule)

    #expect(Data(module).range(of: Data("sample_noise".utf8)) == nil)
    #expect(Data(module).range(of: Data("sample_density".utf8)) == nil)

    let positions = [
        PosInt3D(x: -17, y: 5, z: 29),
        PosInt3D(x: 0, y: 0, z: 0),
        PosInt3D(x: 1234, y: -64, z: -987)
    ]
    for position in positions {
        #expect(compiled(position.x, position.y, position.z) == densityFunction.sample(at: position))
    }

    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_DENSITY_WASM_OUTPUT_PATH"] {
        try Data(module).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("embedded density WASM expected samples:", positions.map { densityFunction.sample(at: $0) })
    }
}

@Test func testWASMSharedSeedNoiseUpdatesWithoutReinstantiation() throws {
    var firstRandom = XoroshiroRandom(seed: 11)
    let firstSampler = DoublePerlinNoise(
        random: &firstRandom,
        firstOctave: -5,
        amplitudes: [1.0, 0.5, 0.25],
        useModernInitialization: true
    )
    let noise = BakedNoise(
        fromKey: RegistryKey(referencing: "test:shared_seed_noise"),
        withSampler: firstSampler,
        usesSharedSeedStorage: true
    )
    let density = NoiseDensityFunction(noise: noise, scaleXZ: 0.125, scaleY: 0.25)
    let instantiations = BulkInvocationCounter()
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, imports in
            instantiations.increment()
            return { x, y, z in
                imports.sampleNoise(0, Double(x) * 0.125, Double(y) * 0.25, Double(z) * 0.125)
            }
        },
        instantiateBiomeSearch: { _, _ in { _, _, _, _, _, _, _, _ in 0 } }
    )
    let compiled = try compile(densityFunction: density, strategy: .wasm, runtime: runtime)
    let position = PosInt3D(x: 1_337, y: 47, z: -9_007)
    let firstValue = compiled(position.x, position.y, position.z)
    #expect(firstValue == density.sample(at: position))

    var secondRandom = XoroshiroRandom(seed: 22)
    let secondSampler = DoublePerlinNoise(
        random: &secondRandom,
        firstOctave: -5,
        amplitudes: [1.0, 0.5, 0.25],
        useModernInitialization: true
    )
    noise.replaceSampler(with: secondSampler)
    let secondValue = compiled(position.x, position.y, position.z)

    #expect(secondValue == density.sample(at: position))
    #expect(secondValue != firstValue)
    #expect(instantiations.count == 1)
    #expect(Data(try #require(compiled.wasmModule)).range(of: Data("sample_noise".utf8)) != nil)
}

@Test func testWASMSharedLegacySeedStateUpdatesWithoutReinstantiation() throws {
    let instantiations = BulkInvocationCounter()
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, imports in
            instantiations.increment()
            return { x, y, z in imports.sampleDensity(0, x, y, z) }
        },
        instantiateBiomeSearch: { _, _ in { _, _, _, _, _, _, _, _ in 0 } }
    )

    var simplexRandom: any Random = CheckedRandom(seed: 101)
    var simplex = DensityFunctionSimplexNoise(withRandom: &simplexRandom)
    let endIslands = EndIslandsDensityFunction(withSampler: simplex)
    let compiledEnd = try compile(densityFunction: endIslands, strategy: .wasm, runtime: runtime)
    let endPosition = PosInt3D(x: 120_000, y: 0, z: -96_000)
    let firstEndValue = compiledEnd(endPosition.x, endPosition.y, endPosition.z)

    var interpolatedRandom: any Random = CheckedRandom(seed: 202)
    let interpolated = InterpolatedNoise(
        random: &interpolatedRandom,
        xzScale: 1,
        yScale: 1,
        xzFactor: 80,
        yFactor: 160,
        smearScaleMultiplier: 8
    )
    let compiledInterpolated = try compile(
        densityFunction: interpolated,
        strategy: .wasm,
        runtime: runtime
    )
    let interpolatedPosition = PosInt3D(x: 1_337, y: 47, z: -9_007)
    let firstInterpolatedValue = compiledInterpolated(
        interpolatedPosition.x,
        interpolatedPosition.y,
        interpolatedPosition.z
    )

    var secondSimplexRandom: any Random = CheckedRandom(seed: 303)
    simplex.replaceSeed(using: &secondSimplexRandom)
    var secondInterpolatedRandom: any Random = CheckedRandom(seed: 404)
    interpolated.replaceSeedState(withRandom: &secondInterpolatedRandom)

    let secondEndValue = compiledEnd(endPosition.x, endPosition.y, endPosition.z)
    let secondInterpolatedValue = compiledInterpolated(
        interpolatedPosition.x,
        interpolatedPosition.y,
        interpolatedPosition.z
    )
    #expect(secondEndValue == endIslands.sample(at: endPosition))
    #expect(secondInterpolatedValue == interpolated.sample(at: interpolatedPosition))
    #expect(secondEndValue != firstEndValue)
    #expect(secondInterpolatedValue != firstInterpolatedValue)
    #expect(instantiations.count == 2)
}

@Test func testWASMClimateCompilationUsesOneMultiValueExport() throws {
    var random = XoroshiroRandom(seed: 0x0fed_cba9_8765_4321)
    let sampler = DoublePerlinNoise(
        random: &random,
        firstOctave: -4,
        amplitudes: [1.0, 0.5, 0.25],
        useModernInitialization: true
    )
    let bakedNoise = BakedNoise(
        fromKey: RegistryKey(referencing: "test:climate_wasm_noise"),
        withSampler: sampler
    )
    let scales: [(Double, Double)] = [(0.1, 0.2), (0.2, 0.3), (0.3, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7)]
    let roots: [any DensityFunction] = scales.map {
        NoiseDensityFunction(noise: bakedNoise, scaleXZ: $0.0, scaleY: $0.1)
    }
    let compiled = try compileWASMClimateFunctions(
        roots,
        registry: Registry(),
        runtime: TestHostWASMRuntime()
    )
    #expect(Data(compiled.wasmModule).range(of: Data("sample_noise".utf8)) == nil)
    #expect(compiled.sample(x: 2, y: 3, z: 5) == WASMClimateSample(
        temperature: 2,
        humidity: 3,
        continentalness: 5,
        erosion: 5,
        weirdness: 8,
        depth: 7
    ))

    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_CLIMATE_WASM_OUTPUT_PATH"] {
        try Data(compiled.wasmModule).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        let position = PosInt3D(x: 17, y: -23, z: 41)
        print("embedded climate WASM expected samples:", roots.map { $0.sample(at: position) })
    }
}

@Test func testVanillaWASMClimateModuleUsesSharedSeedNoiseImports() throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    guard FileManager.default.fileExists(atPath: vanillaDataPath.path) else { return }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let runtime = CapturingClimateWASMRuntime()
    let generator = try WorldGenerator(
        withWorldSeed: 50123537021,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld"),
        buildSearchTrees: false,
        compilationBackend: .wasm,
        wasmRuntime: runtime
    )
    let router = try generator.terrainSettingsForTesting().noiseRouter
    let roots: [any DensityFunction] = [
        router.temperature,
        router.humidity,
        router.continents,
        router.erosion,
        router.weirdness,
        router.depth
    ]
    let frontend = try buildDensityFunctionIR(
        densityFunctions: roots,
        registry: generator.densityFunctionRegistryForTesting()
    )
    let previousScalarNoiseCallbacks = try roots.reduce(into: 0) { count, root in
        let scalarProgram = try buildDensityFunctionIR(
            densityFunction: root,
            registry: generator.densityFunctionRegistryForTesting()
        )
        count += scalarProgram.instructions.count { instruction in
            if case .sampleNoise = instruction { true } else { false }
        }
    }
    #expect(previousScalarNoiseCallbacks > 0)
    #expect(frontend.densityFunctions.isEmpty)
    let captured = runtime.snapshot
    #expect(captured.densityCount > 0)
    #expect(captured.climateModules.count == 1)
    let moduleData = Data(try #require(captured.climateModules.first))
    #expect(moduleData.range(of: Data("sample_noise".utf8)) != nil)
    // Vanilla depth contains a float-precision spline, which is now emitted directly into WASM.
    #expect(moduleData.range(of: Data("sample_density".utf8)) == nil)
    #expect(moduleData.count < 100_000)

    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_VANILLA_CLIMATE_WASM_OUTPUT_PATH"] {
        try moduleData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("vanilla climate WASM module:", moduleData.count, "bytes")
        print("shared seed-noise imports per climate point:", previousScalarNoiseCallbacks)
    }
}

@Test func testWASMBulkMatchesRepeatedSinglePointGeneration() throws {
    var random = XoroshiroRandom(seed: 0x6a09_e667_f3bc_c909)
    let sampler = DoublePerlinNoise(
        random: &random,
        firstOctave: -5,
        amplitudes: [1.0, 0.75, 0.5, 0.25],
        useModernInitialization: true
    )
    let bakedNoise = BakedNoise(
        fromKey: RegistryKey(referencing: "test:bulk_wasm_noise"),
        withSampler: sampler
    )
    let densityFunction = BinaryDensityFunction(
        firstOperand: NoiseDensityFunction(noise: bakedNoise, scaleXZ: 0.125, scaleY: 0.25),
        secondOperand: YClampedGradient(fromY: -64, toY: 192, fromValue: -1, toValue: 1),
        type: .ADD
    )
    let bufferContext = CompiledDensityFunctionBufferContext(
        xCount: 6,
        // A one-block-high plane cannot pair adjacent Y samples. This exercises
        // the paired-X bulk fallback used by biome-plane generation.
        yCount: 1,
        zCount: 4,
        xStep: 2,
        yStep: 3,
        zStep: 5
    )
    let basePosition = PosInt3D(x: -37, y: -23, z: 41)
    let bulk = try compile(
        densityFunction: densityFunction,
        bufferContext: bufferContext,
        strategy: .wasm
    )
    let scalar = try compile(densityFunction: densityFunction, strategy: .wasm)
    let bulkValues = bulk(at: basePosition)

    var repeatedValues: [Double] = []
    repeatedValues.reserveCapacity(bufferContext.sampleCount)
    for zOffset in 0..<bufferContext.zCount {
        for xOffset in 0..<bufferContext.xCount {
            for yOffset in 0..<bufferContext.yCount {
                repeatedValues.append(scalar(
                    basePosition.x + xOffset * bufferContext.xStep,
                    basePosition.y + yOffset * bufferContext.yStep,
                    basePosition.z + zOffset * bufferContext.zStep
                ))
            }
        }
    }
    #expect(bulkValues == repeatedValues)

    let moduleData = Data(try #require(bulk.wasmModule))
    #expect(moduleData.range(of: Data("sample_noise".utf8)) == nil)
    #expect(moduleData.range(of: Data("sample_bulk".utf8)) != nil)
    #expect(moduleData.range(of: Data("memory".utf8)) != nil)
    #expect(
        moduleData.range(of: Data([0xfd, 0xf0, 0x01])) != nil,
        "Single-output bulk modules should contain paired f64x2 IR arithmetic."
    )
    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_DENSITY_BULK_WASM_OUTPUT_PATH"] {
        try moduleData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("density bulk WASM module:", moduleData.count, "bytes")
    }
    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_SIMPLE_BULK_WASM_OUTPUT_PATH"] {
        let simpleBulk = try compile(
            densityFunction: YClampedGradient(fromY: -64, toY: 192, fromValue: -1, toValue: 1),
            bufferContext: CompiledDensityFunctionBufferContext(xCount: 16, yCount: 16, zCount: 16),
            strategy: .wasm
        )
        let simpleModule = try #require(simpleBulk.wasmModule)
        try Data(simpleModule).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("simple density bulk WASM module:", simpleModule.count, "bytes")
    }

    let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    guard let nodePath = nodeCandidates.first(where: FileManager.default.fileExists(atPath:)) else { return }
    let moduleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpreader-density-bulk-\(UUID().uuidString).wasm")
    try moduleData.write(to: moduleURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: moduleURL) }

    let script = """
    const fs = require('fs');
    const bytes = fs.readFileSync(process.argv[1]);
    const module = new WebAssembly.Module(bytes);
    if (WebAssembly.Module.imports(module).length !== 0) throw new Error('unexpected imports');
    const instance = new WebAssembly.Instance(module, {});
    const base = [\(basePosition.x), \(basePosition.y), \(basePosition.z)];
    const counts = [\(bufferContext.xCount), \(bufferContext.yCount), \(bufferContext.zCount)];
    const steps = [\(bufferContext.xStep), \(bufferContext.yStep), \(bufferContext.zStep)];
    const pointer = instance.exports.sample_bulk(...base);
    const actual = new Float64Array(instance.exports.memory.buffer, pointer, \(bufferContext.sampleCount));
    let index = 0;
    for (let z = 0; z < counts[2]; z++) {
      for (let x = 0; x < counts[0]; x++) {
        for (let y = 0; y < counts[1]; y++) {
          const expected = instance.exports.sample(
            base[0] + x * steps[0], base[1] + y * steps[1], base[2] + z * steps[2]
          );
          if (!Object.is(actual[index], expected)) {
            throw new Error(`bulk mismatch at ${index}: ${actual[index]} != ${expected}`);
          }
          index++;
        }
      }
    }
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodePath)
    process.arguments = ["-e", script, moduleURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "Node WASM bulk comparison failed: \(errorOutput)")
}

@Test func testWASMBulkUsesOneRuntimeInvocation() throws {
    let bufferContext = CompiledDensityFunctionBufferContext(xCount: 4, yCount: 3, zCount: 2)
    let counter = BulkInvocationCounter()
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, _ in { _, _, _ in 0 } },
        instantiateBiomeSearch: { _, _ in { _, _, _, _, _, _, _, _ in 0 } },
        instantiateDensityFunctionBulk: { module, exportName, memoryExportName, sampleCount, _ in
            #expect(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
            #expect(exportName == "sample_bulk")
            #expect(memoryExportName == "memory")
            #expect(sampleCount == bufferContext.sampleCount)
            return { _, _, _, output in
                counter.increment()
                output.update(repeating: 3.25, count: sampleCount)
            }
        }
    )
    let compiled = try compile(
        densityFunction: ConstantDensityFunction(value: 3.25),
        bufferContext: bufferContext,
        strategy: .wasm,
        runtime: runtime
    )
    #expect(compiled(at: PosInt3D(x: 10, y: 20, z: 30)) == [Double](
        repeating: 3.25,
        count: bufferContext.sampleCount
    ))
    #expect(counter.count == 1)
}

@Test func testNoiseRouterBiomeBulkUsesOneRuntimeInvocation() throws {
    let zeroDensity = ConstantDensityFunction(value: 0)
    let router = NoiseRouter(
        finalDensity: zeroDensity,
        barrier: zeroDensity,
        fluidLevelFloodedness: zeroDensity,
        fluidLevelSpread: zeroDensity,
        lava: zeroDensity,
        veinToggle: zeroDensity,
        veinRidged: zeroDensity,
        veinGap: zeroDensity,
        temperature: zeroDensity,
        humidity: zeroDensity,
        continents: zeroDensity,
        erosion: zeroDensity,
        depth: zeroDensity,
        weirdness: zeroDensity
    )
    let zeroRange = ParameterRange(min: 0, max: 0)
    let tree = try BiomeSearchTree(entries: [(
        NoiseHypercube(
            temperature: zeroRange,
            humidity: zeroRange,
            continentalness: zeroRange,
            erosion: zeroRange,
            depth: zeroRange,
            weirdness: zeroRange,
            offset: zeroRange
        ),
        RegistryKey(referencing: "test:only")
    )])
    let volume = CompiledDensityFunctionBufferContext(xCount: 4, yCount: 3, zCount: 2)
    let counter = BulkInvocationCounter()
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, _ in { _, _, _ in 0 } },
        instantiateBiomeSearch: { _, _ in { _, _, _, _, _, _, _, _ in 0 } },
        instantiateDensityFunctionBulk: { _, exportName, memoryExportName, sampleCount, _ in
            return { _, _, _, output in
                output.update(repeating: 0, count: sampleCount)
            }
        },
        instantiateBiomeIDBulk: { _, exportName, memoryExportName, sampleCount, _ in
            #expect(exportName == "sample_bulk")
            #expect(memoryExportName == "memory")
            #expect(sampleCount == volume.sampleCount)
            return { _, _, _, output in
                counter.increment()
                output.update(repeating: 0, count: sampleCount)
            }
        }
    )
    let sampler = try compile(
        noiseRouter: router,
        biomeSearchTree: tree,
        bufferContext: volume,
        strategy: .wasm,
        runtime: runtime
    )
    let result = sampler(at: PosInt3D(x: 10, y: 20, z: 30))
    #expect(result.biomeIDs == [Int32](repeating: 0, count: volume.sampleCount))
    #expect(result.palette.map(\.name) == ["test:only"])
    #expect(counter.count == 1)
}

@Test func testWorldGeneratorBulkSamplerFollowsReseeding() throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    guard FileManager.default.fileExists(atPath: vanillaDataPath.path) else { return }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let settings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    let volume = CompiledDensityFunctionBufferContext(
        xCount: 3,
        yCount: 2,
        zCount: 2,
        xStep: 11,
        yStep: 17,
        zStep: 23
    )
    let basePosition = PosInt3D(x: 1_337, y: 31, z: -7_919)
    let firstSeed: WorldSeed = 503_815_372
    let secondSeed: WorldSeed = 50_123_537_021
    let generator = try WorldGenerator(
        withWorldSeed: firstSeed,
        usingDataPacks: [pack],
        usingSettings: settings,
        buildSearchTrees: false,
        compilationBackend: .wasm
    )
    let sampler = try generator.makeFinalDensityBulkSampler(for: volume)
    #expect(sampler.strategy == .wasm)
    let compiledModule = sampler.wasmModule
    let firstValues = sampler(at: basePosition)

    try generator.setWorldSeed(secondSeed)
    #expect(sampler.wasmModule == compiledModule)
    let reseededValues = sampler(at: basePosition)
    let freshGenerator = try WorldGenerator(
        withWorldSeed: secondSeed,
        usingDataPacks: [pack],
        usingSettings: settings,
        buildSearchTrees: false
    )
    let expectedValues = try freshGenerator.makeFinalDensityBulkSampler(
        for: volume,
        strategy: .wasm
    )(at: basePosition)

    #expect(reseededValues == expectedValues)
    #expect(reseededValues != firstValues)
}

@Test func testWorldGeneratorClimateBiomeBulkSamplerMatchesPointsAndReseeding() throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    guard FileManager.default.fileExists(atPath: vanillaDataPath.path) else { return }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let settings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    let volume = CompiledDensityFunctionBufferContext(
        xCount: 2,
        yCount: 2,
        zCount: 2,
        xStep: 13,
        yStep: 19,
        zStep: 29
    )
    let basePosition = PosInt3D(x: 4_101, y: 47, z: -9_007)
    let generator = try WorldGenerator(
        withWorldSeed: 503_815_372,
        usingDataPacks: [pack],
        usingSettings: settings,
        compilationBackend: .wasm
    )
    let referenceGenerator = try WorldGenerator(
        withWorldSeed: 503_815_372,
        usingDataPacks: [pack],
        usingSettings: settings
    )
    let sampler = try generator.makeClimateBiomeBulkSampler(
        for: volume,
        in: dimension
    )
    let biomeIDSampler = try generator.makeBiomeIDBulkSampler(
        for: volume,
        in: dimension
    )
    let firstSamples = sampler(at: basePosition)
    #expect(firstSamples.count == volume.sampleCount)
    #expect(sampler.strategy == .wasm)

    let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    if let nodePath = nodeCandidates.first(where: FileManager.default.fileExists(atPath:)),
        let wasmModule = sampler.wasmModule
    {
        let moduleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpreader-climate-biome-bulk-\(UUID().uuidString).wasm")
        try Data(wasmModule).write(to: moduleURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: moduleURL) }
        let script = """
        const fs = require('fs');
        const module = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
        if (WebAssembly.Module.imports(module).length !== 0) throw new Error('unexpected imports');
        const instance = new WebAssembly.Instance(module, {});
        const base = [\(basePosition.x), \(basePosition.y), \(basePosition.z)];
        const counts = [\(volume.xCount), \(volume.yCount), \(volume.zCount)];
        const steps = [\(volume.xStep), \(volume.yStep), \(volume.zStep)];
        const pointer = instance.exports.sample_bulk(...base);
        const actual = new Float64Array(instance.exports.memory.buffer, pointer, \(volume.sampleCount * 7));
        let sampleIndex = 0;
        for (let z = 0; z < counts[2]; z++) {
          for (let x = 0; x < counts[0]; x++) {
            for (let y = 0; y < counts[1]; y++) {
              const expected = instance.exports.sample(
                base[0] + x * steps[0], base[1] + y * steps[1], base[2] + z * steps[2]
              );
              for (let value = 0; value < 7; value++) {
                const index = sampleIndex * 7 + value;
                if (!Object.is(actual[index], expected[value])) {
                  throw new Error(`bulk mismatch at ${index}: ${actual[index]} != ${expected[value]}`);
                }
              }
              sampleIndex++;
            }
          }
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["-e", script, moduleURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "Node climate-biome bulk comparison failed: \(errorOutput)")
    }

    func expectedSamples() throws -> [ClimateBiomeSample] {
        var samples: [ClimateBiomeSample] = []
        for zOffset in 0..<volume.zCount {
            for xOffset in 0..<volume.xCount {
                for yOffset in 0..<volume.yCount {
                    let position = PosInt3D(
                        x: basePosition.x + xOffset * volume.xStep,
                        y: basePosition.y + yOffset * volume.yStep,
                        z: basePosition.z + zOffset * volume.zStep
                    )
                    let biome = try referenceGenerator.sampleBiome(at: position, in: dimension)
                    samples.append(ClimateBiomeSample(
                        climate: referenceGenerator.sampleNoisePoint(at: position),
                        biome: try #require(biome)
                    ))
                }
            }
        }
        return samples
    }

    let firstExpected = try expectedSamples()
    let firstBiomeIDs = biomeIDSampler(at: basePosition)
    #expect(firstBiomeIDs.biomeIDs.map { firstBiomeIDs.palette[Int($0)] } == firstExpected.map(\.biome))
    for (actual, expected) in zip(firstSamples, firstExpected) {
        #expect(actual.climate == expected.climate)
        #expect(actual.biome == expected.biome)
    }

    #if canImport(CLLVM)
    let llvmSampler = try generator.makeClimateBiomeBulkSampler(
        for: volume,
        in: dimension,
        strategy: .llvm
    )
    let llvmSamples = llvmSampler(at: basePosition)
    for (actual, expected) in zip(llvmSamples, firstExpected) {
        #expect(abs(actual.climate.temperature - expected.climate.temperature) < 1e-12)
        #expect(abs(actual.climate.humidity - expected.climate.humidity) < 1e-12)
        #expect(abs(actual.climate.continentalness - expected.climate.continentalness) < 1e-12)
        #expect(abs(actual.climate.erosion - expected.climate.erosion) < 1e-12)
        #expect(abs(actual.climate.weirdness - expected.climate.weirdness) < 1e-12)
        #expect(abs(actual.climate.depth - expected.climate.depth) < 1e-8)
        #expect(actual.biome == expected.biome)
    }
    let llvmBiomeIDSampler = try generator.makeBiomeIDBulkSampler(
        for: volume,
        in: dimension,
        strategy: .llvm
    )
    let llvmBiomeIDs = llvmBiomeIDSampler(at: basePosition)
    #expect(llvmBiomeIDs.biomeIDs.map { llvmBiomeIDs.palette[Int($0)] } == firstExpected.map(\.biome))
    #endif

    try generator.setWorldSeed(50_123_537_021)
    try referenceGenerator.setWorldSeed(50_123_537_021)
    let reseededSamples = sampler(at: basePosition)
    let reseededExpected = try expectedSamples()
    let reseededBiomeIDs = biomeIDSampler(at: basePosition)
    #expect(reseededBiomeIDs.biomeIDs.map { reseededBiomeIDs.palette[Int($0)] } == reseededExpected.map(\.biome))
    for (actual, expected) in zip(reseededSamples, reseededExpected) {
        #expect(actual.climate == expected.climate)
        #expect(actual.biome == expected.biome)
    }
    #if canImport(CLLVM)
    let reseededLLVMSamples = llvmSampler(at: basePosition)
    for (actual, expected) in zip(reseededLLVMSamples, reseededExpected) {
        #expect(abs(actual.climate.temperature - expected.climate.temperature) < 1e-12)
        #expect(abs(actual.climate.humidity - expected.climate.humidity) < 1e-12)
        #expect(abs(actual.climate.continentalness - expected.climate.continentalness) < 1e-12)
        #expect(abs(actual.climate.erosion - expected.climate.erosion) < 1e-12)
        #expect(abs(actual.climate.weirdness - expected.climate.weirdness) < 1e-12)
        #expect(abs(actual.climate.depth - expected.climate.depth) < 1e-8)
        #expect(actual.biome == expected.biome)
    }
    let reseededLLVMBiomeIDs = llvmBiomeIDSampler(at: basePosition)
    #expect(reseededLLVMBiomeIDs.biomeIDs.map { reseededLLVMBiomeIDs.palette[Int($0)] } == reseededExpected.map(\.biome))
    #endif
    #expect(zip(firstSamples, reseededSamples).contains { $0.0.climate != $0.1.climate })
}

@Test func testWorldGeneratorClimateBiomeWASMBulkUsesOneRuntimeInvocation() throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    guard FileManager.default.fileExists(atPath: vanillaDataPath.path) else { return }

    let volume = CompiledDensityFunctionBufferContext(xCount: 3, yCount: 2, zCount: 2)
    let counter = BulkInvocationCounter()
    let runtime = ClosureWASMRuntime(
        instantiateDensityFunction: { _, _, _ in { _, _, _ in 0 } },
        instantiateBiomeSearch: { _, _ in { _, _, _, _, _, _, _, _ in 0 } },
        instantiateDensityFunctionBulk: { _, exportName, memoryExportName, sampleCount, _ in
            #expect(exportName == "sample_bulk")
            #expect(memoryExportName == "memory")
            #expect(sampleCount == volume.sampleCount * 7)
            return { _, _, _, output in
                counter.increment()
                output.update(repeating: 0, count: sampleCount)
            }
        }
    )
    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let generator = try WorldGenerator(
        withWorldSeed: 503_815_372,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld"),
        wasmRuntime: runtime
    )
    let sampler = try generator.makeClimateBiomeBulkSampler(
        for: volume,
        in: RegistryKey(referencing: "minecraft:overworld"),
        strategy: .wasm
    )

    #expect(sampler(at: PosInt3D(x: 0, y: 64, z: 0)).count == volume.sampleCount)
    #expect(counter.count == 1)
}
