import Foundation
import Testing
@testable import DPReader

private func makeBiomeIDCompilationNoiseRouter(temperature: any DensityFunction) -> NoiseRouter {
    let zero = ConstantDensityFunction(value: 0)
    return NoiseRouter(
        finalDensity: zero,
        barrier: zero,
        fluidLevelFloodedness: zero,
        fluidLevelSpread: zero,
        lava: zero,
        veinToggle: zero,
        veinRidged: zero,
        veinGap: zero,
        temperature: temperature,
        humidity: zero,
        continents: zero,
        erosion: zero,
        depth: zero,
        weirdness: zero
    )
}

private func makeBiomeIDCompilationSearchTree() throws -> BiomeSearchTree {
    let zero = ParameterRange(min: 0, max: 0)
    return try BiomeSearchTree(entries: [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -1), humidity: zero,
                continentalness: zero, erosion: zero, depth: zero, weirdness: zero, offset: zero
            ),
            RegistryKey(referencing: "test:cold")
        ),
        (
            NoiseHypercube(
                temperature: ParameterRange(min: 0, max: 10_000), humidity: zero,
                continentalness: zero, erosion: zero, depth: zero, weirdness: zero, offset: zero
            ),
            RegistryKey(referencing: "test:warm")
        )
    ])
}

@Test func testCompiledNoiseRouterBiomeBulkReturnsPaletteIDs() throws {
    let router = makeBiomeIDCompilationNoiseRouter(
        temperature: YClampedGradient(fromY: 0, toY: 3, fromValue: -1, toValue: 1)
    )
    let tree = try makeBiomeIDCompilationSearchTree()
    let volume = CompiledDensityFunctionBufferContext(xCount: 2, yCount: 4, zCount: 2)
    let wasm = try compile(
        noiseRouter: router,
        biomeSearchTree: tree,
        bufferContext: volume,
        strategy: .wasm
    )

    func verify(_ result: CompiledBiomeIDVolume) {
        #expect(result.biomeIDs.count == volume.sampleCount)
        #expect(result.palette.count == 2)
        let names = result.biomeIDs.map { result.palette[Int($0)].name }
        let expectedColumn = ["test:cold", "test:cold", "test:warm", "test:warm"]
        #expect(names == Array(repeating: expectedColumn, count: 4).flatMap { $0 })
    }

    verify(wasm(at: PosInt3D(x: 10, y: 0, z: 20)))
    #expect(wasm.wasmModule != nil)
    let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    if let nodePath = nodeCandidates.first(where: FileManager.default.fileExists(atPath:)),
       let wasmModule = wasm.wasmModule
    {
        let moduleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpreader-biome-id-bulk-\(UUID().uuidString).wasm")
        try Data(wasmModule).write(to: moduleURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: moduleURL) }
        let script = """
        const fs = require('fs');
        const instance = new WebAssembly.Instance(
          new WebAssembly.Module(fs.readFileSync(process.argv[1])), {}
        );
        const pointer = instance.exports.sample_bulk(10, 0, 20);
        const ids = new Int32Array(instance.exports.memory.buffer, pointer, \(volume.sampleCount));
        for (let index = 0; index < ids.length; index++) {
          const y = index % \(volume.yCount);
          const expected = instance.exports.sample(10, y, 20);
          if (ids[index] !== expected) throw new Error(`mismatch at ${index}`);
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
        #expect(process.terminationStatus == 0, "Node WASM biome ID bulk comparison failed: \(errorOutput)")
    }
    #if canImport(CLLVM)
    let llvm = try compile(
        noiseRouter: router,
        biomeSearchTree: tree,
        bufferContext: volume,
        strategy: .llvm
    )
    verify(llvm(at: PosInt3D(x: 10, y: 0, z: 20)))
    #endif
}

@Test func testBiomeSearchTreeFindsNearestBiome() async throws {
    let registry = Registry<Biome>()
    let biomeA = Biome(
        hasPrecipitation: true,
        temperature: 0.2,
        downfall: 0.1,
        carvers: [],
        features: [],
        spawners: [:],
        spawnCosts: [:]
    )
    let biomeB = Biome(
        hasPrecipitation: false,
        temperature: 0.9,
        downfall: 0.0,
        carvers: [],
        features: [],
        spawners: [:],
        spawnCosts: [:]
    )
    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    registry.register(biomeA, forKey: keyA)
    registry.register(biomeB, forKey: keyB)

    let paramsA = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(min: 0.0, max: 0.2),
        humidity: BiomeParameterRange(min: 0.0, max: 0.2),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )
    let paramsB = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(min: 0.8, max: 1.0),
        humidity: BiomeParameterRange(min: 0.8, max: 1.0),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )

    let entries = [
        MultiNoiseBiomeSourceBiome(biome: "test:a", parameters: paramsA),
        MultiNoiseBiomeSourceBiome(biome: "test:b", parameters: paramsB)
    ]
    let tree = try buildBiomeSearchTree(from: registry, entries: entries)

    let pointA = NoisePoint(temperature: 0.1, humidity: 0.1, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)
    let pointB = NoisePoint(temperature: 0.95, humidity: 0.9, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)
    let pointC = NoisePoint(temperature: -0.5, humidity: 0.5, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)

    let resultA = try tree.get(pointA)
    let resultB = try tree.get(pointB)
    let resultC = try tree.get(pointC)

    #expect(resultA == keyA)
    #expect(resultB == keyB)
    #expect(resultC == keyA)
}

@Test func testBiomeSearchTreeMissingBiomeThrows() async {
    let registry = Registry<Biome>()
    let params = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(value: 0.0),
        humidity: BiomeParameterRange(value: 0.0),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )
    let entries = [MultiNoiseBiomeSourceBiome(biome: "test:missing", parameters: params)]

    do {
        _ = try buildBiomeSearchTree(from: registry, entries: entries)
        #expect(Bool(false))
    } catch let error as BiomeSearchTreeError {
        switch error {
        case .missingBiome(let name):
            #expect(name == "test:missing")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

@Test func testCompiledBiomeSearchTreeUsesSharedIRAndMatchesLookup() throws {
    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    let zero = ParameterRange(min: 0, max: 0)
    let entries: [(NoiseHypercube, RegistryKey<Biome>)] = [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -2_000),
                humidity: ParameterRange(min: -10_000, max: 0),
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
                temperature: ParameterRange(min: 2_000, max: 10_000),
                humidity: ParameterRange(min: 0, max: 10_000),
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyB
        )
    ]
    let tree = try BiomeSearchTree(entries: entries)
    let snapshot = tree.makeCompilerSnapshot()
    let ir = buildBiomeSearchIR(tree: snapshot.tree)
    let wasm = try tree.compile(strategy: .wasm)

    #expect(ir.inputTypes == [.f64, .f64, .f64, .f64, .f64, .f64, .i64, .i32])
    #expect(ir.biomeSearchTrees.count == 1)
    #expect(wasm.strategy == .wasm)
    #expect(wasm.wasmModule?.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

    #if canImport(CLLVM)
    let llvm = try tree.compile(strategy: .llvm)
    #endif
    for point in [
        NoisePoint(temperature: -0.9, humidity: -0.4, continentalness: 0, erosion: 0, weirdness: 0, depth: 0),
        NoisePoint(temperature: 0.9, humidity: 0.4, continentalness: 0, erosion: 0, weirdness: 0, depth: 0),
        NoisePoint(temperature: -0.15, humidity: 0.9, continentalness: 0, erosion: 0, weirdness: 0, depth: 0),
        NoisePoint(temperature: 0.15, humidity: -0.9, continentalness: 0, erosion: 0, weirdness: 0, depth: 0)
    ] {
        tree.resetAlternative()
        let expected = try tree.get(point)
        #expect(wasm(point) == expected)
        #if canImport(CLLVM)
        #expect(llvm(point) == expected)
        #endif
    }

    let singleTree = try BiomeSearchTree(entries: [entries[0]])
    let singleCompiled = try singleTree.compile(strategy: .wasm)
    let arbitraryPoint = NoisePoint(
        temperature: 0.7,
        humidity: -0.6,
        continentalness: 0.5,
        erosion: -0.4,
        weirdness: 0.3,
        depth: -0.2
    )
    #expect(try singleTree.get(arbitraryPoint) == keyA)
    #expect(singleCompiled(arbitraryPoint) == keyA)
}

#if canImport(CLLVM)
@Test func testCompiledVanillaBiomeSearchTreeMatchesInterpretedTree() throws {
    let entries = getPredefinedBiomeSearchTreeData(for: "overworld")!.map { entry in
        (NoiseHypercube(from: entry.parameters), RegistryKey<Biome>(referencing: entry.biome))
    }
    let tree = try BiomeSearchTree(entries: entries)
    let wasm = try tree.compile(strategy: .wasm)
    let compiled = try tree.compile(strategy: .llvm)
    let wasmWithAlternative = try tree.compile(strategy: .wasm, useAlternativeNode: true)
    let llvmWithAlternative = try tree.compile(strategy: .llvm, useAlternativeNode: true)
    let wasmModule = try #require(wasm.wasmModule)
    #expect(wasmModule.count < 1_500_000)
    if let outputPath = ProcessInfo.processInfo.environment["DPREADER_BIOME_WASM_OUTPUT_PATH"] {
        try Data(wasmModule).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("biome search WASM module:", wasmModule.count, "bytes at", outputPath)
    }
    var randomState: UInt64 = 0x4d595df4d0f33173

    func nextParameter() -> Double {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(Int(randomState % 20_001) - 10_000) / 10_000.0
    }

    let points = (0..<256).map { _ in
        NoisePoint(
            temperature: nextParameter(),
            humidity: nextParameter(),
            continentalness: nextParameter(),
            erosion: nextParameter(),
            weirdness: nextParameter(),
            depth: nextParameter()
        )
    }
    for point in points {
        tree.resetAlternative()
        let expected = tree.getUnchecked(point)
        #expect(wasm(point) == expected)
        #expect(compiled(point) == expected)
    }

    tree.resetAlternative()
    wasmWithAlternative.resetAlternative()
    llvmWithAlternative.resetAlternative()
    for point in points {
        let expected = tree.getUnchecked(point)
        #expect(wasmWithAlternative(point) == expected)
        #expect(llvmWithAlternative(point) == expected)
    }

    if ProcessInfo.processInfo.environment["DPREADER_BIOME_COMPILER_BENCHMARK"] == "1" {
        let iterations = 1_000
        let lookupState = tree.makeReusableLookupState()
        var interpretedChecksum = 0
        var start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            for point in points {
                interpretedChecksum &+= tree.getUnchecked(
                    temperature: point.temperature,
                    humidity: point.humidity,
                    continentalness: point.continentalness,
                    erosion: point.erosion,
                    weirdness: point.weirdness,
                    depth: point.depth,
                    using: lookupState
                ).name.count
            }
        }
        let interpretedNanos = DispatchTime.now().uptimeNanoseconds - start

        var compiledChecksum = 0
        start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            for point in points {
                compiledChecksum &+= compiled(point).name.count
            }
        }
        let compiledNanos = DispatchTime.now().uptimeNanoseconds - start
        #expect(compiledChecksum == interpretedChecksum)
        print(
            "biome search benchmark:",
            "interpreted", interpretedNanos, "ns;",
            "compiled", compiledNanos, "ns;",
            "speedup", Double(interpretedNanos) / Double(compiledNanos)
        )
    }
}
#endif

// Tests whether the vanilla biome search tree matches the stupid one implemented here.
// While these tests are somewhat comprehensive, they don't cover the entire biome space.
// Any potential further offenders should be added here.
@Test func testVanillaBiomeSearchTree() async throws {
    enum Errors: Error { case noVanillaDataFound }

    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw Errors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let entries = getPredefinedBiomeSearchTreeData(for: "overworld")!
    let tree = try buildBiomeSearchTree(from: pack.biomeRegistry, entries: entries)

    //let swampNodes = tree.nodes(with: RegistryKey(referencing: "minecraft:swamp"))
    //let mangroveSwampNodes = tree.nodes(with: RegistryKey(referencing: "minecraft:mangrove_swamp"))
    //let swampText = swampNodes.map { node in
    //    "T=\(node.parameters[0]),H=\(node.parameters[1]),C=\(node.parameters[2]),E=\(node.parameters[3]),W=\(node.parameters[5]),D=\(node.parameters[4]),O=\(node.parameters[6])"
    //}
    //let mangroveSwampText = mangroveSwampNodes.map { node in
    //    "T=\(node.parameters[0]),H=\(node.parameters[1]),C=\(node.parameters[2]),E=\(node.parameters[3]),W=\(node.parameters[5]),D=\(node.parameters[4]),O=\(node.parameters[6])"
    //}
    //print("Swamp: \(swampText), Mangrove Swamp: \(mangroveSwampText)")

    // Generated from cubiomes; numbers are cubiomes biome IDs
    let npdata: [[Int]: Int] = [[5075, 2432, -151, 5500, -15067, 2738]: 163, [-6352, -9181, -988, -1976, -50744, -5428]: 12, [-6642, 7870, -7152, 9349, -24698, -8959]: 50, [-9024, -6930, -2836, -2377, -13763, 9726]: 10, [-9131, 8390, -3485, 7856, -25013, -2777]: 10, [4719, 9309, -885, -9788, -59074, 3848]: 21, [1149, -895, -4906, -2945, -35882, -6651]: 24, [-6961, 2449, -6831, 1763, -34918, 9782]: 50, [-1333, -8577, 5054, 7571, -63639, 2403]: 6, [-7418, 8089, -394, 1850, -4326, -3700]: 5, [-7721, -8499, -2533, -518, -69542, -2372]: 10, [-6691, 2455, -892, 4857, -32181, -4671]: 30, [2130, 1641, -3135, -1252, -70642, 9960]: 45, [-4393, 7502, -1979, -4646, -19411, 2433]: 46, [-1155, 8250, -2804, 626, -72669, -2495]: 0, [-8949, 336, 3145, -1227, -71325, -3087]: 12, [8585, 311, -3033, 6358, -28144, 5035]: 44, [-5319, -1321, -5425, -1919, -6421, 7661]: 50, [-1391, 9155, 4038, 9121, -27650, 1861]: 6, [-2814, -5468, 6696, 6171, -68085, -8457]: 1, [-6408, -4992, -4758, 3833, -1828, -7919]: 50, [2608, 2504, 9526, 5337, -10648, -1762]: 21, [8128, -9624, -6247, 7595, -45027, 1146]: 44, [-6345, -383, 4246, -4818, -20530, -9894]: 178, [-1370, 6403, -4146, 6635, -66053, -221]: 0, [6635, 9954, -3483, -4992, -30991, -4707]: 44, [7674, 7378, -9982, 9626, -37513, 6010]: 44, [-9362, -6335, 1894, 76, -48615, -8102]: 12, [-2108, 8591, -7420, -7194, -16301, -7733]: 49, [7455, -5880, -5793, 5574, -7937, -4590]: 44, [-1315, 7290, 9876, 3865, -52240, 7671]: 29, [-3409, 214, 3074, 2236, -22578, 6959]: 4, [4794, -6035, -1877, -2638, -71608, 1078]: 25, [-9311, 9277, 8150, -2460, -2872, -2784]: 30, [-9765, -7674, -8071, -2499, -71166, -8971]: 50, [827, -7679, 6847, -2202, -43500, 5906]: 185, [-2980, 7669, -5665, 8711, -4475, 5488]: 49, [-2038, 5498, 3338, -3761, -67637, -6824]: 180, [4124, 1609, 3879, 3470, -18787, -8225]: 21, [-6776, -8014, 3193, 1118, -65678, -1853]: 12, [-3722, -3768, 7573, 4700, -61627, 3824]: 131, [-3988, -873, 5159, -1815, -70120, 4520]: 177, [8033, -6792, -8343, 7713, -78066, -6944]: 44, [-2255, -4551, 3317, 5913, -16908, -2996]: 6, [3141, -8079, -4606, 2418, -79718, 2793]: 48, [-1310, 4909, -653, 3861, -7155, 5947]: 29, [-4928, -3778, -278, -2867, -72335, 8978]: 140, [7766, -8003, 276, -8127, -73428, 9142]: 165, [5623, 6477, 7403, -4842, -72545, 6640]: 38, [-7375, -3911, -7755, 9498, -71093, -2293]: 50, [3230, -6072, 8667, -1933, -4120, 9481]: 35, [-8698, -7314, 3737, 9125, -5915, 7130]: 140, [366, -1456, -3307, 295, -48715, -1297]: 0, [2969, -5712, -170, 4982, -38559, -7623]: 35, [-9695, 5017, 8448, -6724, -70398, 7617]: 181, [-3016, 6576, -1310, -5660, -34255, -7746]: 160, [-1996, 2108, -662, -4831, -22567, 7800]: 5, [-88, 7332, -9744, 8173, -40760, -6606]: 24, [-5600, -1334, -6218, -6493, -7488, -4907]: 50, [-1076, -768, 9819, -3099, -35058, -3329]: 177, [-1350, 6561, 6008, -1772, -73342, -6976]: 29, [3879, -934, -8556, -9884, -36281, -5714]: 48, [-1417, -4706, 4478, 8077, -23943, 8379]: 129, [-9684, -6335, -7535, -5116, -8489, -8820]: 50, [2098, 9087, 8105, -5148, -23667, -5824]: 182, [-8630, 101, 1948, -8693, -33102, -3117]: 178, [-1824, -6632, 1589, 8346, -26736, -4936]: 1, [-2243, -4676, -4199, 3510, -76752, -4123]: 46, [885, 3491, -1869, -1258, -59134, -6458]: 29, [2535, -8732, 5423, -2712, -53842, 5083]: 36, [1457, 0, -2543, -2696, -76899, -3672]: 0, [3056, 756, -871, -7726, -43415, 1506]: 1, [6692, 3096, 7570, 851, -76383, -6221]: 2, [-1441, -4149, 9024, -1302, -74986, -6448]: 177, [9548, 4239, 1327, 278, -22801, 9864]: 38, [6758, -6211, 2622, 8893, -55086, -1654]: 184, [-8546, 4288, -9945, 7036, -9425, -3544]: 50, [1934, 4132, -7708, 819, -38855, -5917]: 24, [-160, 6617, 134, 3382, -37247, 3185]: 29, [-312, 8166, -5830, -3714, -24892, 2423]: 24, [-4298, 8648, -139, 3306, -8181, -9987]: 160, [-43, -599, -3113, 4086, -3981, 9879]: 0, [559, 5236, 4476, 4488, -51990, 6750]: 29, [5505, -4440, -7222, -701, -12439, 983]: 44, [-6940, -2304, 171, -2639, -53900, -5172]: 12, [-9200, -8486, -1977, 5569, -70455, 4923]: 10, [3580, 8863, -3629, 2582, -15201, 3095]: 45, [-2006, -5165, -9819, -6508, -24276, -2830]: 49, [-4237, 6972, 5222, -8355, -6940, -1835]: 160, [-6024, 4957, -5631, 5225, -10384, 8314]: 50, [9511, 397, 4502, 6540, -24067, 7952]: 2, [4611, -4785, 5554, 4747, -46028, -1899]: 35, [-914, 7081, 5879, -2161, -44008, 4413]: 186, [-7462, -638, -2317, -1097, -35980, 476]: 10, [7699, -7360, -5466, -5058, -49689, 2551]: 44, [-4993, -2990, -7896, 3594, -26576, 842]: 50, [7780, 5267, 3624, -7960, -52890, 3767]: 38, [2762, 9139, -9360, 8864, -30143, 5629]: 48, [-9807, 1526, -216, 2779, -25079, 7636]: 30, [7895, 9767, -2774, 5998, -51240, -1057]: 44, [4281, 5913, -9049, 2742, -35943, 3248]: 48, ]
    let cubiomesIdMap: [Int: String] = [-1: "minecraft:none", 0: "minecraft:ocean", 1: "minecraft:plains", 2: "minecraft:desert", 3: "minecraft:windswept_hills", 4: "minecraft:forest", 5: "minecraft:taiga", 6: "minecraft:swamp",7: "minecraft:river",8: "minecraft:nether_wastes",9: "minecraft:the_end",10: "minecraft:frozen_ocean",11: "minecraft:frozen_river",12: "minecraft:snowy_plains",13: "minecraft:snowy_mountains",14: "minecraft:mushroom_fields",15: "minecraft:mushroom_field_shore",16: "minecraft:beach",17: "minecraft:desert_hills",18: "minecraft:wooded_hills",19: "minecraft:taiga_hills",20: "minecraft:mountain_edge",21: "minecraft:jungle",22: "minecraft:jungle_hills",23: "minecraft:sparse_jungle",24: "minecraft:deep_ocean",25: "minecraft:stony_shore",26: "minecraft:snowy_beach",27: "minecraft:birch_forest",28: "minecraft:birch_forest_hills",29: "minecraft:dark_forest",30: "minecraft:snowy_taiga",31: "minecraft:snowy_taiga_hills",32: "minecraft:old_growth_pine_taiga",33: "minecraft:giant_tree_taiga_hills",34: "minecraft:windswept_forest",35: "minecraft:savanna",36: "minecraft:savanna_plateau",37: "minecraft:badlands",38: "minecraft:wooded_badlands",39: "minecraft:badlands_plateau",40: "minecraft:small_end_islands",41: "minecraft:end_midlands",42: "minecraft:end_highlands",43: "minecraft:end_barrens",44: "minecraft:warm_ocean",45: "minecraft:lukewarm_ocean",46: "minecraft:cold_ocean",47: "minecraft:deep_warm_ocean",48: "minecraft:deep_lukewarm_ocean",49: "minecraft:deep_cold_ocean",50: "minecraft:deep_frozen_ocean",51: "minecraft:seasonal_forest",52: "minecraft:rainforest",53: "minecraft:shrubland",127: "minecraft:the_void",129: "minecraft:sunflower_plains",130: "minecraft:desert_lakes",131: "minecraft:windswept_gravelly_hills",132: "minecraft:flower_forest",133: "minecraft:taiga_mountains",134: "minecraft:swamp_hills",140: "minecraft:ice_spikes",149: "minecraft:modified_jungle",151: "minecraft:modified_jungle_edge",155: "minecraft:old_growth_birch_forest",156: "minecraft:tall_birch_hills",157: "minecraft:dark_forest_hills",158: "minecraft:snowy_taiga_mountains",160: "minecraft:old_growth_spruce_taiga",161: "minecraft:giant_spruce_taiga_hills",162: "minecraft:modified_gravelly_mountains",163: "minecraft:windswept_savanna",164: "minecraft:shattered_savanna_plateau",165: "minecraft:eroded_badlands",166: "minecraft:modified_wooded_badlands_plateau",167: "minecraft:modified_badlands_plateau",168: "minecraft:bamboo_jungle",169: "minecraft:bamboo_jungle_hills",170: "minecraft:soul_sand_valley",171: "minecraft:crimson_forest",172: "minecraft:warped_forest",173: "minecraft:basalt_deltas",174: "minecraft:dripstone_caves",175: "minecraft:lush_caves",177: "minecraft:meadow",178: "minecraft:grove",179: "minecraft:snowy_slopes",180: "minecraft:jagged_peaks",181: "minecraft:frozen_peaks",182: "minecraft:stony_peaks",183: "minecraft:deep_dark",184: "minecraft:mangrove_swamp",185: "minecraft:cherry_grove",186: "minecraft:pale_garden"]
    
    for (noisePoint, biomeID) in npdata {
        // There's a potential bug in Cubiomes that makes pale gardens less common.
        // Therefore, we ignore dark forests here (as they're what the lost pale gardens get replaced with).
        // See the note in `BiomeSearchTree.swift` for more details.
        if (biomeID == 29) { continue }
        tree.resetAlternative()
        let biomeName = cubiomesIdMap[biomeID]!
        let point = NoisePoint(
            temperature: Double(noisePoint[0]) / 10000.0,
            humidity: Double(noisePoint[1]) / 10000.0,
            continentalness: Double(noisePoint[2]) / 10000.0,
            erosion: Double(noisePoint[3]) / 10000.0,
            weirdness: Double(noisePoint[5]) / 10000.0,
            depth: Double(noisePoint[4]) / 10000.0
        )
        let foundBiome = try tree.get(point)
        if foundBiome.name != biomeName {
            let distance = tree.lastResultDistance(to: point)
            let distanceText = distance != nil ? String(distance!) : "nil"
            print("Found biome \(foundBiome.name) not expected biome \(biomeName) (with ID \(biomeID)); distance=\(distanceText)")
        }
        #expect(foundBiome.name == biomeName)
    }
}
