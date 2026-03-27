import Foundation
import Testing
@testable import DPReader

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

@Test func testConcentricRingsStructurePlacementIsDeferred() async throws {
    let pack = try DataPack(
        fromRootPath: try vanillaStructurePlacementPackURL(),
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures]
    )
    let sampler = StructurePlacementSampler(withWorldSeed: 503815372, usingDataPacks: [pack])

    do {
        _ = try sampler.sampleStructureSet(
            inRegion: PosInt2D(x: 0, z: 0),
            for: RegistryKey(referencing: "minecraft:strongholds")
        )
        Issue.record("Expected concentric rings structure placement to be unsupported")
    } catch StructurePlacementSampler.Errors.unsupportedStructurePlacement(let key) {
        #expect(key == "minecraft:strongholds")
    }
}

private enum Errors: Error {
    case noVanillaDataFound
}
