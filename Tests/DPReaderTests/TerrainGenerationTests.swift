import Foundation
import Testing
@testable import DPReader

private enum TerrainTestErrors: Error {
    case noVanillaDataFound
    case invalidEmbeddedTerrainBitset
}

private let vanillaTerrainMinY: Int32 = -64
private let vanillaTerrainHeight: Int32 = 384
private let vanillaTerrainSampleCount = ProtoChunk.sideLength * ProtoChunk.sideLength * Int(vanillaTerrainHeight)
private let vanillaTerrainEncodedBitset = """
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////v/+//////////////////////////////////z/+H/4P/gf/D////////////////////////////7//P/4f/g/+B/8P/////////////////
///////////P/4//h/+D/4H/wf/v/////////////////////////4//h/8H/wP/AP+B/+P/////////////////////////D/8H/wP/Af8A/4D/wP//////
//////////////////8H/gf+A/8A/wD/AP+A/+D//P///////////////////wf8B/wB/AD+AP4A/wD/gP/A//D/////////////////B/gD+AH4APwA/AD8
APwA/gD+AP4A/AD8APwD/v////8D4APwAPAA8AD4APgA8ADwAPAA4ADAAMAAwACAAIAAgAfgA+AA4ADgAOAA4ADAAMAAwACAAIAAgAAAAAAAAAAAB+ADwAHA
AMAAgACAAIAAAAAAAAAAAAAAAAAAAAAAAAAH4AOAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfgBwADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
DxAHAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAPEA8ABwABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAQABAP8fDwAHAAMAAAABAAEAAQABAAEAAQABAAEA
AQABAAMA/x8PAA8ABwADAAMAAwADAAMAAwADAAMAAwADAAMAAwD//////8N/AD8AHwAPAA8ABwAHAAcABwADAAcABwAHAP///////////+//A/8AfwAfAB8A
DwAPAAcABwAHAA8A////////////////////A/8AfwA/AB8ADwAPAA8ADwD//////////////////////wf/Af8APwAfAB8AHwA/AP//////////////////
/////////wP/AD8AfwB/AH8A//////////////////////////////8H/wD/AP8A/wD/////////////////////////////////A/8D/wP/A///////////
///////////////////////////////P////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////+//7//v/+//7///////////
////////////z//P/4//j/+P/8f/x//H/+f//v/8///////////////////////v/+//7//v/+//////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/v/4/8D/4P/+/////8P/h/8P/w//H/8f/z//P/j/4P8A/wDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"""

// Compare to 6 decimal places while allowing tiny floating-point drift.
private func checkDoubleTerrain(_ actualValue: Double, _ roundedExpectedValue: Int) -> Bool {
    let roundedUpActualValue = Int((actualValue * 1_000_000).rounded(.up))
    let roundedDownActualValue = Int((actualValue * 1_000_000).rounded(.down))
    if roundedExpectedValue == roundedUpActualValue || roundedExpectedValue == roundedDownActualValue {
        return true
    }

    let roundedActualValue = Int((actualValue * 1_000_000).rounded(.toNearestOrEven))
    print(
        "Error in checkDoubleTerrain: expected value",
        roundedExpectedValue,
        "did not match actual value",
        actualValue,
        "(rounded to",
        roundedActualValue,
        ")!"
    )
    return false
}

private func makeNoiseSettings(minY: Int, height: Int, finalDensity: DensityFunction) -> NoiseSettings {
    let zero = ConstantDensityFunction(value: 0.0)
    let router = NoiseRouter(
        preliminarySurfaceLevel: zero,
        finalDensity: finalDensity,
        barrier: zero,
        fluidLevelFloodedness: zero,
        fluidLevelSpread: zero,
        lava: zero,
        veinToggle: zero,
        veinRidged: zero,
        veinGap: zero,
        temperature: zero,
        humidity: zero,
        continents: zero,
        erosion: zero,
        depth: zero,
        weirdness: zero
    )
    return NoiseSettings(
        legacyRandomSource: false,
        minY: minY,
        height: height,
        sizeHorizontal: 1,
        sizeVertical: 2,
        noiseRouter: router,
        surfaceRule: SurfaceRuleBlock(resultState: BlockStateDefinition(name: "minecraft:stone"))
    )
}

private func loadNoiseSettingsPack() throws -> DataPack {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/NoiseSettings/noise_settings")
    return try DataPack(
        fromRootPath: packURL,
        loadingOptions: [.noDensityFunctions, .noNoises, .noBiomes, .noDimensions]
    )
}

private func decodeVanillaTerrainBitset() throws -> [UInt8] {
    guard let bytes = Data(base64Encoded: vanillaTerrainEncodedBitset, options: [.ignoreUnknownCharacters]) else {
        throw TerrainTestErrors.invalidEmbeddedTerrainBitset
    }
    let expectedByteCount = vanillaTerrainSampleCount / 8
    guard bytes.count == expectedByteCount else {
        throw TerrainTestErrors.invalidEmbeddedTerrainBitset
    }
    return [UInt8](bytes)
}

@inline(__always)
private func vanillaTerrainIsSolid(atWorld pos: PosInt3D, bitset: [UInt8]) -> Bool {
    precondition(pos.x >= 0 && pos.x < Int32(ProtoChunk.sideLength), "x position out of range")
    precondition(pos.y >= vanillaTerrainMinY && pos.y < vanillaTerrainMinY + vanillaTerrainHeight, "y position out of range")
    precondition(pos.z >= 0 && pos.z < Int32(ProtoChunk.sideLength), "z position out of range")

    let localY = Int(pos.y - vanillaTerrainMinY)
    let index = ((localY * ProtoChunk.sideLength + Int(pos.z)) * ProtoChunk.sideLength) + Int(pos.x)
    let byteIndex = index >> 3
    let bitMask = UInt8(1) << UInt8(index & 7)
    return (bitset[byteIndex] & bitMask) != 0
}

@Test func testProtoChunkSectionsStoreTerrainAsBitmap() async throws {
    let chunk = ProtoChunk()
    try chunk.configure(minY: -64, height: 32)
    #expect(chunk.sectionCount == 2)

    guard let section0 = chunk.section(at: 0), let section1 = chunk.section(at: 1) else {
        #expect(Bool(false), "Section lookup failed")
        return
    }
    #expect(section0.bitmap.count == ProtoChunkSection.bitmapWordCount)
    #expect(section1.bitmap.count == ProtoChunkSection.bitmapWordCount)
    #expect(section0.bitmap.allSatisfy { $0 == 0 })
    #expect(section1.bitmap.allSatisfy { $0 == 0 })

    chunk.setTerrain(true, atLocal: PosInt3D(x: 1, y: 0, z: 2))
    chunk.setTerrain(true, atLocal: PosInt3D(x: 15, y: 15, z: 15))
    chunk.setTerrain(true, atLocal: PosInt3D(x: 0, y: 16, z: 0))

    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 1, y: 0, z: 2)))
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 15, y: 15, z: 15)))
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 16, z: 0)))
    #expect(!chunk.isTerrain(atLocal: PosInt3D(x: 2, y: 0, z: 2)))

    let section0BitIndex = (0 << 8) | (2 << 4) | 1
    let section0WordIndex = section0BitIndex >> 6
    let section0BitMask = UInt64(1) << UInt64(section0BitIndex & 63)
    #expect((section0.bitmap[section0WordIndex] & section0BitMask) != 0)
    #expect((section0.bitmap[63] & (UInt64(1) << 63)) != 0)
    #expect((section1.bitmap[0] & 1) != 0)
}

@Test func testGenerateIntoUsesNoiseSettingsHeightAndFinalDensity() async throws {
    let pack = try loadNoiseSettingsPack()
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 1,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "test:example"),
        buildSearchTrees: false
    )
    let chunk = ProtoChunk()
    try worldGenerator.generateInto(chunk, at: PosInt2D(x: 0, z: 0))

    #expect(chunk.minY == -64)
    #expect(chunk.height == 384)
    #expect(chunk.sectionCount == 24)
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 0, z: 0)))
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 15, y: 383, z: 15)))

    for sectionIndex in 0..<chunk.sectionCount {
        guard let section = chunk.section(at: sectionIndex) else {
            #expect(Bool(false), "Section lookup failed")
            return
        }
        #expect(section.bitmap.allSatisfy { $0 == UInt64.max })
    }
}

@Test func testGenerateIntoFinalDensityThreshold() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:threshold")
    pack.noiseSettingsRegistry.register(
        makeNoiseSettings(
            minY: -8,
            height: 16,
            finalDensity: YClampedGradient(fromY: -8, toY: 7, fromValue: -1.0, toValue: 1.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 2,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )
    let chunk = ProtoChunk()
    try worldGenerator.generateInto(chunk, at: PosInt2D(x: 0, z: 0))

    #expect(!chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 0, z: 0)))
    #expect(!chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 7, z: 0)))
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 8, z: 0)))
    #expect(chunk.isTerrain(atLocal: PosInt3D(x: 0, y: 15, z: 0)))
}

@Test func testGenerateIntoRejectsInvalidChunkHeights() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:invalid_height")
    pack.noiseSettingsRegistry.register(
        makeNoiseSettings(
            minY: 0,
            height: 30,
            finalDensity: ConstantDensityFunction(value: 1.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 3,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    do {
        try worldGenerator.generateInto(ProtoChunk(), at: PosInt2D(x: 0, z: 0))
        #expect(Bool(false), "Expected invalidProtoChunkHeight to be thrown")
    } catch WorldGenerationErrors.invalidProtoChunkHeight(let actualHeight) {
        #expect(actualHeight == 30)
    }
}

@Test func testVanillaTerrainGeneration() async throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw TerrainTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
    let terrainBitset = try decodeVanillaTerrainBitset()

    let sampled = try worldGenerator.sampleFinalDensity(at: PosInt3D(x: 0, y: 0, z: 0))
    #expect(checkDoubleTerrain(sampled, 204_443))

    let chunk = ProtoChunk()
    try worldGenerator.generateInto(chunk, at: PosInt2D(x: 0, z: 0))
    var mismatchCount = 0
    var mismatchNearThreshold = 0
    var mismatchLargeMagnitude = 0
    var expectedTerrainGotAir = 0
    var expectedAirGotTerrain = 0

    #expect(chunk.minY == vanillaTerrainMinY)
    #expect(chunk.height == vanillaTerrainHeight)

    for localY in Int32(0)..<chunk.height {
        let worldY = chunk.minY + localY
        for localZ in 0..<ProtoChunk.sideLength {
            for localX in 0..<ProtoChunk.sideLength {
                let worldPos = PosInt3D(x: Int32(localX), y: worldY, z: Int32(localZ))
                let localPos = PosInt3D(x: Int32(localX), y: localY, z: Int32(localZ))
                let expectedTerrain = vanillaTerrainIsSolid(atWorld: worldPos, bitset: terrainBitset)
                let actualTerrain = chunk.isTerrain(atLocal: localPos)
                if actualTerrain != expectedTerrain {
                    mismatchCount += 1
                    if expectedTerrain {
                        expectedTerrainGotAir += 1
                    } else {
                        expectedAirGotTerrain += 1
                    }
                    let density = try worldGenerator.sampleFinalDensity(at: worldPos)
                    let magnitude = abs(density)
                    if magnitude < 0.05 {
                        mismatchNearThreshold += 1
                    }
                    if magnitude > 0.25 {
                        mismatchLargeMagnitude += 1
                    }
                    if mismatchCount <= 10 {
                        print(
                            "Mismatch in terrain sample at (\(worldPos.x), \(worldPos.y), \(worldPos.z)): expected",
                            expectedTerrain ? 1 : 0,
                            "got",
                            actualTerrain ? 1 : 0,
                            "density",
                            density
                        )
                    }
                }
            }
        }
    }
    if mismatchCount > 0 {
        print(
            "Mismatch summary: total",
            mismatchCount,
            "expected1->0",
            expectedTerrainGotAir,
            "expected0->1",
            expectedAirGotTerrain,
                    "near-threshold(|d|<0.05)",
                    mismatchNearThreshold,
                    "large(|d|>0.25)",
                    mismatchLargeMagnitude
        )
    }
    #expect(mismatchCount == 0)
}
