import Foundation
import Testing
@testable import DPReader

private enum DimensionBiomeTestErrors: Error {
    case noVanillaDataFound
    case invalidReferenceData
    case unknownCubiomesBiomeId(Int)
}

private struct CubiomesDimensionBiomeReference: Decodable {
    let seed: String
    let minecraftVersion: String
    let dimension: String
    let entries: [Entry]

    struct Entry: Decodable {
        let biomeX: Int32
        let biomeY: Int32
        let biomeZ: Int32
        let biomeID: Int

        private enum CodingKeys: String, CodingKey {
            case biomeX = "biome_x"
            case biomeY = "biome_y"
            case biomeZ = "biome_z"
            case biomeID = "biome_id"
        }
    }
}

private func cubiomesDimensionBiome(for id: Int) -> RegistryKey<Biome>? {
    switch id {
    case 8:
        return RegistryKey(referencing: "minecraft:nether_wastes")
    case 9:
        return RegistryKey(referencing: "minecraft:the_end")
    case 40:
        return RegistryKey(referencing: "minecraft:small_end_islands")
    case 41:
        return RegistryKey(referencing: "minecraft:end_midlands")
    case 42:
        return RegistryKey(referencing: "minecraft:end_highlands")
    case 43:
        return RegistryKey(referencing: "minecraft:end_barrens")
    case 170:
        return RegistryKey(referencing: "minecraft:soul_sand_valley")
    case 171:
        return RegistryKey(referencing: "minecraft:crimson_forest")
    case 172:
        return RegistryKey(referencing: "minecraft:warped_forest")
    case 173:
        return RegistryKey(referencing: "minecraft:basalt_deltas")
    default:
        return nil
    }
}

private func vanillaBiomeTestPackURL() throws -> URL {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw DimensionBiomeTestErrors.noVanillaDataFound
    }
    return vanillaDataPath
}

private func cubiomesDimensionBiomeReferenceURL(named name: String) -> URL {
    return URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/Resources/Cubiomes/\(name)")
}

private func loadCubiomesDimensionBiomeReference(
    named name: String,
    expectedSeed: String,
    expectedDimension: String,
    expectedCount: Int
) throws -> CubiomesDimensionBiomeReference {
    let data = try Data(contentsOf: cubiomesDimensionBiomeReferenceURL(named: name))
    let reference = try JSONDecoder().decode(CubiomesDimensionBiomeReference.self, from: data)
    guard reference.seed == expectedSeed,
          reference.minecraftVersion == "1.21.11",
          reference.dimension == expectedDimension,
          reference.entries.count == expectedCount else {
        throw DimensionBiomeTestErrors.invalidReferenceData
    }
    for entry in reference.entries where cubiomesDimensionBiome(for: entry.biomeID) == nil {
        throw DimensionBiomeTestErrors.unknownCubiomesBiomeId(entry.biomeID)
    }
    return reference
}

private func makeVanillaDimensionBiomeWorldGenerator(seed: UInt64, settings: String) throws -> WorldGenerator {
    let pack = try DataPack(fromRootPath: try vanillaBiomeTestPackURL())
    return try WorldGenerator(
        withWorldSeed: seed,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: settings)
    )
}

@Test func testWorldGeneratorCanReseedAndUseCompiledBiomeFunctions() throws {
    let pack = try DataPack(fromRootPath: try vanillaBiomeTestPackURL())
    let settings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    let position = PosInt3D(x: 12_345, y: 96, z: -54_321)

    let generator = try WorldGenerator(
        withWorldSeed: 503_815_372,
        usingDataPacks: [pack],
        usingSettings: settings,
        compilationBackend: .wasm,
        useBiomeSearchAlternative: true
    )
    let initialCompiledTree = try generator.getCompiledBiomeSearchTree(
        forTarget: .wasm,
        inDimension: dimension
    )
    let initialCompiledFunctions = try #require(generator.compiledDensityFunctionRegistryForTesting())
        .entries()
        .reduce(into: [String: ObjectIdentifier]()) { result, entry in
            result[entry.key.name] = ObjectIdentifier(entry.value)
        }
    #expect(initialCompiledTree.usesAlternativeNode)
    try generator.setWorldSeed(501_235_370_21)
    let reseededCompiledTree = try generator.getCompiledBiomeSearchTree(
        forTarget: .wasm,
        inDimension: dimension
    )
    #expect(reseededCompiledTree.usesAlternativeNode)
    #expect(reseededCompiledTree === initialCompiledTree)
    let reseededCompiledFunctions = try #require(generator.compiledDensityFunctionRegistryForTesting())
        .entries()
        .reduce(into: [String: ObjectIdentifier]()) { result, entry in
            result[entry.key.name] = ObjectIdentifier(entry.value)
        }
    #expect(reseededCompiledFunctions == initialCompiledFunctions)

    let reseededPoint = generator.sampleNoisePoint(at: position)
    let reseededBiome = try generator.sampleBiome(at: position, in: dimension)
    let freshGenerator = try WorldGenerator(
        withWorldSeed: 501_235_370_21,
        usingDataPacks: [pack],
        usingSettings: settings
    )
    let freshPoint = freshGenerator.sampleNoisePoint(at: position)
    let freshBiome = try freshGenerator.sampleBiome(at: position, in: dimension)

    #expect(reseededPoint.temperature == freshPoint.temperature)
    #expect(reseededPoint.humidity == freshPoint.humidity)
    #expect(reseededPoint.continentalness == freshPoint.continentalness)
    #expect(reseededPoint.erosion == freshPoint.erosion)
    #expect(reseededPoint.weirdness == freshPoint.weirdness)
    #expect(reseededPoint.depth == freshPoint.depth)
    #expect(reseededBiome == freshBiome)
}

@Test func testVanillaNetherBiomesMatchCubiomesReference() async throws {
    let reference = try loadCubiomesDimensionBiomeReference(
        named: "nether_biomes_seed_503815372.json",
        expectedSeed: "503815372",
        expectedDimension: "minecraft:the_nether",
        expectedCount: 20
    )
    let world = try makeVanillaDimensionBiomeWorldGenerator(seed: 503815372, settings: "minecraft:nether")
    let dim = RegistryKey<DPReader.Dimension>(referencing: "minecraft:nether")

    for entry in reference.entries {
        let pos = PosInt3D(x: entry.biomeX * 4, y: entry.biomeY * 4, z: entry.biomeZ * 4)
        let biome = try world.sampleBiome(at: pos, in: dim)
        let expectedBiome = cubiomesDimensionBiome(for: entry.biomeID)
        #expect(
            biome == expectedBiome,
            "Biome mismatch at quart (\(entry.biomeX), \(entry.biomeY), \(entry.biomeZ)): expected \(expectedBiome?.name ?? "nil"), got \(biome?.name ?? "nil")"
        )
    }
}

@Test func testVanillaEndBiomesMatchCubiomesReference() async throws {
    let reference = try loadCubiomesDimensionBiomeReference(
        named: "end_biomes_seed_503815372.json",
        expectedSeed: "503815372",
        expectedDimension: "minecraft:the_end",
        expectedCount: 20
    )
    let world = try makeVanillaDimensionBiomeWorldGenerator(seed: 503815372, settings: "minecraft:end")
    let dim = RegistryKey<DPReader.Dimension>(referencing: "minecraft:end")

    for entry in reference.entries {
        let pos = PosInt3D(x: entry.biomeX * 4, y: entry.biomeY * 4, z: entry.biomeZ * 4)
        let biome = try world.sampleBiome(at: pos, in: dim)
        let expectedBiome = cubiomesDimensionBiome(for: entry.biomeID)
        #expect(
            biome == expectedBiome,
            "Biome mismatch at quart (\(entry.biomeX), \(entry.biomeY), \(entry.biomeZ)): expected \(expectedBiome?.name ?? "nil"), got \(biome?.name ?? "nil")"
        )
    }
}
