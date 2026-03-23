import Foundation
import Testing
@testable import DPReader

private enum TerrainTestErrors: Error {
    case noVanillaDataFound
    case invalidEmbeddedTerrainBitset
    case unexpectedDensityFunctionType
}

private let vanillaTerrainMinY: Int32 = -64
private let vanillaTerrainHeight: Int32 = 384
private let vanillaTerrainSampleCount = ProtoChunk.sideLength * ProtoChunk.sideLength * Int(vanillaTerrainHeight)
private let vanillaLODOrigin = PosInt3D(x: 16, y: 96, z: 240)
private let vanillaLODRadius: Int32 = 12
private let vanillaLODSurfaceBandCounts = [
    [
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64]
    ],
    [
        [64, 64, 64, 64, 64, 61, 47],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64]
    ],
    [
        [64, 64, 64, 64, 57, 26, 12],
        [64, 64, 64, 64, 64, 63, 56],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64]
    ],
    [
        [26, 21, 18, 10, 0, 0, 0],
        [44, 44, 43, 36, 22, 3, 0],
        [58, 64, 64, 64, 57, 30, 13],
        [64, 64, 64, 64, 64, 59, 48],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64],
        [64, 64, 64, 64, 64, 64, 64]
    ],
    [
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 1, 6, 4, 1, 0, 0],
        [8, 13, 20, 22, 16, 1, 0],
        [29, 26, 33, 39, 38, 22, 12],
        [30, 34, 48, 55, 60, 52, 40],
        [17, 32, 52, 64, 64, 64, 64]
    ],
    [
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 8, 14, 16]
    ],
    [
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0]
    ]
]
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

private func snapshotTerrainBitmap(from chunk: ProtoChunk) -> [[UInt64]] {
    return (0..<chunk.sectionCount).compactMap { chunk.section(at: $0)?.bitmap }
}

private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
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

@Test func testSampleLODUsesGenerationCellSizeAndCountsTerrain() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:lod_constant")
    pack.noiseSettingsRegistry.register(
        makeNoiseSettings(
            minY: -8,
            height: 16,
            finalDensity: ConstantDensityFunction(value: 1.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 5,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    let sampled = try worldGenerator.sampleLOD(from: PosInt3D(x: 5, y: 1, z: -3), radius: 5)

    #expect(sampled.cellWidth == 4)
    #expect(sampled.cellDepth == 4)
    #expect(sampled.verticalResolution == 4)
    #expect(sampled.minX == 0)
    #expect(sampled.maxXExclusive == 12)
    #expect(sampled.minY == -8)
    #expect(sampled.maxYExclusive == 8)
    #expect(sampled.minZ == -8)
    #expect(sampled.maxZExclusive == 4)
    #expect(sampled.sampleCountX == 3)
    #expect(sampled.sampleCountZ == 3)
    #expect(sampled.verticalSampleCount == 4)
    #expect(sampled.columns.count == 9)

    for column in sampled.columns {
        #expect(column.width == 4)
        #expect(column.depth == 4)
        #expect(column.samples.count == 4)

        for sample in column.samples {
            #expect(sample.height == 4)
            #expect(sample.solidBlockCount == 64)
            #expect(sample.containsTerrain)
        }
    }
}

@Test func testGenerateIntoIsStableAcrossConcurrentCalls() async throws {
    let pack = try loadNoiseSettingsPack()
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 4,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "test:example"),
        buildSearchTrees: false
    )

    let chunkPositions = [
        PosInt2D(x: 0, z: 0),
        PosInt2D(x: 1, z: 0),
        PosInt2D(x: -1, z: 0),
        PosInt2D(x: 0, z: 1),
        PosInt2D(x: 0, z: -1),
        PosInt2D(x: 2, z: 3),
        PosInt2D(x: -4, z: 5),
        PosInt2D(x: 7, z: -6)
    ]

    let expectedBitmaps = try chunkPositions.map { chunkPos in
        let chunk = ProtoChunk()
        try worldGenerator.generateInto(chunk, at: chunkPos)
        return snapshotTerrainBitmap(from: chunk)
    }

    let sharedGenerator = UnsafeSendableBox(value: worldGenerator)
    let sharedChunkPositions = UnsafeSendableBox(value: chunkPositions)
    let results = chunkPositions.map { _ in LockedOptional<[[UInt64]]>() }
    let failure = LockedOptional<String>()
    DispatchQueue.concurrentPerform(iterations: chunkPositions.count) { index in
        let chunk = ProtoChunk()
        do {
            try sharedGenerator.value.generateInto(chunk, at: sharedChunkPositions.value[index])
            results[index].value = snapshotTerrainBitmap(from: chunk)
        } catch {
            failure.setIfNil(String(describing: error))
        }
    }

    #expect(failure.value == nil)
    for index in chunkPositions.indices {
        #expect(results[index].value == .some(expectedBitmaps[index]))
    }
}

private final class LockedOptional<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
        set {
            self.lock.lock()
            self.storage = newValue
            self.lock.unlock()
        }
    }

    func setIfNil(_ value: Value) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.storage == nil {
            self.storage = value
        }
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
                }
            }
        }
    }
    #expect(mismatchCount == 0)
}

@Test func testSampleLODMatchesCubiomesVanillaTerrain() async throws {
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

    let sampled = try worldGenerator.sampleLOD(from: vanillaLODOrigin, radius: vanillaLODRadius)

    #expect(sampled.originX == vanillaLODOrigin.x)
    #expect(sampled.originY == vanillaLODOrigin.y)
    #expect(sampled.originZ == vanillaLODOrigin.z)
    #expect(sampled.radius == vanillaLODRadius)
    #expect(sampled.cellWidth == 4)
    #expect(sampled.cellDepth == 4)
    #expect(sampled.verticalResolution == 4)
    #expect(sampled.minX == 4)
    #expect(sampled.maxXExclusive == 32)
    #expect(sampled.minY == -64)
    #expect(sampled.maxYExclusive == 320)
    #expect(sampled.minZ == 228)
    #expect(sampled.maxZExclusive == 256)
    #expect(sampled.sampleCountX == 7)
    #expect(sampled.sampleCountZ == 7)
    #expect(sampled.verticalSampleCount == 96)
    #expect(sampled.columns.count == sampled.sampleCountX * sampled.sampleCountZ)

    let bandStartIndex = Int((84 - sampled.minY) / sampled.verticalResolution)
    #expect(bandStartIndex == 37)

    var columnIndex = 0
    for zIndex in 0..<sampled.sampleCountZ {
        for xIndex in 0..<sampled.sampleCountX {
            let column = sampled.columns[columnIndex]
            #expect(column.x == sampled.minX + Int32(xIndex) * sampled.cellWidth)
            #expect(column.z == sampled.minZ + Int32(zIndex) * sampled.cellDepth)
            #expect(column.width == sampled.cellWidth)
            #expect(column.depth == sampled.cellDepth)
            #expect(column.samples.count == sampled.verticalSampleCount)
            #expect(column.samples.first?.y == sampled.minY)
            #expect(column.samples.last?.y == sampled.maxYExclusive - sampled.verticalResolution)

            for yIndex in 0..<vanillaLODSurfaceBandCounts.count {
                let expectedSolidCount = vanillaLODSurfaceBandCounts[yIndex][zIndex][xIndex]
                let sample = column.samples[bandStartIndex + yIndex]

                #expect(sample.y == 84 + Int32(yIndex) * sampled.verticalResolution)
                #expect(sample.height == sampled.verticalResolution)
                #expect(sample.solidBlockCount == expectedSolidCount)
                #expect(sample.containsTerrain == (expectedSolidCount > 0))
            }

            columnIndex += 1
        }
    }
}

@Test func testChunkNoiseRouterBakeReusesSharedCachesAcrossTerrainAndBiomeRoots() async throws {
    let shared = CacheMarker(type: .flatCache, wrapping: ConstantDensityFunction(value: 1.0))
    let zero = ConstantDensityFunction(value: 0.0)
    let chunkSampler = VanillaChunkTerrainSampler(
        chunkPos: PosInt2D(x: 0, z: 0),
        minY: 0,
        height: 16,
        sizeHorizontal: 1,
        sizeVertical: 2
    )
    let terrainDensity = try chunkSampler.bakeDensityFunction(
        BinaryDensityFunction(firstOperand: shared, secondOperand: zero, type: .ADD)
    )
    let temperature = try chunkSampler.bakeDensityFunction(shared)
    guard let bakedFinalDensity = terrainDensity as? BinaryDensityFunction else {
        throw TerrainTestErrors.unexpectedDensityFunctionType
    }
    guard type(of: bakedFinalDensity.firstOperand) is AnyObject.Type else {
        throw TerrainTestErrors.unexpectedDensityFunctionType
    }
    guard type(of: temperature) is AnyObject.Type else {
        throw TerrainTestErrors.unexpectedDensityFunctionType
    }

    let terrainCache = ObjectIdentifier(bakedFinalDensity.firstOperand as AnyObject)
    let biomeCache = ObjectIdentifier(temperature as AnyObject)
    #expect(terrainCache == biomeCache)
}

@Test func testGenerateIntoAlsoPopulatesChunkBiomes() async throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw TerrainTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let generatedWorld = try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
    let expectedWorld = try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )

    let chunkPos = PosInt2D(x: 2, z: -1)
    let chunk = ProtoChunk()
    try generatedWorld.generateInto(chunk, at: chunkPos)

    let chunkStartX = chunkPos.x * Int32(ProtoChunk.sideLength)
    let chunkStartZ = chunkPos.z * Int32(ProtoChunk.sideLength)
    for localBiomeY in 0..<chunk.biomeHeight {
        let worldY = chunk.minY + Int32(localBiomeY * ProtoChunk.biomeScale)
        for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
            let worldZ = chunkStartZ + Int32(localBiomeZ * ProtoChunk.biomeScale)
            for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                let worldX = chunkStartX + Int32(localBiomeX * ProtoChunk.biomeScale)
                let expectedBiome = try expectedWorld.sampleBiome(
                    at: PosInt3D(x: worldX, y: worldY, z: worldZ),
                    in: RegistryKey(referencing: "minecraft:overworld")
                )
                let actualBiome = chunk.biome(
                    atBiomeLocal: PosInt3D(x: Int32(localBiomeX), y: Int32(localBiomeY), z: Int32(localBiomeZ))
                )
                #expect(actualBiome == expectedBiome)
            }
        }
    }
}

@Test func testVoronoiSubsampleMapsBlocksToExpectedBiomePositions() async throws {
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
    let cases: [(PosInt3D, PosInt3D)] = [
        (PosInt3D(x: 0, y: 0, z: 0), PosInt3D(x: -1, y: -1, z: -1)),
        (PosInt3D(x: 1, y: 0, z: 0), PosInt3D(x: 0, y: 0, z: -1)),
        (PosInt3D(x: 2, y: 0, z: 0), PosInt3D(x: 0, y: 0, z: -1)),
        (PosInt3D(x: 4, y: 0, z: 0), PosInt3D(x: 0, y: 0, z: -1)),
        (PosInt3D(x: 15, y: 63, z: -9), PosInt3D(x: 3, y: 15, z: -3)),
        (PosInt3D(x: -17, y: -64, z: 20), PosInt3D(x: -4, y: -16, z: 4)),
        (PosInt3D(x: 31, y: 255, z: 31), PosInt3D(x: 7, y: 63, z: 7)),
        (PosInt3D(x: 64, y: 70, z: -64), PosInt3D(x: 16, y: 17, z: -16)),
    ]

    for (blockPos, expectedBiomePos) in cases {
        let actualBiomePos = worldGenerator.biomePosition(forBlock: blockPos)
        #expect(actualBiomePos.x == expectedBiomePos.x)
        #expect(actualBiomePos.y == expectedBiomePos.y)
        #expect(actualBiomePos.z == expectedBiomePos.z)
    }
}

@Test func testGenerateIntoAlsoPopulatesExactBlockBiomes() async throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw TerrainTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let generatedWorld = try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
    let expectedWorld = try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )

    let chunkPos = PosInt2D(x: 2, z: -1)
    let chunk = ProtoChunk()
    try generatedWorld.generateInto(chunk, at: chunkPos)

    let chunkStartX = chunkPos.x * Int32(ProtoChunk.sideLength)
    let chunkStartZ = chunkPos.z * Int32(ProtoChunk.sideLength)
    let sampledSectionStarts = [
        0,
        max(0, Int(chunk.height / 2) - ProtoChunk.sectionHeight / 2),
        Int(chunk.height) - ProtoChunk.sectionHeight,
    ]

    for sectionStart in sampledSectionStarts {
        for localY in sectionStart..<(sectionStart + ProtoChunk.sectionHeight) {
            let worldY = chunk.minY + Int32(localY)
            for localZ in 0..<ProtoChunk.sideLength {
                let worldZ = chunkStartZ + Int32(localZ)
                for localX in 0..<ProtoChunk.sideLength {
                    let worldX = chunkStartX + Int32(localX)
                    let expectedBiome = try expectedWorld.sampleBlockBiome(
                        at: PosInt3D(x: worldX, y: worldY, z: worldZ),
                        in: RegistryKey(referencing: "minecraft:overworld")
                    )
                    let actualBiome = chunk.biome(
                        atLocal: PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ))
                    )
                    #expect(actualBiome == expectedBiome)
                }
            }
        }
    }
}

@Test func benchmarkVanillaTerrainChunkGenerationProfiled() async throws {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()

    let warmupChunk = ProtoChunk()
    try worldGenerator.generateInto(warmupChunk, at: PosInt2D(x: 0, z: 0))

    let start = DispatchTime.now().uptimeNanoseconds
    for chunkX in 0..<8 {
        for chunkZ in 0..<8 {
            let chunk = ProtoChunk()
            try worldGenerator.generateInto(chunk, at: PosInt2D(x: Int32(chunkX), z: Int32(chunkZ)))
        }
    }
    let end = DispatchTime.now().uptimeNanoseconds

    print(
        "benchmarkVanillaTerrainChunkGenerationProfiled:",
        "64 chunks in",
        end - start,
        "ns",
        "(\((end - start) / 1_000_000)ms)"
    )

    let profiledChunk = ProtoChunk()
    let profiledStart = DispatchTime.now().uptimeNanoseconds
    try worldGenerator.generateInto(profiledChunk, at: PosInt2D(x: 0, z: 0))
    let profiledEnd = DispatchTime.now().uptimeNanoseconds
    print(
        "benchmarkVanillaTerrainChunkGenerationProfiledSingle:",
        "1 chunk in",
        profiledEnd - profiledStart,
        "ns",
        "(\((profiledEnd - profiledStart) / 1_000_000)ms)"
    )
}

@Test func benchmarkVanillaTerrainChunkGenerationUnprofiled() async throws {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()

    let warmupChunk = ProtoChunk()
    try worldGenerator.generateInto(warmupChunk, at: PosInt2D(x: 0, z: 0))

    let chunk = ProtoChunk()
    let start = DispatchTime.now().uptimeNanoseconds
    try worldGenerator.generateInto(chunk, at: PosInt2D(x: 0, z: 0))
    let end = DispatchTime.now().uptimeNanoseconds

    print(
        "benchmarkVanillaTerrainChunkGenerationUnprofiled:",
        "1 chunk in",
        end - start,
        "ns",
        "(\((end - start) / 1_000_000)ms)"
    )
}

@Test func benchmarkVanillaTerrainChunkGenerationComponents() async throws {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()
    _ = try worldGenerator.benchmarkChunkGenerationComponents(at: PosInt2D(x: 0, z: 0))

    var configureNanos: UInt64 = 0
    var samplerInitNanos: UInt64 = 0
    var sharedBakeNanos: UInt64 = 0
    var terrainOnlyNanos: UInt64 = 0
    var quartBiomesOnlyNanos: UInt64 = 0
    var blockBiomesOnlyNanos: UInt64 = 0
    var fullGenerateIntoNanos: UInt64 = 0

    for chunkX in 0..<8 {
        for chunkZ in 0..<8 {
            let benchmark = try worldGenerator.benchmarkChunkGenerationComponents(
                at: PosInt2D(x: Int32(chunkX), z: Int32(chunkZ))
            )
            configureNanos &+= benchmark.configureNanos
            samplerInitNanos &+= benchmark.samplerInitNanos
            sharedBakeNanos &+= benchmark.sharedBakeNanos
            terrainOnlyNanos &+= benchmark.terrainOnlyNanos
            quartBiomesOnlyNanos &+= benchmark.quartBiomesOnlyNanos
            blockBiomesOnlyNanos &+= benchmark.blockBiomesOnlyNanos
            fullGenerateIntoNanos &+= benchmark.fullGenerateIntoNanos
        }
    }

    let chunkCount: UInt64 = 64
    func average(_ total: UInt64) -> UInt64 {
        return total / chunkCount
    }

    print(
        "benchmarkVanillaTerrainChunkGenerationComponents:",
        "64 chunks;",
        "configure", configureNanos, "ns total", "(\(average(configureNanos))ns/chunk);",
        "sampler init", samplerInitNanos, "ns total", "(\(average(samplerInitNanos))ns/chunk);",
        "shared bake", sharedBakeNanos, "ns total", "(\(average(sharedBakeNanos))ns/chunk);",
        "terrain only", terrainOnlyNanos, "ns total", "(\(average(terrainOnlyNanos))ns/chunk);",
        "quart biomes only", quartBiomesOnlyNanos, "ns total", "(\(average(quartBiomesOnlyNanos))ns/chunk);",
        "exact block biomes only", blockBiomesOnlyNanos, "ns total", "(\(average(blockBiomesOnlyNanos))ns/chunk);",
        "full generateInto body", fullGenerateIntoNanos, "ns total", "(\(average(fullGenerateIntoNanos))ns/chunk)"
    )
}

private func makeVanillaTerrainBenchmarkWorldGenerator() throws -> WorldGenerator {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw TerrainTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    return try WorldGenerator(
        withWorldSeed: 123_456_789,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
}
