import Foundation
import Testing
@testable import DPReader

private enum TerrainTestErrors: Error {
    case noVanillaDataFound
    case invalidEmbeddedTerrainBitset
    case unexpectedDensityFunctionType
    case missingVanillaNoiseSettings(String)
    case invalidProfileLogPath(String)
}

private let vanillaTerrainMinY: Int32 = -64
private let vanillaTerrainHeight: Int32 = 384
private let vanillaTerrainSampleCount = ProtoChunk.sideLength * ProtoChunk.sideLength * Int(vanillaTerrainHeight)
private let vanillaLODOrigin = PosInt3D(x: 16, y: 96, z: 240)
private let vanillaLODRadius: Int32 = 12
private let vanillaLODStartingRadius: Int32 = 4
private let vanillaLODRadiusStep: Int32 = 4
private let vanillaLODMaxCellSizePower = 2

@inline(__always)
private func performConcurrentTestIterations(iterations: Int, _ body: @Sendable (Int) -> Void) {
    #if os(WASI) || arch(wasm32)
    for index in 0..<iterations {
        body(index)
    }
    #else
    DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
    #endif
}

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
    return makeSurfaceNoiseSettings(
        minY: minY,
        height: height,
        finalDensity: finalDensity,
        preliminarySurfaceLevel: ConstantDensityFunction(value: 0.0)
    )
}

private func makeSurfaceNoiseSettings(
    minY: Int,
    height: Int,
    finalDensity: DensityFunction,
    preliminarySurfaceLevel: DensityFunction? = nil,
    initialDensityWithoutJaggedness: DensityFunction? = nil
) -> NoiseSettings {
    let zero = ConstantDensityFunction(value: 0.0)
    let router = NoiseRouter(
        preliminarySurfaceLevel: preliminarySurfaceLevel,
        initialDensityWithoutJaggedness: initialDensityWithoutJaggedness,
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

private func surfaceCell(atX x: Int32, z: Int32, in result: TerrainSurfaceLODResult) -> TerrainSurfaceLODCell? {
    return result.cells.first { $0.x == x && $0.z == z }
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

private struct TerrainChunkKey: Hashable {
    let x: Int32
    let z: Int32
}

@inline(__always)
private func chebyshevDistance(from origin: PosInt3D, toX x: Int32, z: Int32) -> Int32 {
    return Int32(max(abs(Int64(x) - Int64(origin.x)), abs(Int64(z) - Int64(origin.z))))
}

@inline(__always)
private func expectedLODCellSize(for column: TerrainLODColumn, in result: TerrainLODResult) -> Int32 {
    let distance = chebyshevDistance(from: PosInt3D(x: result.originX, y: result.originY, z: result.originZ), toX: column.x, z: column.z)
    let power = min(Int(max(0, distance - result.startingRadius) / result.radiusStep), result.maxCellSizePower)
    return result.baseCellSize << power
}

@inline(__always)
private func lodSampleY(for sampleIndex: Int, in column: TerrainLODColumn, result: TerrainLODResult) -> Int32 {
    let bandStartY = result.minY + Int32(sampleIndex) * column.cellSize
    let bandHeight = min(column.cellSize, result.maxYExclusive - bandStartY)
    return bandStartY + bandHeight / 2
}

@inline(__always)
private func lodSampleX(for column: TerrainLODColumn, result: TerrainLODResult) -> Int32 {
    let bandWidth = min(column.cellSize, result.maxXExclusive - column.x)
    return column.x + bandWidth / 2
}

@inline(__always)
private func lodSampleZ(for column: TerrainLODColumn, result: TerrainLODResult) -> Int32 {
    let bandDepth = min(column.cellSize, result.maxZExclusive - column.z)
    return column.z + bandDepth / 2
}

private func generatedChunk(
    containing worldPos: PosInt3D,
    using worldGenerator: WorldGenerator,
    cache: inout [TerrainChunkKey: ProtoChunk]
) throws -> (chunk: ProtoChunk, key: TerrainChunkKey) {
    let chunkPos = PosInt2D(
        x: worldPos.x >> 4,
        z: worldPos.z >> 4
    )
    let key = TerrainChunkKey(x: chunkPos.x, z: chunkPos.z)
    let chunk: ProtoChunk
    if let cached = cache[key] {
        chunk = cached
    } else {
        let generated = ProtoChunk()
        try worldGenerator.generateInto(generated, at: chunkPos)
        cache[key] = generated
        chunk = generated
    }

    return (chunk, key)
}

private func expectedLODSample(
    at worldPos: PosInt3D,
    using worldGenerator: WorldGenerator,
    cache: inout [TerrainChunkKey: ProtoChunk]
) throws -> (isSolid: Bool, biome: RegistryKey<Biome>?) {
    let (chunk, key) = try generatedChunk(containing: worldPos, using: worldGenerator, cache: &cache)
    let localPos = PosInt3D(
        x: worldPos.x - key.x * Int32(ProtoChunk.sideLength),
        y: worldPos.y - chunk.minY,
        z: worldPos.z - key.z * Int32(ProtoChunk.sideLength)
    )
    return (try worldGenerator.sampleFinalDensity(at: worldPos) > 0.0, chunk.biome(atLocal: localPos))
}

private func assertLODMatchesGeneratedTerrain(_ sampled: TerrainLODResult, using worldGenerator: WorldGenerator) throws {
    var chunkCache: [TerrainChunkKey: ProtoChunk] = [:]

    for (chunkListIndex, chunk) in sampled.chunks.enumerated() {
        #expect(sampled.chunkIndex[chunk.key] == chunkListIndex)

        for column in chunk.columns {
            #expect(column.x >= sampled.minX && column.x < sampled.maxXExclusive)
            #expect(column.z >= sampled.minZ && column.z < sampled.maxZExclusive)
            #expect(chebyshevDistance(from: PosInt3D(x: sampled.originX, y: sampled.originY, z: sampled.originZ), toX: column.x, z: column.z) >= sampled.startingRadius)
            #expect(column.cellSize == expectedLODCellSize(for: column, in: sampled))
            #expect(chunk.key == TerrainLODChunkKey(x: lodSampleX(for: column, result: sampled) >> 4, z: lodSampleZ(for: column, result: sampled) >> 4))

            let expectedSampleCount = Int((sampled.maxYExclusive - sampled.minY + column.cellSize - 1) / column.cellSize)
            #expect(column.samples.count == expectedSampleCount)
            #expect((column.samplePayloads?.count ?? 0) == (column.samplePayloads == nil ? 0 : expectedSampleCount))

            for sampleIndex in column.samples.indices {
                let worldY = lodSampleY(for: sampleIndex, in: column, result: sampled)
                let worldX = lodSampleX(for: column, result: sampled)
                let worldZ = lodSampleZ(for: column, result: sampled)
                let expected = try expectedLODSample(
                    at: PosInt3D(x: worldX, y: worldY, z: worldZ),
                    using: worldGenerator,
                    cache: &chunkCache
                )
                #expect(column.samples[sampleIndex] == expected.isSolid)

                if let payload = column.samplePayloads?[sampleIndex] {
                    if sampled.payloads.contains(.biome) {
                        #expect(payload.biome == expected.biome)
                    } else {
                        #expect(payload.biome == nil)
                    }
                    if sampled.payloads.contains(.material) {
                        #expect(payload.materialID == (expected.isSolid ? "minecraft:stone" : "minecraft:air"))
                    } else {
                        #expect(payload.materialID == nil)
                    }
                }
            }
        }
    }
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

@Test func testSampleLODUsesAdaptiveCellSizesAndPointSamples() async throws {
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

    let sampled = try worldGenerator.sampleLOD(
        from: PosInt3D(x: 5, y: 1, z: -3),
        radius: 9,
        startingRadius: 4,
        radiusStep: 2,
        maxCellSizePower: 2,
        threadCount: 2,
        payloads: [.material]
    )

    #expect(sampled.baseCellSize == 2)
    #expect(sampled.startingRadius == 4)
    #expect(sampled.radiusStep == 2)
    #expect(sampled.maxCellSizePower == 2)
    #expect(sampled.payloads == [.material])
    #expect(sampled.minX == -4)
    #expect(sampled.maxXExclusive == 15)
    #expect(sampled.minY == -8)
    #expect(sampled.maxYExclusive == 8)
    #expect(sampled.minZ == -12)
    #expect(sampled.maxZExclusive == 7)
    #expect(!sampled.chunks.isEmpty)
    #expect(!sampled.columns.isEmpty)

    for chunk in sampled.chunks {
        #expect(sampled.chunkIndex[chunk.key] != nil)
        #expect(!chunk.columns.isEmpty)
        for column in chunk.columns {
            #expect(column.cellSize == expectedLODCellSize(for: column, in: sampled))
            #expect(column.samples.allSatisfy { $0 })
            #expect(column.samplePayloads?.allSatisfy { $0.biome == nil && $0.materialID == "minecraft:stone" } == true)
        }
    }
}

@Test func testSampleSurfaceLODUsesExactInnerSamplesAndRoundedPreliminarySurfaceLevels() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:surface_lod_preliminary")
    pack.noiseSettingsRegistry.register(
        makeSurfaceNoiseSettings(
            minY: 0,
            height: 16,
            finalDensity: YClampedGradient(fromY: 0, toY: 15, fromValue: 1.0, toValue: -1.0),
            preliminarySurfaceLevel: ConstantDensityFunction(value: 10.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 5,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    let sampled = try worldGenerator.sampleSurfaceLOD(
        from: PosInt3D(x: 0, y: 0, z: 0),
        radius: 3,
        startingRadius: 2,
        radiusStep: 4,
        maxCellSizePower: 0,
        threadCount: 2
    )

    #expect(sampled.baseCellSize == 2)
    #expect(sampled.minX == -3)
    #expect(sampled.maxXExclusive == 4)
    #expect(sampled.minY == 0)
    #expect(sampled.maxYExclusive == 16)
    #expect(sampled.cells.contains { $0.cellSize == 1 })
    #expect(sampled.cells.contains { $0.cellSize == 2 })

    let innerCell = try #require(surfaceCell(atX: 0, z: 0, in: sampled))
    #expect(innerCell.cellSize == 1)
    #expect(innerCell.surfaceY == 7)
    #expect(innerCell.surfaceBiome == nil)

    let coarseCell = try #require(surfaceCell(atX: 2, z: 0, in: sampled))
    #expect(coarseCell.cellSize == 2)
    #expect(coarseCell.surfaceY == 10)
    #expect(coarseCell.surfaceBiome == nil)
}

@Test func testSampleSurfaceLODFallsBackToInitialDensityWithoutJaggedness() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:surface_lod_legacy")
    let descendingSurfaceDensity = YClampedGradient(fromY: 0, toY: 15, fromValue: 1.0, toValue: -1.0)
    pack.noiseSettingsRegistry.register(
        makeSurfaceNoiseSettings(
            minY: 0,
            height: 16,
            finalDensity: descendingSurfaceDensity,
            initialDensityWithoutJaggedness: descendingSurfaceDensity
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 6,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    let sampled = try worldGenerator.sampleSurfaceLOD(
        from: PosInt3D(x: 0, y: 0, z: 0),
        radius: 2,
        startingRadius: 1,
        radiusStep: 4,
        maxCellSizePower: 0,
        threadCount: 1
    )

    let innerCell = try #require(surfaceCell(atX: 0, z: 0, in: sampled))
    #expect(innerCell.cellSize == 1)
    #expect(innerCell.surfaceY == 7)

    let coarseCell = try #require(surfaceCell(atX: 2, z: 0, in: sampled))
    #expect(coarseCell.cellSize == 2)
    #expect(coarseCell.surfaceY == 8)
    #expect(coarseCell.surfaceBiome == nil)
}

@Test func testSampleLODReportsProgress() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:lod_progress")
    pack.noiseSettingsRegistry.register(
        makeNoiseSettings(
            minY: -8,
            height: 16,
            finalDensity: ConstantDensityFunction(value: 1.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 7,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )
    let progressEvents = LockedArray<TerrainLODProgress>()

    let sampled = try worldGenerator.sampleLOD(
        from: PosInt3D(x: 5, y: 1, z: -3),
        radius: 9,
        startingRadius: 4,
        radiusStep: 2,
        maxCellSizePower: 2,
        threadCount: 1,
        payloads: [.material],
        progressHandler: { progressEvents.append($0) }
    )

    let events = progressEvents.values
    let first = try #require(events.first)
    let last = try #require(events.last)
    #expect(first.completedChunkCount == 0)
    #expect(first.completedSampleCount == 0)
    #expect(first.totalChunkCount == sampled.chunks.count)
    #expect(first.totalSampleCount == sampled.columns.count)
    #expect(last.completedChunkCount == sampled.chunks.count)
    #expect(last.totalChunkCount == sampled.chunks.count)
    #expect(last.completedSampleCount == sampled.columns.count)
    #expect(last.totalSampleCount == sampled.columns.count)
    #expect(last.isFinished)
    #expect(last.fractionCompleted == 1.0)

    for index in 1..<events.count {
        #expect(events[index].completedChunkCount >= events[index - 1].completedChunkCount)
        #expect(events[index].completedSampleCount >= events[index - 1].completedSampleCount)
    }
}

@Test func testStreamLODMatchesSampleLODChunks() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:lod_streaming")
    pack.noiseSettingsRegistry.register(
        makeNoiseSettings(
            minY: -8,
            height: 16,
            finalDensity: ConstantDensityFunction(value: 1.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 9,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    let streamedChunks = LockedArray<TerrainLODChunk>()
    let streamedRanges = LockedArray<(Int32, Int32)>()
    try worldGenerator.streamLOD(
        from: PosInt3D(x: 5, y: 1, z: -3),
        radius: 9,
        startingRadius: 4,
        radiusStep: 2,
        maxCellSizePower: 2,
        threadCount: 2,
        payloads: [.material],
        streamer: { chunk, minY, maxYExclusive in
            streamedChunks.append(chunk)
            streamedRanges.append((minY, maxYExclusive))
        }
    )

    let sampled = try worldGenerator.sampleLOD(
        from: PosInt3D(x: 5, y: 1, z: -3),
        radius: 9,
        startingRadius: 4,
        radiusStep: 2,
        maxCellSizePower: 2,
        threadCount: 2,
        payloads: [.material]
    )

    let sortedStreamedChunks = streamedChunks.values.sorted { left, right in
        if left.key.z != right.key.z {
            return left.key.z < right.key.z
        }
        return left.key.x < right.key.x
    }
    #expect(sortedStreamedChunks == sampled.chunks)
    #expect(streamedRanges.values.allSatisfy { $0.0 == sampled.minY && $0.1 == sampled.maxYExclusive })
}

@Test func testStreamSurfaceLODMatchesSampleSurfaceLODChunks() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:surface_lod_streaming")
    pack.noiseSettingsRegistry.register(
        makeSurfaceNoiseSettings(
            minY: 0,
            height: 16,
            finalDensity: YClampedGradient(fromY: 0, toY: 15, fromValue: 1.0, toValue: -1.0),
            preliminarySurfaceLevel: ConstantDensityFunction(value: 10.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 10,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )

    let streamedChunks = LockedArray<TerrainSurfaceLODChunk>()
    let streamedRanges = LockedArray<(Int32, Int32)>()
    try worldGenerator.streamSurfaceLOD(
        from: PosInt3D(x: 0, y: 0, z: 0),
        radius: 3,
        startingRadius: 2,
        radiusStep: 4,
        maxCellSizePower: 0,
        threadCount: 2,
        streamer: { chunk, minY, maxYExclusive in
            streamedChunks.append(chunk)
            streamedRanges.append((minY, maxYExclusive))
        }
    )

    let sampled = try worldGenerator.sampleSurfaceLOD(
        from: PosInt3D(x: 0, y: 0, z: 0),
        radius: 3,
        startingRadius: 2,
        radiusStep: 4,
        maxCellSizePower: 0,
        threadCount: 2
    )

    let sortedStreamedChunks = streamedChunks.values.sorted { left, right in
        if left.key.z != right.key.z {
            return left.key.z < right.key.z
        }
        return left.key.x < right.key.x
    }
    #expect(sortedStreamedChunks == sampled.chunks)
    #expect(streamedRanges.values.allSatisfy { $0.0 == sampled.minY && $0.1 == sampled.maxYExclusive })
}

@Test func testSampleSurfaceLODReportsProgress() async throws {
    let pack = try loadNoiseSettingsPack()
    let settingsKey = RegistryKey<NoiseSettings>(referencing: "test:surface_lod_progress")
    pack.noiseSettingsRegistry.register(
        makeSurfaceNoiseSettings(
            minY: 0,
            height: 16,
            finalDensity: YClampedGradient(fromY: 0, toY: 15, fromValue: 1.0, toValue: -1.0),
            preliminarySurfaceLevel: ConstantDensityFunction(value: 10.0)
        ),
        forKey: settingsKey
    )
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 8,
        usingDataPacks: [pack],
        usingSettings: settingsKey,
        buildSearchTrees: false
    )
    let progressEvents = LockedArray<TerrainLODProgress>()

    let sampled = try worldGenerator.sampleSurfaceLOD(
        from: PosInt3D(x: 0, y: 0, z: 0),
        radius: 3,
        startingRadius: 2,
        radiusStep: 4,
        maxCellSizePower: 0,
        threadCount: 1,
        progressHandler: { progressEvents.append($0) }
    )

    let events = progressEvents.values
    let first = try #require(events.first)
    let last = try #require(events.last)
    #expect(first.completedChunkCount == 0)
    #expect(first.completedSampleCount == 0)
    #expect(first.totalChunkCount == sampled.chunks.count)
    #expect(first.totalSampleCount == sampled.cells.count)
    #expect(last.completedChunkCount == sampled.chunks.count)
    #expect(last.totalChunkCount == sampled.chunks.count)
    #expect(last.completedSampleCount == sampled.cells.count)
    #expect(last.totalSampleCount == sampled.cells.count)
    #expect(last.isFinished)
    #expect(last.fractionCompleted == 1.0)

    for index in 1..<events.count {
        #expect(events[index].completedChunkCount >= events[index - 1].completedChunkCount)
        #expect(events[index].completedSampleCount >= events[index - 1].completedSampleCount)
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
    performConcurrentTestIterations(iterations: chunkPositions.count) { index in
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

@Test func testSampleLODIsStableAcrossConcurrentCalls() async throws {
    let pack = try loadNoiseSettingsPack()
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 4,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "test:example"),
        buildSearchTrees: false
    )

    let requests: [(PosInt3D, Int32, Int32, Int32, Int, Int, TerrainLODPayloadOptions)] = [
        (PosInt3D(x: 0, y: 64, z: 0), Int32(16), Int32(0), Int32(4), 0, 1, []),
        (PosInt3D(x: 32, y: 64, z: -16), Int32(24), Int32(8), Int32(4), 2, 4, [.material]),
        (PosInt3D(x: -48, y: 80, z: 24), Int32(28), Int32(12), Int32(8), 1, 3, [.material]),
        (PosInt3D(x: 7, y: 1, z: -3), Int32(9), Int32(4), Int32(2), 2, 2, []),
    ]

    let expectedResults = try requests.map { request in
        try worldGenerator.sampleLOD(
            from: request.0,
            radius: request.1,
            startingRadius: request.2,
            radiusStep: request.3,
            maxCellSizePower: request.4,
            threadCount: request.5,
            payloads: request.6
        )
    }

    let sharedGenerator = UnsafeSendableBox(value: worldGenerator)
    let sharedRequests = UnsafeSendableBox(value: requests)
    let results = requests.map { _ in LockedOptional<TerrainLODResult>() }
    let failure = LockedOptional<String>()
    performConcurrentTestIterations(iterations: requests.count) { index in
        do {
            let request = sharedRequests.value[index]
            results[index].value = try sharedGenerator.value.sampleLOD(
                from: request.0,
                radius: request.1,
                startingRadius: request.2,
                radiusStep: request.3,
                maxCellSizePower: request.4,
                threadCount: request.5,
                payloads: request.6
            )
        } catch {
            failure.setIfNil(String(describing: error))
        }
    }

    #expect(failure.value == nil)
    for index in requests.indices {
        #expect(results[index].value == .some(expectedResults[index]))
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

private final class LockedArray<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ value: Value) {
        self.lock.lock()
        self.storage.append(value)
        self.lock.unlock()
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

@Test func testSampleLODMatchesVanillaFinalDensityAndBiomesAtSamplePoints() async throws {
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

    let sampled = try worldGenerator.sampleLOD(
        from: vanillaLODOrigin,
        radius: vanillaLODRadius,
        startingRadius: vanillaLODStartingRadius,
        radiusStep: vanillaLODRadiusStep,
        maxCellSizePower: vanillaLODMaxCellSizePower,
        threadCount: 4,
        payloads: [.biome, .material]
    )

    #expect(sampled.originX == vanillaLODOrigin.x)
    #expect(sampled.originY == vanillaLODOrigin.y)
    #expect(sampled.originZ == vanillaLODOrigin.z)
    #expect(sampled.radius == vanillaLODRadius)
    #expect(sampled.startingRadius == vanillaLODStartingRadius)
    #expect(sampled.radiusStep == vanillaLODRadiusStep)
    #expect(sampled.maxCellSizePower == vanillaLODMaxCellSizePower)
    #expect(sampled.payloads == [.biome, .material])
    #expect(sampled.baseCellSize == 2)
    #expect(sampled.minX == 4)
    #expect(sampled.maxXExclusive == 29)
    #expect(sampled.minY == -64)
    #expect(sampled.maxYExclusive == 320)
    #expect(sampled.minZ == 228)
    #expect(sampled.maxZExclusive == 253)

    try assertLODMatchesGeneratedTerrain(sampled, using: worldGenerator)
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

@Test func testGenerateIntoExactBlockBiomeSliceMatchesCubiomesReference() async throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw TerrainTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let world = try WorldGenerator(
        withWorldSeed: 503_815_372,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
    let chunk = ProtoChunk()
    try world.generateInto(chunk, at: PosInt2D(x: 0, z: 0))

    let cubiomesNumberToKeyMap = [
        23: RegistryKey<Biome>(referencing: "minecraft:sparse_jungle"),
        175: RegistryKey<Biome>(referencing: "minecraft:lush_caves"),
        184: RegistryKey<Biome>(referencing: "minecraft:mangrove_swamp"),
    ]
    let cubiomesSlice = [
        23, 23, 23, 23, 23, 23, 23, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        23, 175, 175, 23, 23, 23, 23, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        175, 175, 175, 175, 23, 23, 175, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        175, 175, 175, 175, 23, 175, 175, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        175, 175, 175, 175, 175, 175, 175, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        175, 175, 23, 175, 175, 175, 175, 175, 175, 175, 175, 175, 175, 184, 184, 184,
        175, 23, 23, 175, 175, 175, 23, 23, 23, 175, 175, 175, 175, 184, 184, 184,
        175, 23, 23, 175, 175, 175, 23, 23, 23, 175, 175, 175, 175, 184, 184, 184,
        175, 23, 175, 175, 175, 175, 23, 23, 23, 23, 175, 175, 175, 184, 184, 184,
        23, 23, 23, 23, 175, 175, 175, 23, 23, 184, 184, 184, 184, 184, 184, 184,
        23, 23, 23, 23, 175, 175, 175, 175, 184, 184, 184, 184, 184, 184, 184, 184,
        23, 23, 23, 23, 175, 175, 175, 175, 175, 184, 184, 184, 175, 175, 175, 175,
        175, 23, 23, 175, 175, 175, 175, 175, 175, 175, 184, 184, 184, 175, 175, 175,
        23, 175, 175, 184, 184, 184, 184, 175, 175, 184, 184, 184, 184, 175, 175, 175,
        23, 23, 175, 184, 184, 184, 184, 175, 175, 184, 184, 184, 184, 184, 175, 175,
        23, 23, 23, 184, 184, 184, 184, 175, 175, 184, 184, 184, 184, 184, 184, 175,
    ]

    for localZ in 0..<ProtoChunk.sideLength {
        for localX in 0..<ProtoChunk.sideLength {
            let expected = cubiomesNumberToKeyMap[cubiomesSlice[localZ * ProtoChunk.sideLength + localX]]!
            let actual = chunk.biome(atLocal: PosInt3D(x: Int32(localX), y: 64, z: Int32(localZ)))
            #expect(actual == .some(expected), "Mismatch at local (\(localX), 64, \(localZ)): expected \(expected.name), got \(actual?.name ?? "nil")")
        }
    }
}

//#if DEBUG && !(os(WASI) || arch(wasm32))
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

@Test func benchmarkVanillaTerrainChunkGenerationDetailedProfile() async throws {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()

    _ = try worldGenerator.benchmarkChunkGenerationDetailedProfile(at: PosInt2D(x: 0, z: 0))
    let benchmark = try worldGenerator.benchmarkChunkGenerationDetailedProfile(at: PosInt2D(x: 0, z: 0))

    func averageCallNanos(_ profile: TimedComponentBenchmark) -> UInt64 {
        guard profile.callCount > 0 else { return 0 }
        return profile.totalNanos / profile.callCount
    }

    func printComponent(_ label: String, _ profile: TimedComponentBenchmark) {
        print(
            label,
            profile.totalNanos, "ns",
            "(\(profile.callCount) calls;",
            "\(averageCallNanos(profile))ns/call)"
        )
    }

    func printBiomeProfile(_ label: String, _ profile: ChunkBiomeGenerationDetailedBenchmark?) {
        guard let profile else {
            print(label, "n/a")
            return
        }
        print(label)
        printComponent("  temperature:", profile.temperature)
        printComponent("  humidity:", profile.humidity)
        printComponent("  continentalness:", profile.continentalness)
        printComponent("  erosion:", profile.erosion)
        printComponent("  weirdness:", profile.weirdness)
        printComponent("  depth:", profile.depth)
        printComponent("  search tree:", profile.searchTree)
    }

    print(
        "benchmarkVanillaTerrainChunkGenerationDetailedProfile:",
        "configure", benchmark.configureNanos, "ns;",
        "sampler init", benchmark.samplerInitNanos, "ns;",
        "shared bake", benchmark.sharedBakeNanos, "ns;"
    )
    print(
        "  terrain only:",
        benchmark.terrainOnlyNanos, "ns"
    )
    printComponent("    terrain density:", benchmark.terrainOnlyProfile.terrainDensity)
    print(
        "  quart biomes only:",
        benchmark.quartBiomesOnlyNanos, "ns"
    )
    printBiomeProfile("    quart biome components:", benchmark.quartBiomesOnlyProfile)
    print(
        "  block biomes only:",
        benchmark.blockBiomesOnlyNanos, "ns"
    )
    printBiomeProfile("    block biome components:", benchmark.blockBiomesOnlyProfile)
    print(
        "  full generateInto body:",
        benchmark.fullGenerateIntoNanos, "ns"
    )
    printBiomeProfile("    full biome components:", benchmark.fullBiomeProfile)
    printComponent("    full terrain density:", benchmark.fullTerrainProfile.terrainDensity)
}

@Test func benchmarkVanillaFullBiomeAndTerrainChunkGeneration() async throws {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()

    let warmupChunk = ProtoChunk()
    try worldGenerator.generateInto(warmupChunk, at: PosInt2D(x: 0, z: 0))
    let warmupChecksum = biomeAndTerrainHash(for: warmupChunk)

    var totalNanos: UInt64 = 0
    var checksum: UInt64 = 0
    for chunkX in 0..<8 {
        for chunkZ in 0..<8 {
            let chunk = ProtoChunk()
            let start = DispatchTime.now().uptimeNanoseconds
            try worldGenerator.generateInto(chunk, at: PosInt2D(x: Int32(chunkX), z: Int32(chunkZ)))
            totalNanos &+= DispatchTime.now().uptimeNanoseconds - start
            checksum ^= biomeAndTerrainHash(for: chunk)
        }
    }

    let chunkCount: UInt64 = 64
    print(
        "benchmarkVanillaFullBiomeAndTerrainChunkGeneration:",
        chunkCount, "chunks in",
        totalNanos, "ns",
        "(\(totalNanos / 1_000_000)ms total;",
        "\(totalNanos / chunkCount)ns/chunk);",
        "warmup checksum", warmupChecksum,
        "checksum", checksum
    )
}

@Test func benchmarkCompiledVanillaTerrainFinalDensityZXY() throws {
    let benchmarkContext = try makeVanillaTerrainCompiledBenchmarkContext()
    let profilingState = environmentFlagEnabled("DPREADER_COMPILED_BUFFER_PROFILE") ? BufferedDensityFunctionProfilingState() : nil
    let compiledBufferedDensity = try compile(
        densityFunction: benchmarkContext.finalDensity,
        bufferContext: benchmarkContext.bufferContext,
        registry: benchmarkContext.densityFunctionRegistry,
        options: BufferedDensityFunctionCompilationOptions(profilingState: profilingState)
    )
    let basePos = PosInt3D(x: 0, y: benchmarkContext.minY, z: 0)

    var interpretedBuffer = [Double](repeating: 0.0, count: benchmarkContext.bufferContext.sampleCount)
    var compiledBufferedBuffer = [Double](repeating: 0.0, count: benchmarkContext.bufferContext.sampleCount)

    _ = benchmarkVanillaTerrainDensityBufferZXY(
        basePos: basePos,
        bufferContext: benchmarkContext.bufferContext,
        output: &interpretedBuffer
    ) { x, y, z in
        benchmarkContext.finalDensity.sample(at: PosInt3D(x: x, y: y, z: z))
    }
    _ = benchmarkCompiledVanillaTerrainDensityBufferZXY(
        basePos: basePos,
        bufferContext: benchmarkContext.bufferContext,
        output: &compiledBufferedBuffer,
        compiledDensity: compiledBufferedDensity
    )

    let interpreted = benchmarkVanillaTerrainDensityBufferZXY(
        basePos: basePos,
        bufferContext: benchmarkContext.bufferContext,
        output: &interpretedBuffer
    ) { x, y, z in
        benchmarkContext.finalDensity.sample(at: PosInt3D(x: x, y: y, z: z))
    }
    let compiledBuffered = benchmarkCompiledVanillaTerrainDensityBufferZXY(
        basePos: basePos,
        bufferContext: benchmarkContext.bufferContext,
        output: &compiledBufferedBuffer,
        compiledDensity: compiledBufferedDensity
    )

    #expect(interpreted.sampleCount == compiledBuffered.sampleCount)

    let interpretedSolidCount = solidTerrainDensitySampleCount(in: interpretedBuffer)
    let compiledBufferedSolidCount = solidTerrainDensitySampleCount(in: compiledBufferedBuffer)
    #expect(interpretedSolidCount == compiledBufferedSolidCount)

    if let mismatch = firstTerrainDensityBufferMismatch(
        reference: interpretedBuffer,
        candidate: compiledBufferedBuffer,
        basePos: basePos,
        bufferContext: benchmarkContext.bufferContext
    ) {
        Issue.record("Buffered compiled mismatch: \(mismatch)")
    }

    let bufferedSpeedup = Double(interpreted.totalNanos) / Double(max(compiledBuffered.totalNanos, 1))
    print(
        "benchmarkCompiledVanillaTerrainFinalDensityZXY:",
        interpreted.sampleCount, "samples across one chunk in ZXY order;",
        "interpreted", interpreted.totalNanos, "ns",
        "(\(interpreted.totalNanos / 1_000_000)ms);",
        "compiled buffered", compiledBuffered.totalNanos, "ns",
        "(\(compiledBuffered.totalNanos / 1_000_000)ms);",
        "buffered speedup", String(format: "%.2f", bufferedSpeedup), "x;",
        "solid count", interpretedSolidCount
    )

    if let report = profilingState?.latestReport() {
        printBufferedDensityFunctionProfilingReport(
            report,
            label: "benchmarkCompiledVanillaTerrainFinalDensityZXY.profile"
        )
        let logURL = try writeBufferedDensityFunctionProfilingLog(
            label: "benchmarkCompiledVanillaTerrainFinalDensityZXY",
            rootDensityFunctionType: String(describing: type(of: benchmarkContext.finalDensity)),
            basePos: basePos,
            bufferContext: benchmarkContext.bufferContext,
            interpretedTotalNanos: interpreted.totalNanos,
            compiledBufferedTotalNanos: compiledBuffered.totalNanos,
            interpretedSolidCount: interpretedSolidCount,
            compiledBufferedSolidCount: compiledBufferedSolidCount,
            bufferedSpeedup: bufferedSpeedup,
            report: report
        )
        print("benchmarkCompiledVanillaTerrainFinalDensityZXY.profile log:", logURL.path)
    }
}

@Test func testCompiledVanillaNoiseRouterFunctionsCellBulkCorrectness() throws {
    let context = try makeVanillaNoiseRouterCellBulkBenchmarkContext(
        cellVolume: DensityFunctionCellVolume(xCount: 1, yCount: 1, zCount: 1)
    )
    for (label, function) in context.functions {
        let result = try evaluateCompiledCellBulk(
            function,
            cellSize: context.cellSize,
            cellVolume: context.cellVolume,
            registry: context.registry,
            basePos: context.basePos
        )
        let expected = sampleDensityFunctionInCellBulkOrder(
            function,
            cellSize: context.cellSize,
            cellVolume: context.cellVolume,
            basePos: context.basePos
        )
        if let mismatch = firstCellBulkMismatch(reference: expected, candidate: result.values) {
            Issue.record("Cell-bulk noise router mismatch for \(label): \(mismatch)")
        }
    }
}

@Test func benchmarkCompiledVanillaNoiseRouterFunctionsCellBulkZXY() throws {
    let settings = try makeVanillaTerrainBenchmarkWorldGenerator().terrainSettingsForTesting()
    let cellSize = DensityFunctionCellSize(sizeHorizontal: settings.sizeHorizontal, sizeVertical: settings.sizeVertical)
    let chunkSide = Int(ProcessInfo.processInfo.environment["DPREADER_CELL_BULK_BENCHMARK_CHUNK_SIDE"] ?? "") ?? 20
    precondition(chunkSide > 0)
    let context = try makeVanillaNoiseRouterCellBulkBenchmarkContext(
        cellVolume: DensityFunctionCellVolume(
            xCount: Int32(ProtoChunk.sideLength * chunkSide) / cellSize.horizontalBlockCount,
            yCount: Int32(settings.height) / cellSize.verticalBlockCount,
            zCount: Int32(ProtoChunk.sideLength * chunkSide) / cellSize.horizontalBlockCount
        )
    )
    let chunkCount = chunkSide * chunkSide
    let functionFilter = ProcessInfo.processInfo.environment["DPREADER_CELL_BULK_BENCHMARK_FUNCTION"]
    let compiledOnly = ProcessInfo.processInfo.environment["DPREADER_CELL_BULK_BENCHMARK_COMPILED_ONLY"] == "1"

    for (label, function) in context.functions where functionFilter.map({ $0 == label }) ?? true {
        let interpreted: (hash: UInt64, count: Int, nanos: UInt64)?
        if compiledOnly {
            interpreted = nil
        } else {
            let interpretedStart = DispatchTime.now().uptimeNanoseconds
            let expected = densityFunctionChecksumInCellBulkOrder(
                function,
                cellSize: context.cellSize,
                cellVolume: context.cellVolume,
                basePos: context.basePos
            )
            interpreted = (expected.hash, expected.count, DispatchTime.now().uptimeNanoseconds - interpretedStart)
        }
        let compiled = try evaluateCompiledCellBulk(
            function,
            cellSize: context.cellSize,
            cellVolume: context.cellVolume,
            registry: context.registry,
            basePos: context.basePos
        )
        if let interpreted {
            let compiledChecksum = densityFunctionChecksum(compiled.values)
            #expect(compiledChecksum == interpreted.hash, "Cell-bulk noise router benchmark checksum mismatch for \(label)")
            print(
                "benchmarkCompiledVanillaNoiseRouterFunctionsCellBulkZXY:", label,
                interpreted.count, "samples; interpreted", interpreted.nanos, "ns; compiled", compiled.nanos, "ns; speedup",
                String(format: "%.2f", Double(interpreted.nanos) / Double(max(compiled.nanos, 1))), "x; caches", compiled.cacheCount,
                "; interpreted", interpreted.nanos / UInt64(chunkCount), "nspc; compiled", compiled.nanos / UInt64(chunkCount), "nspc"
            )
        } else {
            print(
                "benchmarkCompiledVanillaNoiseRouterFunctionsCellBulkZXY:", label,
                compiled.values.count, "samples; compiled", compiled.nanos, "ns; caches", compiled.cacheCount,
                "; compiled", compiled.nanos / UInt64(chunkCount), "nspc"
            )
        }
    }
}

private struct VanillaNoiseRouterCellBulkBenchmarkContext {
    let functions: [(String, any DensityFunction)]
    let registry: Registry<DensityFunction>
    let cellSize: DensityFunctionCellSize
    let cellVolume: DensityFunctionCellVolume
    let basePos: PosInt3D
}

private struct CompiledCellBulkEvaluationResult {
    let values: [Double]
    let nanos: UInt64
    let cacheCount: Int
}

private func makeVanillaNoiseRouterCellBulkBenchmarkContext(
    cellVolume: DensityFunctionCellVolume
) throws -> VanillaNoiseRouterCellBulkBenchmarkContext {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()
    let settings = try worldGenerator.terrainSettingsForTesting()
    let baker = ChunkDensityFunctionBaker(
        chunkPos: PosInt2D(x: 0, z: 0),
        minY: Int32(settings.minY),
        height: Int32(settings.height),
        sizeHorizontal: settings.sizeHorizontal,
        sizeVertical: settings.sizeVertical
    )
    let router = try settings.noiseRouter.bakeAll(withBaker: baker)
    var functions: [(String, any DensityFunction)] = [
        ("barrier", router.barrier),
        ("fluidLevelFloodedness", router.fluidLevelFloodedness),
        ("fluidLevelSpread", router.fluidLevelSpread),
        ("lava", router.lava),
        ("temperature", router.temperature),
        ("humidity", router.humidity),
        ("continents", router.continents),
        ("erosion", router.erosion),
        ("depth", router.depth),
        ("weirdness", router.weirdness),
        ("veinToggle", router.veinToggle),
        ("veinRidged", router.veinRidged),
        ("veinGap", router.veinGap),
        ("finalDensity", router.finalDensity)
    ]
    if let preliminarySurfaceLevel = router.preliminarySurfaceLevel {
        functions.append(("preliminarySurfaceLevel", preliminarySurfaceLevel))
    }
    if let initialDensityWithoutJaggedness = router.initialDensityWithoutJaggedness {
        functions.append(("initialDensityWithoutJaggedness", initialDensityWithoutJaggedness))
    }
    return VanillaNoiseRouterCellBulkBenchmarkContext(
        functions: functions,
        registry: worldGenerator.densityFunctionRegistryForTesting(),
        cellSize: DensityFunctionCellSize(sizeHorizontal: settings.sizeHorizontal, sizeVertical: settings.sizeVertical),
        cellVolume: cellVolume,
        basePos: PosInt3D(x: 0, y: Int32(settings.minY), z: 0)
    )
}

private func evaluateCompiledCellBulk(
    _ function: any DensityFunction,
    cellSize: DensityFunctionCellSize,
    cellVolume: DensityFunctionCellVolume,
    registry: Registry<DensityFunction>,
    basePos: PosInt3D
) throws -> CompiledCellBulkEvaluationResult {
    let program = try compile(
        densityFunction: function,
        cellSize: cellSize,
        cellVolume: cellVolume,
        registry: registry
    )
    var cache = [Double](repeating: 0.0, count: program.cacheValueCount)
    var output = [Double](repeating: 0.0, count: program.outputValueCount)
    let start = DispatchTime.now().uptimeNanoseconds
    cache.withUnsafeMutableBufferPointer { cacheBuffer in
        var evaluationContext = CompiledDensityFunctionBulkEvaluationContext(
            cacheValues: cacheBuffer.baseAddress,
            cacheValueCount: cacheBuffer.count
        )
        withUnsafePointer(to: &evaluationContext) { contextPointer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                program.function(
                    UnsafeRawPointer(contextPointer),
                    basePos.x,
                    basePos.y,
                    basePos.z,
                    outputBuffer.baseAddress
                )
            }
        }
    }
    return CompiledCellBulkEvaluationResult(
        values: output,
        nanos: DispatchTime.now().uptimeNanoseconds - start,
        cacheCount: program.cacheCount
    )
}

private func sampleDensityFunctionInCellBulkOrder(
    _ function: any DensityFunction,
    cellSize: DensityFunctionCellSize,
    cellVolume: DensityFunctionCellVolume,
    basePos: PosInt3D
) -> [Double] {
    var values: [Double] = []
    values.reserveCapacity(cellVolume.cellCount * cellSize.blockCount)
    for cellZ in 0..<Int(cellVolume.zCount) {
        for cellX in 0..<Int(cellVolume.xCount) {
            for cellY in 0..<Int(cellVolume.yCount) {
                for localZ in 0..<Int(cellSize.horizontalBlockCount) {
                    for localX in 0..<Int(cellSize.horizontalBlockCount) {
                        for localY in 0..<Int(cellSize.verticalBlockCount) {
                            values.append(function.sample(at: PosInt3D(
                                x: basePos.x + Int32(cellX) * cellSize.horizontalBlockCount + Int32(localX),
                                y: basePos.y + Int32(cellY) * cellSize.verticalBlockCount + Int32(localY),
                                z: basePos.z + Int32(cellZ) * cellSize.horizontalBlockCount + Int32(localZ)
                            )))
                        }
                    }
                }
            }
        }
    }
    return values
}

private func densityFunctionChecksumInCellBulkOrder(
    _ function: any DensityFunction,
    cellSize: DensityFunctionCellSize,
    cellVolume: DensityFunctionCellVolume,
    basePos: PosInt3D
) -> (hash: UInt64, count: Int) {
    var hash: UInt64 = 1_469_598_103_934_665_603
    var count = 0
    for cellZ in 0..<Int(cellVolume.zCount) {
        for cellX in 0..<Int(cellVolume.xCount) {
            for cellY in 0..<Int(cellVolume.yCount) {
                for localZ in 0..<Int(cellSize.horizontalBlockCount) {
                    for localX in 0..<Int(cellSize.horizontalBlockCount) {
                        for localY in 0..<Int(cellSize.verticalBlockCount) {
                            let value = function.sample(at: PosInt3D(
                                x: basePos.x + Int32(cellX) * cellSize.horizontalBlockCount + Int32(localX),
                                y: basePos.y + Int32(cellY) * cellSize.verticalBlockCount + Int32(localY),
                                z: basePos.z + Int32(cellZ) * cellSize.horizontalBlockCount + Int32(localZ)
                            ))
                            hash ^= UInt64(bitPattern: Int64((value * 1_000_000).rounded(.toNearestOrEven)))
                            hash &*= 1_099_511_628_211
                            count += 1
                        }
                    }
                }
            }
        }
    }
    return (hash, count)
}

private func densityFunctionChecksum(_ values: [Double]) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for value in values {
        hash ^= UInt64(bitPattern: Int64((value * 1_000_000).rounded(.toNearestOrEven)))
        hash &*= 1_099_511_628_211
    }
    return hash
}

private func firstCellBulkMismatch(reference: [Double], candidate: [Double]) -> String? {
    guard reference.count == candidate.count else {
        return "value count differs: expected \(reference.count), got \(candidate.count)"
    }
    for index in reference.indices {
        let expected = Int((reference[index] * 1_000_000).rounded(.toNearestOrEven))
        if !checkDoubleTerrain(candidate[index], expected) {
            return "index \(index): expected \(reference[index]), got \(candidate[index])"
        }
    }
    return nil
}

private func biomeAndTerrainHash(for chunk: ProtoChunk) -> UInt64 {
    let offsetBasis: UInt64 = 1_469_598_103_934_665_603
    let prime: UInt64 = 1_099_511_628_211

    var hash = offsetBasis
    for localY in 0..<Int(chunk.height) {
        for localZ in 0..<ProtoChunk.sideLength {
            for localX in 0..<ProtoChunk.sideLength {
                let pos = PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ))
                hash ^= chunk.isTerrain(atLocal: pos) ? 1 : 0
                hash &*= prime

                if let biome = chunk.biome(atLocal: pos) {
                    for byte in biome.name.utf8 {
                        hash ^= UInt64(byte)
                        hash &*= prime
                    }
                } else {
                    hash ^= 0xff
                    hash &*= prime
                }
            }
        }
    }

    return hash
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

private struct VanillaTerrainDensityBenchmarkContext {
    let minY: Int32
    let maxYExclusive: Int32
    let bufferContext: CompiledDensityFunctionBufferContext
    let densityFunctionRegistry: Registry<DensityFunction>
    let finalDensity: any DensityFunction
}

private struct VanillaTerrainDensityBenchmarkResult {
    let totalNanos: UInt64
    let sampleCount: UInt64
}

private struct ProfiledBenchmarkBufferContext: Codable {
    let xCount: Int32
    let yCount: Int32
    let zCount: Int32
    let xStep: Int32
    let yStep: Int32
    let zStep: Int32

    init(_ context: CompiledDensityFunctionBufferContext) {
        self.xCount = context.xCount
        self.yCount = context.yCount
        self.zCount = context.zCount
        self.xStep = context.xStep
        self.yStep = context.yStep
        self.zStep = context.zStep
    }
}

private struct ProfiledBenchmarkPos: Codable {
    let x: Int32
    let y: Int32
    let z: Int32

    init(_ pos: PosInt3D) {
        self.x = pos.x
        self.y = pos.y
        self.z = pos.z
    }
}

private struct ProfiledBenchmarkLog: Codable {
    let label: String
    let createdAt: String
    let processIdentifier: Int32
    let rootDensityFunctionType: String
    let basePosition: ProfiledBenchmarkPos
    let bufferContext: ProfiledBenchmarkBufferContext
    let interpretedTotalNanos: UInt64
    let compiledBufferedTotalNanos: UInt64
    let bufferedSpeedup: Double
    let interpretedSolidCount: UInt64
    let compiledBufferedSolidCount: UInt64
    let profile: BufferedDensityFunctionProfilingReport
}

private func environmentFlagEnabled(_ name: String) -> Bool {
    guard let rawValue = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !rawValue.isEmpty
    else {
        return false
    }
    switch rawValue.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}

private func environmentValue(_ name: String) -> String? {
    guard let rawValue = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !rawValue.isEmpty
    else {
        return nil
    }
    return rawValue
}

private func bufferedDensityFunctionProfilingLogURL(label: String) throws -> URL {
    if let explicitPath = environmentValue("DPREADER_COMPILED_BUFFER_PROFILE_LOG_PATH") {
        guard explicitPath.first == "/" else {
            throw TerrainTestErrors.invalidProfileLogPath(explicitPath)
        }
        return URL(fileURLWithPath: explicitPath)
    }

    let uniqueComponent = ProcessInfo.processInfo.globallyUniqueString
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(uniqueComponent).json")
}

private func writeBufferedDensityFunctionProfilingLog(
    label: String,
    rootDensityFunctionType: String,
    basePos: PosInt3D,
    bufferContext: CompiledDensityFunctionBufferContext,
    interpretedTotalNanos: UInt64,
    compiledBufferedTotalNanos: UInt64,
    interpretedSolidCount: UInt64,
    compiledBufferedSolidCount: UInt64,
    bufferedSpeedup: Double,
    report: BufferedDensityFunctionProfilingReport
) throws -> URL {
    let log = ProfiledBenchmarkLog(
        label: label,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        processIdentifier: ProcessInfo.processInfo.processIdentifier,
        rootDensityFunctionType: rootDensityFunctionType,
        basePosition: ProfiledBenchmarkPos(basePos),
        bufferContext: ProfiledBenchmarkBufferContext(bufferContext),
        interpretedTotalNanos: interpretedTotalNanos,
        compiledBufferedTotalNanos: compiledBufferedTotalNanos,
        bufferedSpeedup: bufferedSpeedup,
        interpretedSolidCount: interpretedSolidCount,
        compiledBufferedSolidCount: compiledBufferedSolidCount,
        profile: report
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(log)
    let url = try bufferedDensityFunctionProfilingLogURL(label: label)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return url
}

private func formatValueCountAsBytes(_ valueCount: Int) -> String {
    let byteCount = valueCount * MemoryLayout<Double>.stride
    return "\(byteCount)B"
}

private func printBufferedDensityFunctionProfilingReport(
    _ report: BufferedDensityFunctionProfilingReport,
    label: String,
    topNodeCount: Int = 12
) {
    print(
        label,
        "build", report.buildNanos, "ns;",
        "total", report.totalNanos, "ns;",
        "nodes", report.nodeCount, "planned /", report.realizedNodeCount, "realized;",
        "shared node reuses", report.sharedNodeReuseCount, ";",
        "fused transforms", report.fusedTransformCount, ";",
        "node result cache hits", report.nodeResultCacheHitCount, ";",
        "allocated", report.allocatedBufferCount, "buffers /", report.allocatedValueCount, "values /", formatValueCountAsBytes(report.allocatedValueCount) + ";",
        "reused", report.reusedBufferCount, "buffers /", report.reusedValueCount, "values /", formatValueCountAsBytes(report.reusedValueCount) + ";",
        "recycled", report.recycledBufferCount, "buffers /", report.recycledValueCount, "values /", formatValueCountAsBytes(report.recycledValueCount) + ";",
        "peak pooled", report.peakPooledBufferCount, "buffers /", report.peakPooledValueCount, "values /", formatValueCountAsBytes(report.peakPooledValueCount) + ";",
        "peak live", report.peakRetainedBufferCount, "buffers /", report.peakRetainedValueCount, "values /", formatValueCountAsBytes(report.peakRetainedValueCount) + ";",
        "events", report.events.count
    )

    let hottestNodes = report.nodes.sorted { lhs, rhs in
        if lhs.totalNanos != rhs.totalNanos {
            return lhs.totalNanos > rhs.totalNanos
        }
        return lhs.outputValueCount > rhs.outputValueCount
    }
    let widestNodes = report.nodes.sorted { lhs, rhs in
        if lhs.outputValueCount != rhs.outputValueCount {
            return lhs.outputValueCount > rhs.outputValueCount
        }
        return lhs.totalNanos > rhs.totalNanos
    }

    print(label, "top time nodes:")
    for node in hottestNodes.prefix(topNodeCount) {
        print(
            " ", "#\(node.index)", node.kind, node.label,
            "|", node.totalNanos, "ns",
            "|", "\(node.xCount)x\(node.yCount)x\(node.zCount)",
            "|", node.sampleCount, "samples",
            "|", node.outputValueCount, "values",
            "|", formatValueCountAsBytes(node.outputValueCount),
            "|", "uses", node.plannedUseCount,
            "|", "fused", node.fusedTransformCount,
            "|", "cache hits", node.cacheHitCount
        )
    }

    print(label, "top memory nodes:")
    for node in widestNodes.prefix(topNodeCount) {
        print(
            " ", "#\(node.index)", node.kind, node.label,
            "|", node.outputValueCount, "values",
            "|", formatValueCountAsBytes(node.outputValueCount),
            "|", node.totalNanos, "ns",
            "|", node.sampleCount, "samples",
            "|", "\(node.xCount)x\(node.yCount)x\(node.zCount)",
            "|", "uses", node.plannedUseCount,
            "|", "fused", node.fusedTransformCount,
            "|", "cache hits", node.cacheHitCount
        )
    }

    let hottestFunctions = report.functions.sorted { lhs, rhs in
        if lhs.selfNanos != rhs.selfNanos {
            return lhs.selfNanos > rhs.selfNanos
        }
        return lhs.totalNanos > rhs.totalNanos
    }
    let widestFunctions = report.functions.sorted { lhs, rhs in
        if lhs.totalNanos != rhs.totalNanos {
            return lhs.totalNanos > rhs.totalNanos
        }
        return lhs.callCount > rhs.callCount
    }

    print(label, "top self-time functions:")
    for function in hottestFunctions.prefix(topNodeCount) {
        print(
            " ", "#\(function.index)", function.type, function.label,
            "|", "self", function.selfNanos, "ns",
            "|", "total", function.totalNanos, "ns",
            "|", "calls", function.callCount
        )
    }

    print(label, "top total-time functions:")
    for function in widestFunctions.prefix(topNodeCount) {
        print(
            " ", "#\(function.index)", function.type, function.label,
            "|", "total", function.totalNanos, "ns",
            "|", "self", function.selfNanos, "ns",
            "|", "calls", function.callCount
        )
    }
}

private func benchmarkVanillaTerrainDensityBufferZXY(
    basePos: PosInt3D,
    bufferContext: CompiledDensityFunctionBufferContext,
    output: inout [Double],
    sampler: (Int32, Int32, Int32) -> Double
) -> VanillaTerrainDensityBenchmarkResult {
    precondition(output.count == bufferContext.sampleCount, "Unexpected terrain density output buffer size.")

    let start = DispatchTime.now().uptimeNanoseconds
    var index = 0
    var zOffset: Int32 = 0
    while zOffset < bufferContext.zCount {
        let worldZ = basePos.z + zOffset * bufferContext.zStep
        var xOffset: Int32 = 0
        while xOffset < bufferContext.xCount {
            let worldX = basePos.x + xOffset * bufferContext.xStep
            var yOffset: Int32 = 0
            while yOffset < bufferContext.yCount {
                let worldY = basePos.y + yOffset * bufferContext.yStep
                output[index] = sampler(worldX, worldY, worldZ)
                index += 1
                yOffset += 1
            }
            xOffset += 1
        }
        zOffset += 1
    }
    let end = DispatchTime.now().uptimeNanoseconds

    return VanillaTerrainDensityBenchmarkResult(
        totalNanos: end - start,
        sampleCount: UInt64(output.count)
    )
}

private func benchmarkCompiledVanillaTerrainDensityBufferZXY(
    basePos: PosInt3D,
    bufferContext: CompiledDensityFunctionBufferContext,
    output: inout [Double],
    compiledDensity: CompiledDensityFunctionBuffer
) -> VanillaTerrainDensityBenchmarkResult {
    precondition(output.count == bufferContext.sampleCount, "Unexpected terrain density output buffer size.")

    let start = DispatchTime.now().uptimeNanoseconds
    withUnsafePointer(to: bufferContext) { contextPointer in
        output.withUnsafeMutableBufferPointer { bufferPointer in
            compiledDensity(UnsafeRawPointer(contextPointer), basePos.x, basePos.y, basePos.z, bufferPointer.baseAddress)
        }
    }
    let end = DispatchTime.now().uptimeNanoseconds

    return VanillaTerrainDensityBenchmarkResult(
        totalNanos: end - start,
        sampleCount: UInt64(output.count)
    )
}

private func solidTerrainDensitySampleCount(in output: [Double]) -> UInt64 {
    UInt64(output.lazy.filter { $0 > 0.0 }.count)
}

private func firstTerrainDensityBufferMismatch(
    reference: [Double],
    candidate: [Double],
    basePos: PosInt3D,
    bufferContext: CompiledDensityFunctionBufferContext
) -> String? {
    guard reference.count == candidate.count else {
        return "buffer size mismatch: reference \(reference.count), candidate \(candidate.count)"
    }

    var index = 0
    var zOffset: Int32 = 0
    while zOffset < bufferContext.zCount {
        let worldZ = basePos.z + zOffset * bufferContext.zStep
        var xOffset: Int32 = 0
        while xOffset < bufferContext.xCount {
            let worldX = basePos.x + xOffset * bufferContext.xStep
            var yOffset: Int32 = 0
            while yOffset < bufferContext.yCount {
                let worldY = basePos.y + yOffset * bufferContext.yStep
                let roundedReference = Int((reference[index] * 1_000_000).rounded(.toNearestOrEven))
                if !checkDoubleTerrain(candidate[index], roundedReference) {
                    return "first mismatch at (\(worldX), \(worldY), \(worldZ)) [index \(index)]: expected \(reference[index]), got \(candidate[index])"
                }
                index += 1
                yOffset += 1
            }
            xOffset += 1
        }
        zOffset += 1
    }

    return nil
}

private func makeVanillaTerrainCompiledBenchmarkContext() throws -> VanillaTerrainDensityBenchmarkContext {
    let worldGenerator = try makeVanillaTerrainBenchmarkWorldGenerator()
    let config = try worldGenerator.terrainSettingsForTesting()
    let minY = Int32(config.minY)
    return VanillaTerrainDensityBenchmarkContext(
        minY: minY,
        maxYExclusive: minY + Int32(config.height),
        bufferContext: CompiledDensityFunctionBufferContext(
            xCount: Int32(ProtoChunk.sideLength),
            yCount: Int32(config.height),
            zCount: Int32(ProtoChunk.sideLength)
        ),
        densityFunctionRegistry: worldGenerator.densityFunctionRegistryForTesting(),
        finalDensity: try worldGenerator.cachedFinalDensityFunction()
    )
}
//#endif
