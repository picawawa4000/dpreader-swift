import Foundation
import Testing
@testable import DPReader

private enum GenerateIntoNeighborhoodTestErrors: Error {
    case noVanillaDataFound
    case invalidReferenceData
    case unknownCubiomesBiomeId(Int)
}

private struct CubiomesNeighborhoodChunkReference: Decodable {
    let x: Int32
    let z: Int32
    let terrain: String
    let quartBiomes: String
    let blockBiomeSlices: [String]
}

private struct CubiomesNeighborhoodReference: Decodable {
    let seed: String
    let minecraftVersion: String
    let centerChunk: CenterChunk
    let blockBiomeSliceYs: [Int32]
    let chunks: [CubiomesNeighborhoodChunkReference]
    let usedBiomeIds: [Int]

    struct CenterChunk: Decodable {
        let x: Int32
        let z: Int32
    }
}

private let generateIntoNeighborhoodSeed: UInt64 = 8_608_349_533_057_813_284
private let generateIntoNeighborhoodTerrainByteCount = ProtoChunk.sideLength * ProtoChunk.sideLength * 384 / 8
private let generateIntoNeighborhoodQuartBiomeByteCount = ProtoChunk.biomeSideLength * ProtoChunk.biomeSideLength * 96

private func cubiomesNeighborhoodBiome(for id: Int) -> RegistryKey<Biome>? {
    switch id {
    case 21:
        return RegistryKey(referencing: "minecraft:jungle")
    case 174:
        return RegistryKey(referencing: "minecraft:dripstone_caves")
    case 182:
        return RegistryKey(referencing: "minecraft:stony_peaks")
    case 183:
        return RegistryKey(referencing: "minecraft:deep_dark")
    default:
        return nil
    }
}

private func makeVanillaNeighborhoodWorldGenerator() throws -> WorldGenerator {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw GenerateIntoNeighborhoodTestErrors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    return try WorldGenerator(
        withWorldSeed: generateIntoNeighborhoodSeed,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
}

private func loadCubiomesNeighborhoodReference() throws -> CubiomesNeighborhoodReference {
    let referencePath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/Resources/Cubiomes/generate_into_chunk_34_16_seed_8608349533057813284.json")

    let data = try Data(contentsOf: referencePath)
    let reference = try JSONDecoder().decode(CubiomesNeighborhoodReference.self, from: data)
    guard reference.seed == "8608349533057813284",
          reference.minecraftVersion == "1.21.11",
          reference.centerChunk.x == 34,
          reference.centerChunk.z == 16,
          reference.chunks.count == 9 else {
        throw GenerateIntoNeighborhoodTestErrors.invalidReferenceData
    }
    for biomeId in reference.usedBiomeIds where cubiomesNeighborhoodBiome(for: biomeId) == nil {
        throw GenerateIntoNeighborhoodTestErrors.unknownCubiomesBiomeId(biomeId)
    }
    return reference
}

private func decodeReferenceBytes(_ encoded: String, expectedByteCount: Int) throws -> [UInt8] {
    guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
          data.count == expectedByteCount else {
        throw GenerateIntoNeighborhoodTestErrors.invalidReferenceData
    }
    return [UInt8](data)
}

@inline(__always)
private func referenceTerrainIsSolid(localX: Int, localY: Int, localZ: Int, bitset: [UInt8]) -> Bool {
    let index = ((localY * ProtoChunk.sideLength + localZ) * ProtoChunk.sideLength) + localX
    let byteIndex = index >> 3
    let bitMask = UInt8(1) << UInt8(index & 7)
    return (bitset[byteIndex] & bitMask) != 0
}

@inline(__always)
private func referenceBiome(at index: Int, bytes: [UInt8]) throws -> RegistryKey<Biome>? {
    let biomeId = Int(bytes[index])
    if biomeId == 255 {
        return nil
    }
    guard let biome = cubiomesNeighborhoodBiome(for: biomeId) else {
        throw GenerateIntoNeighborhoodTestErrors.unknownCubiomesBiomeId(biomeId)
    }
    return biome
}

@Test func testGenerateIntoMatchesCubiomesTerrainForChunkNeighborhood3416() async throws {
    let world = try makeVanillaNeighborhoodWorldGenerator()
    let reference = try loadCubiomesNeighborhoodReference()

    for chunkReference in reference.chunks {
        let chunk = ProtoChunk()
        try world.generateInto(chunk, at: PosInt2D(x: chunkReference.x, z: chunkReference.z))
        let expectedTerrain = try decodeReferenceBytes(
            chunkReference.terrain,
            expectedByteCount: generateIntoNeighborhoodTerrainByteCount
        )

        var mismatchCount = 0
        var firstMismatch: String?
        for localY in 0..<Int(chunk.height) {
            let worldY = Int(chunk.minY) + localY
            for localZ in 0..<ProtoChunk.sideLength {
                for localX in 0..<ProtoChunk.sideLength {
                    let actual = chunk.isTerrain(atLocal: PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ)))
                    let expected = referenceTerrainIsSolid(localX: localX, localY: localY, localZ: localZ, bitset: expectedTerrain)
                    if actual != expected {
                        mismatchCount += 1
                        if firstMismatch == nil {
                            firstMismatch = "first mismatch at local (\(localX), \(localY), \(localZ)) worldY \(worldY): expected \(expected), got \(actual)"
                        }
                    }
                }
            }
        }

        #expect(
            mismatchCount == 0,
            "Chunk (\(chunkReference.x), \(chunkReference.z)) terrain mismatches: \(mismatchCount). \(firstMismatch ?? "")"
        )
    }
}

@Test func testGenerateIntoMatchesCubiomesQuartBiomesForChunkNeighborhood3416() async throws {
    let world = try makeVanillaNeighborhoodWorldGenerator()
    let reference = try loadCubiomesNeighborhoodReference()

    for chunkReference in reference.chunks {
        let chunk = ProtoChunk()
        try world.generateInto(chunk, at: PosInt2D(x: chunkReference.x, z: chunkReference.z))
        let expectedQuartBiomes = try decodeReferenceBytes(
            chunkReference.quartBiomes,
            expectedByteCount: generateIntoNeighborhoodQuartBiomeByteCount
        )

        var mismatchCount = 0
        var firstMismatch: String?
        for localBiomeY in 0..<chunk.biomeHeight {
            let worldY = chunk.minY + Int32(localBiomeY * ProtoChunk.biomeScale)
            for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
                for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                    let index = (localBiomeY * ProtoChunk.biomeSideLength + localBiomeZ) * ProtoChunk.biomeSideLength + localBiomeX
                    let expected = try referenceBiome(at: index, bytes: expectedQuartBiomes)
                    let actual = chunk.biome(
                        atBiomeLocal: PosInt3D(x: Int32(localBiomeX), y: Int32(localBiomeY), z: Int32(localBiomeZ))
                    )
                    if actual != expected {
                        mismatchCount += 1
                        if firstMismatch == nil {
                            firstMismatch = "first mismatch at quart local (\(localBiomeX), \(localBiomeY), \(localBiomeZ)) worldY \(worldY): expected \(expected?.name ?? "nil"), got \(actual?.name ?? "nil")"
                        }
                    }
                }
            }
        }

        #expect(
            mismatchCount == 0,
            "Chunk (\(chunkReference.x), \(chunkReference.z)) quart biome mismatches: \(mismatchCount). \(firstMismatch ?? "")"
        )
    }
}

@Test func testGenerateIntoMatchesCubiomesBlockBiomeSlicesForChunkNeighborhood3416() async throws {
    let world = try makeVanillaNeighborhoodWorldGenerator()
    let reference = try loadCubiomesNeighborhoodReference()

    for chunkReference in reference.chunks {
        let chunk = ProtoChunk()
        try world.generateInto(chunk, at: PosInt2D(x: chunkReference.x, z: chunkReference.z))

        #expect(chunkReference.blockBiomeSlices.count == reference.blockBiomeSliceYs.count)
        for (sliceIndex, worldY) in reference.blockBiomeSliceYs.enumerated() {
            let localY = Int(worldY - chunk.minY)
            let expectedSlice = try decodeReferenceBytes(
                chunkReference.blockBiomeSlices[sliceIndex],
                expectedByteCount: ProtoChunk.sideLength * ProtoChunk.sideLength
            )

            var mismatchCount = 0
            var firstMismatch: String?
            for localZ in 0..<ProtoChunk.sideLength {
                for localX in 0..<ProtoChunk.sideLength {
                    let index = localZ * ProtoChunk.sideLength + localX
                    let expected = try referenceBiome(at: index, bytes: expectedSlice)
                    let actual = chunk.biome(atLocal: PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ)))
                    if actual != expected {
                        mismatchCount += 1
                        if firstMismatch == nil {
                            firstMismatch = "first mismatch at local (\(localX), \(localY), \(localZ)) worldY \(worldY): expected \(expected?.name ?? "nil"), got \(actual?.name ?? "nil")"
                        }
                    }
                }
            }

            #expect(
                mismatchCount == 0,
                "Chunk (\(chunkReference.x), \(chunkReference.z)) block biome slice y=\(worldY) mismatches: \(mismatchCount). \(firstMismatch ?? "")"
            )
        }
    }
}
