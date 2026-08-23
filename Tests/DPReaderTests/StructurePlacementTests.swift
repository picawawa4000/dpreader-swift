import Foundation
import Testing
@testable import DPReader

private struct CubiomesNetherComplexReference: Decodable {
    let seed: UInt64
    let entries: [Entry]

    struct Entry: Decodable {
        let regionX: Int32
        let regionZ: Int32
        let chunkX: Int32
        let chunkZ: Int32
        let structure: String

        private enum CodingKeys: String, CodingKey {
            case regionX = "region_x"
            case regionZ = "region_z"
            case chunkX = "chunk_x"
            case chunkZ = "chunk_z"
            case structure
        }
    }
}

private func vanillaStructurePlacementPackURL() throws -> URL {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw Errors.noVanillaDataFound
    }
    return vanillaDataPath
}

private func cubiomesNetherComplexReferenceURL() -> URL {
    return URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/Resources/Cubiomes/nether_complexes_seed_503815372.json")
}

@Test func testVanillaRandomSpreadStructurePlacementSamples() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    let desertPyramids = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        for: RegistryKey(referencing: "minecraft:desert_pyramids")
    )
    #expect(desertPyramids != nil)
    #expect(desertPyramids!.chunkPos == PosInt2D(x: 22, z: 4))
    #expect(desertPyramids!.blockPos == PosInt2D(x: 352, z: 64))

    let villages = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        for: RegistryKey(referencing: "minecraft:villages")
    )
    #expect(villages != nil)
    #expect(villages!.chunkPos == PosInt2D(x: 12, z: 18))
    #expect(villages!.blockPos == PosInt2D(x: 192, z: 288))
    #expect(villages!.structures.count == 5)

    let woodlandMansions = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        for: RegistryKey(referencing: "minecraft:woodland_mansions")
    )
    #expect(woodlandMansions != nil)
    #expect(woodlandMansions!.chunkPos == PosInt2D(x: 31, z: 9))
    #expect(woodlandMansions!.blockPos == PosInt2D(x: 496, z: 144))

    let ancientCities = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        for: RegistryKey(referencing: "minecraft:ancient_cities")
    )
    #expect(ancientCities != nil)
    #expect(ancientCities!.chunkPos == PosInt2D(x: 12, z: 5))
    #expect(ancientCities!.blockPos == PosInt2D(x: 192, z: 80))

    let buriedTreasures = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: -19, z: 9),
        for: RegistryKey(referencing: "minecraft:buried_treasures")
    )
    #expect(buriedTreasures != nil)
    #expect(buriedTreasures!.chunkPos == PosInt2D(x: -19, z: 9))
    #expect(buriedTreasures!.blockPos == PosInt2D(x: -295, z: 153))

    let mineshafts = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: -14, z: 7),
        for: RegistryKey(referencing: "minecraft:mineshafts")
    )
    #expect(mineshafts != nil)
    #expect(mineshafts!.chunkPos == PosInt2D(x: -14, z: 7))
    #expect(mineshafts!.blockPos == PosInt2D(x: -224, z: 112))
}

@Test func testVanillaOutpostPlacementRespectsExclusionZone() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    let included = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: -20, z: -15),
        for: RegistryKey(referencing: "minecraft:pillager_outposts")
    )
    #expect(included != nil)
    #expect(included!.chunkPos == PosInt2D(x: -617, z: -476))
    #expect(included!.blockPos == PosInt2D(x: -9872, z: -7616))

    let excluded = try sampler.sampleStructureSet(
        inRegion: PosInt2D(x: -20, z: -18),
        for: RegistryKey(referencing: "minecraft:pillager_outposts")
    )
    #expect(excluded == nil)
}

@Test func testVanillaConcentricRingsStructurePlacementMatchesCubiomesReference() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    let placements = try sampler.sampleAllPlacements(
        for: RegistryKey(referencing: "minecraft:strongholds")
    )
    #expect(placements.count == 128)

    let expected: [(chunk: PosInt2D, block: PosInt2D)] = [
        (PosInt2D(x: -112, z: -126), PosInt2D(x: -1788, z: -2012)),
        (PosInt2D(x: 109, z: -27), PosInt2D(x: 1748, z: -428)),
        (PosInt2D(x: -28, z: 87), PosInt2D(x: -444, z: 1396)),
        (PosInt2D(x: -341, z: -27), PosInt2D(x: -5452, z: -428)),
        (PosInt2D(x: -128, z: -269), PosInt2D(x: -2044, z: -4300))
    ]
    for (placement, expectedPlacement) in zip(placements.prefix(expected.count), expected) {
        #expect(placement.chunkPos == expectedPlacement.chunk)
        #expect(placement.blockPos == expectedPlacement.block)
        let sampled = try sampler.sampleStructureSet(
            inRegion: placement.chunkPos,
            for: RegistryKey(referencing: "minecraft:strongholds")
        )
        #expect(sampled!.chunkPos == expectedPlacement.chunk)
        #expect(sampled!.blockPos == expectedPlacement.block)
    }
}

@Test func testVanillaStructureResolutionMatchesBiomeTags() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    let villages = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        biome: RegistryKey(referencing: "minecraft:plains"),
        for: RegistryKey(referencing: "minecraft:villages")
    )
    #expect(villages?.structureKey == RegistryKey(referencing: "minecraft:village_plains"))

    let mineshafts = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: -14, z: 7),
        biome: RegistryKey(referencing: "minecraft:badlands"),
        for: RegistryKey(referencing: "minecraft:mineshafts")
    )
    #expect(mineshafts?.structureKey == RegistryKey(referencing: "minecraft:mineshaft_mesa"))

    let shipwrecks = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        biome: RegistryKey(referencing: "minecraft:beach"),
        for: RegistryKey(referencing: "minecraft:shipwrecks")
    )
    #expect(shipwrecks?.structureKey == RegistryKey(referencing: "minecraft:shipwreck_beached"))

    let noVillage = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        biome: RegistryKey(referencing: "minecraft:nether_wastes"),
        for: RegistryKey(referencing: "minecraft:villages")
    )
    #expect(noVillage == nil)
}

@Test func testVanillaNetherComplexResolutionMatchesCubiomesReference() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let referenceData = try Data(contentsOf: cubiomesNetherComplexReferenceURL())
    let reference = try JSONDecoder().decode(CubiomesNetherComplexReference.self, from: referenceData)
    #expect(reference.seed == 503815372)
    let sampler = StructurePlacementSampler(withWorldSeed: reference.seed, usingDataPacks: [pack])

    for entry in reference.entries {
        let resolved = try sampler.resolveStructureSet(
            inRegion: PosInt2D(x: entry.regionX, z: entry.regionZ),
            biome: RegistryKey(referencing: "minecraft:nether_wastes"),
            for: RegistryKey(referencing: "minecraft:nether_complexes")
        )
        #expect(resolved != nil, "Expected a nether complex at region (\(entry.regionX), \(entry.regionZ))")
        #expect(
            resolved!.chunkPos == PosInt2D(x: entry.chunkX, z: entry.chunkZ),
            "Chunk mismatch at region (\(entry.regionX), \(entry.regionZ))"
        )
        #expect(
            resolved!.structureKey == RegistryKey(referencing: entry.structure),
            "Structure mismatch at region (\(entry.regionX), \(entry.regionZ))"
        )
    }

    let basaltDeltas = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        biome: RegistryKey(referencing: "minecraft:basalt_deltas"),
        for: RegistryKey(referencing: "minecraft:nether_complexes")
    )
    #expect(basaltDeltas?.structureKey == RegistryKey(referencing: "minecraft:fortress"))
}

@Test func testOverlappingStructureResolutionUsesWeightedSelection() async throws {
    let pack = try DataPack(
        fromRootPath: URL(filePath: "Tests/Resources/Datapacks/StructureResolution/ambiguous"),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    let resolved = try sampler.resolveStructureSet(
        inRegion: PosInt2D(x: 0, z: 0),
        biome: RegistryKey(referencing: "test:plains"),
        for: RegistryKey(referencing: "test:overlap")
    )
    #expect(resolved != nil)
    #expect(resolved!.chunkPos == PosInt2D(x: 0, z: 0))
    #expect(resolved!.structureKey == RegistryKey(referencing: "test:second"))
}

@Test func testStructureStartValidationChecksTempleCornersAndSurfaceBiomeY() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 123456789, usingDataPacks: [pack])
    let desertPyramid = RegistryKey<Structure>(referencing: "minecraft:desert_pyramid")
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")

    let lowCornerContext = StructureStartValidationContext(
        dimension: dimension,
        seaLevel: 63,
        minimumWorldY: -64,
        maximumWorldY: 319,
        heightmapSampler: { _, x, z in
            x == 20 && z == 20 ? 62 : 70
        },
        biomeSampler: { _ in RegistryKey(referencing: "minecraft:desert") }
    )
    #expect(
        try sampler.validateStructureStart(
            for: desertPyramid,
            atChunk: PosInt2D(x: 0, z: 0),
            using: lowCornerContext
        ) == nil
    )

    let validContext = StructureStartValidationContext(
        dimension: dimension,
        seaLevel: 63,
        minimumWorldY: -64,
        maximumWorldY: 319,
        heightmapSampler: { _, _, _ in 70 },
        biomeSampler: { position in
            position.y == 68 ? RegistryKey(referencing: "minecraft:desert") : RegistryKey(referencing: "minecraft:plains")
        }
    )
    let validated = try #require(
        try sampler.validateStructureStart(
            for: desertPyramid,
            atChunk: PosInt2D(x: 0, z: 0),
            using: validContext
        )
    )
    #expect(validated.generationPosition == PosInt3D(x: 8, y: 70, z: 8))
    #expect(validated.biome == RegistryKey<Biome>(referencing: "minecraft:desert"))
}

@Test func testStructureStartValidationProjectsJigsawBiomeCheckToSurface() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 123456789, usingDataPacks: [pack])
    let context = StructureStartValidationContext(
        dimension: RegistryKey(referencing: "minecraft:overworld"),
        seaLevel: 63,
        minimumWorldY: -64,
        maximumWorldY: 319,
        heightmapSampler: { heightmap, x, z in
            #expect(heightmap == .worldSurfaceWG)
            #expect(x == 0)
            #expect(z == 0)
            return 84
        },
        biomeSampler: { position in
            position.y == 84 ? RegistryKey(referencing: "minecraft:plains") : RegistryKey(referencing: "minecraft:deep_dark")
        }
    )

    let validated = try #require(
        try sampler.validateStructureStart(
            for: RegistryKey(referencing: "minecraft:village_plains"),
            atChunk: PosInt2D(x: 0, z: 0),
            using: context
        )
    )
    #expect(validated.generationPosition.y == 84)
}

@Test func testStructureStartValidationChecksMonumentSurroundingBiomes() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 123456789, usingDataPacks: [pack])
    let monument = RegistryKey<Structure>(referencing: "minecraft:monument")
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    let deepOcean = RegistryKey<Biome>(referencing: "minecraft:deep_ocean")

    let validContext = StructureStartValidationContext(
        dimension: dimension,
        seaLevel: 63,
        minimumWorldY: -64,
        maximumWorldY: 319,
        heightmapSampler: { heightmap, _, _ in
            #expect(heightmap == .oceanFloorWG)
            return 35
        },
        biomeSampler: { _ in deepOcean }
    )
    #expect(
        try sampler.validateStructureStart(
            for: monument,
            atChunk: PosInt2D(x: 0, z: 0),
            using: validContext
        ) != nil
    )

    let invalidContext = StructureStartValidationContext(
        dimension: dimension,
        seaLevel: 63,
        minimumWorldY: -64,
        maximumWorldY: 319,
        heightmapSampler: { _, _, _ in 35 },
        biomeSampler: { position in
            position == PosInt3D(x: -20, y: 32, z: -20)
                ? RegistryKey(referencing: "minecraft:plains")
                : deepOcean
        }
    )
    #expect(
        try sampler.validateStructureStart(
            for: monument,
            atChunk: PosInt2D(x: 0, z: 0),
            using: invalidContext
        ) == nil
    )
}

private enum Errors: Error {
    case noVanillaDataFound
}
