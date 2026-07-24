import Foundation
import Testing
@testable import DPReader

private struct DesertPyramidChunkKey: Hashable {
    let x: Int32
    let z: Int32
}

private struct DesertPyramidNormalizedEnchantment: Equatable {
    let id: String
    let level: Int
}

private struct DesertPyramidNormalizedLootItem: Equatable {
    let name: String
    let count: Int
    let enchantments: [DesertPyramidNormalizedEnchantment]
}

private struct ExpectedDesertPyramidLootMarker {
    let pos: PosInt3D
    let seed: Int64
    let items: [DesertPyramidNormalizedLootItem]
}

private let vanilla12111Root = URL(filePath: "vanilla/1.21.11")

private func desertPyramidTestContext() -> StructureGenerationContext {
    StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y <= 63 {
            return BlockState(type: Block(withID: "minecraft:sand"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

private func uniquePositions(_ positions: [PosInt3D]) -> [PosInt3D] {
    var unique: [PosInt3D] = []
    for pos in positions where !unique.contains(pos) {
        unique.append(pos)
    }
    return unique
}

private func makeCheckedContext(seed: Int64, enchantmentResources: LootEnchantmentResources? = nil) -> LootContext {
    LootContext(random: CheckedRandom(seed: UInt64(bitPattern: seed)), enchantmentResources: enchantmentResources)
}

private func normalizedDesertPyramidLoot(_ items: [ItemStack]) -> [DesertPyramidNormalizedLootItem] {
    let normalizedItems = items.map { item in
        let enchantments = item.enchantmentLevels
            .map { DesertPyramidNormalizedEnchantment(id: $0.key, level: $0.value) }
            .sorted { $0.id < $1.id }
        let normalizedName = item.itemName == "minecraft:enchanted_book" ? "minecraft:book" : item.itemName
        return DesertPyramidNormalizedLootItem(
            name: normalizedName,
            count: item.count,
            enchantments: enchantments
        )
    }
    var combined: [DesertPyramidNormalizedLootItem] = []
    for item in normalizedItems {
        if let index = combined.firstIndex(where: { $0.name == item.name && $0.enchantments == item.enchantments }) {
            let existing = combined[index]
            combined[index] = DesertPyramidNormalizedLootItem(
                name: existing.name,
                count: existing.count + item.count,
                enchantments: existing.enchantments
            )
        } else {
            combined.append(item)
        }
    }
    return combined.sorted { left, right in
        if left.name != right.name { return left.name < right.name }
        if left.enchantments != right.enchantments {
            return String(describing: left.enchantments) < String(describing: right.enchantments)
        }
        return left.count < right.count
    }
}

private func normalizedExpectedDesertPyramidLoot(_ items: [DesertPyramidNormalizedLootItem]) -> [DesertPyramidNormalizedLootItem] {
    var combined: [DesertPyramidNormalizedLootItem] = []
    for item in items {
        let normalized = DesertPyramidNormalizedLootItem(
            name: item.name,
            count: item.count,
            enchantments: item.enchantments.sorted { left, right in
                if left.id != right.id { return left.id < right.id }
                return left.level < right.level
            }
        )
        if let index = combined.firstIndex(where: {
            $0.name == normalized.name && $0.enchantments == normalized.enchantments
        }) {
            let existing = combined[index]
            combined[index] = DesertPyramidNormalizedLootItem(
                name: existing.name,
                count: existing.count + normalized.count,
                enchantments: existing.enchantments
            )
        } else {
            combined.append(normalized)
        }
    }
    return combined.sorted { left, right in
        if left.name != right.name { return left.name < right.name }
        if left.enchantments != right.enchantments {
            return String(describing: left.enchantments) < String(describing: right.enchantments)
        }
        return left.count < right.count
    }
}

private func decodeLootTable(_ identifier: String, from root: URL = vanilla12111Root) throws -> LootTable {
    let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
    let namespace = parts.count == 2 ? parts[0] : "minecraft"
    let path = parts.count == 2 ? parts[1] : parts[0]
    let url = root
        .appendingPathComponent("data")
        .appendingPathComponent(namespace)
        .appendingPathComponent("loot_table")
        .appendingPathComponent(path + ".json")
    return try JSONDecoder().decode(LootTable.self, from: Data(contentsOf: url))
}

private func loadVanilla12111EnchantmentResources() throws -> LootEnchantmentResources {
    let pack = try DataPack(
        fromRootPath: vanilla12111Root,
        loadingOptions: [
            .noDensityFunctions,
            .noNoises,
            .noNoiseSettings,
            .noDimensions,
            .noBiomes,
            .noStructures,
            .noStructureSets
        ]
    )
    return pack.lootEnchantmentResources
}

private func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
    precondition(divisor > 0)
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder >= 0 ? quotient : quotient - 1
}

private func makeVanillaDesertPyramidWorldGenerator(seed: WorldSeed) throws -> WorldGenerator {
    guard FileManager.default.fileExists(atPath: vanilla12111Root.path) else {
        throw DesertPyramidTestErrors.noVanillaDataFound
    }
    let pack = try DataPack(fromRootPath: vanilla12111Root)
    return try WorldGenerator(
        withWorldSeed: seed,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
}

private func makeRealTempleContext(worldSeed: WorldSeed, startChunk: PosInt2D) throws -> StructureGenerationContext {
    let world = try makeVanillaDesertPyramidWorldGenerator(seed: worldSeed)
    let chunkKeys = [
        DesertPyramidChunkKey(x: startChunk.x, z: startChunk.z),
        DesertPyramidChunkKey(x: startChunk.x + 1, z: startChunk.z),
        DesertPyramidChunkKey(x: startChunk.x, z: startChunk.z + 1),
        DesertPyramidChunkKey(x: startChunk.x + 1, z: startChunk.z + 1)
    ]

    var chunks: [DesertPyramidChunkKey: ProtoChunk] = [:]
    for chunkKey in chunkKeys {
        let chunk = ProtoChunk()
        try world.generateInto(chunk, at: PosInt2D(x: chunkKey.x, z: chunkKey.z))
        chunks[chunkKey] = chunk
    }

    return StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        let chunkX = floorDiv(pos.x, by: 16)
        let chunkZ = floorDiv(pos.z, by: 16)
        let key = DesertPyramidChunkKey(x: chunkX, z: chunkZ)
        guard let chunk = chunks[key] else {
            return BlockState(type: Block(withID: "minecraft:air"))
        }
        guard pos.y >= chunk.minY && pos.y < chunk.minY + chunk.height else {
            return BlockState(type: Block(withID: "minecraft:air"))
        }

        let localX = pos.x - chunkX * 16
        let localY = pos.y - chunk.minY
        let localZ = pos.z - chunkZ * 16
        let localPos = PosInt3D(x: localX, y: localY, z: localZ)
        if chunk.isTerrain(atLocal: localPos) {
            return BlockState(type: Block(withID: "minecraft:sand"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

private func sortMarkers(_ markers: [DesertPyramidLootMarker]) -> [DesertPyramidLootMarker] {
    markers.sorted { left, right in
        if left.pos.z != right.pos.z { return left.pos.z < right.pos.z }
        if left.pos.x != right.pos.x { return left.pos.x < right.pos.x }
        return left.pos.y < right.pos.y
    }
}

private func assertExpectedLootMarkers(
    _ actualMarkers: [DesertPyramidLootMarker],
    match expectedMarkers: [ExpectedDesertPyramidLootMarker],
    expectedLootTable: String,
    using lootTable: LootTable,
    enchantmentResources: LootEnchantmentResources
) throws {
    #expect(actualMarkers.count == expectedMarkers.count)
    #expect(actualMarkers.map(\.pos) == expectedMarkers.map(\.pos))
    #expect(actualMarkers.map(\.lootSeed) == expectedMarkers.map(\.seed))
    #expect(Set(actualMarkers.map(\.lootTable)) == [expectedLootTable])

    for (actual, expected) in zip(actualMarkers, expectedMarkers) {
        let generated = try lootTable.generateLoot(
            withContext: makeCheckedContext(seed: actual.lootSeed, enchantmentResources: enchantmentResources)
        )
        #expect(
            normalizedDesertPyramidLoot(generated) == normalizedExpectedDesertPyramidLoot(expected.items),
            "\(expectedLootTable) / \(expected.pos) / seed \(actual.lootSeed)"
        )
    }
}

private enum DesertPyramidTestErrors: Error {
    case noVanillaDataFound
}

private func expectedRealDesertPyramidChests() -> [ExpectedDesertPyramidLootMarker] {
    [
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 8, y: 54, z: -3302),
            seed: 4_491_153_968_970_665_757,
            items: [
                DesertPyramidNormalizedLootItem(name: "minecraft:bone", count: 15, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:sand", count: 2, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:gold_ingot", count: 5, enchantments: []),
                DesertPyramidNormalizedLootItem(
                    name: "minecraft:book",
                    count: 1,
                    enchantments: [DesertPyramidNormalizedEnchantment(id: "minecraft:frost_walker", level: 1)]
                )
            ]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 10, y: 54, z: -3304),
            seed: 130_303_442_934_438_913,
            items: [
                DesertPyramidNormalizedLootItem(name: "minecraft:bone", count: 5, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:golden_apple", count: 1, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:string", count: 8, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:gunpowder", count: 8, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:rotten_flesh", count: 3, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:copper_horse_armor", count: 1, enchantments: [])
            ]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 12, y: 54, z: -3302),
            seed: -4_561_558_765_432_998_277,
            items: [
                DesertPyramidNormalizedLootItem(name: "minecraft:rotten_flesh", count: 16, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:bone", count: 6, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:string", count: 7, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:golden_apple", count: 1, enchantments: [])
            ]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 10, y: 54, z: -3300),
            seed: 8_155_339_335_510_710_962,
            items: [
                DesertPyramidNormalizedLootItem(name: "minecraft:rotten_flesh", count: 14, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:iron_horse_armor", count: 2, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:copper_horse_armor", count: 1, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:gold_ingot", count: 7, enchantments: []),
                DesertPyramidNormalizedLootItem(name: "minecraft:string", count: 8, enchantments: [])
            ]
        )
    ].sorted { left, right in
        if left.pos.z != right.pos.z { return left.pos.z < right.pos.z }
        if left.pos.x != right.pos.x { return left.pos.x < right.pos.x }
        return left.pos.y < right.pos.y
    }
}

private func expectedRealDesertPyramidArchaeology() -> [ExpectedDesertPyramidLootMarker] {
    [
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 16, y: 64, z: -3303),
            seed: 4_672_910_889_024,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:diamond", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 16, y: 63, z: -3303),
            seed: 4_672_910_889_023,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:diamond", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 17, y: 65, z: -3305),
            seed: 4_947_788_787_777,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:emerald", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 18, y: 64, z: -3305),
            seed: 5_222_666_694_720,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:diamond", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 19, y: 63, z: -3305),
            seed: 5_497_544_601_663,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:miner_pottery_sherd", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 14, y: 62, z: -3306),
            seed: 4_123_155_062_846,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:gunpowder", count: 1, enchantments: [])]
        ),
        ExpectedDesertPyramidLootMarker(
            pos: PosInt3D(x: 15, y: 64, z: -3306),
            // `dtemple_0_-3302_loot.txt` records the rolled item here but not the seed.
            // Keep the real generated seed in the fixture so the integration test still
            // verifies the structure's emitted loot marker deterministically.
            seed: 4_398_032_969_792,
            items: [DesertPyramidNormalizedLootItem(name: "minecraft:prize_pottery_sherd", count: 1, enchantments: [])]
        )
    ].sorted { left, right in
        if left.pos.z != right.pos.z { return left.pos.z < right.pos.z }
        if left.pos.x != right.pos.x { return left.pos.x < right.pos.x }
        return left.pos.y < right.pos.y
    }
}

@Test func testDesertPyramidPieceGraphIsDeterministic() async throws {
    let graphA = DesertPyramid.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: desertPyramidTestContext()
    )
    let graphB = DesertPyramid.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: desertPyramidTestContext()
    )

    #expect(graphA != nil)
    #expect(graphB != nil)

    guard let graphA, let graphB else {
        return
    }

    #expect(graphA.orientation == graphB.orientation)
    #expect(graphA.boundingBox == graphB.boundingBox)
    #expect(graphA.pieces.count == 1)
    #expect(graphB.pieces.count == 1)
    #expect(graphA.pieces.map(\.boundingBox) == graphB.pieces.map(\.boundingBox))
    #expect(graphA.pieces.map(\.orientation) == graphB.pieces.map(\.orientation))
    #expect(graphA.boundingBox.maxX - graphA.boundingBox.minX == 20)
    #expect(graphA.boundingBox.maxY - graphA.boundingBox.minY == 14)
    #expect(graphA.boundingBox.maxZ - graphA.boundingBox.minZ == 20)
}

@Test func testDesertPyramidGenerationMarkersAreDeterministic() async throws {
    let resultA = DesertPyramid.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: desertPyramidTestContext()
    )
    let resultB = DesertPyramid.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: desertPyramidTestContext()
    )

    #expect(resultA != nil)
    #expect(resultB != nil)

    guard let resultA, let resultB else {
        return
    }

    #expect(resultA.graph.boundingBox == resultB.graph.boundingBox)
    #expect(resultA.chestLootMarkers.map(\.pos) == resultB.chestLootMarkers.map(\.pos))
    #expect(resultA.archaeologyLootMarkers.map(\.pos) == resultB.archaeologyLootMarkers.map(\.pos))
    #expect(resultA.potentialSuspiciousSandPositions == resultB.potentialSuspiciousSandPositions)
    #expect(resultA.basementMarkerPos == resultB.basementMarkerPos)

    #expect(resultA.chestLootMarkers.count == 4)
    #expect(uniquePositions(resultA.chestLootMarkers.map(\.pos)).count == 4)
    #expect(Set(resultA.chestLootMarkers.map(\.lootTable)) == ["minecraft:chests/desert_pyramid"])

    #expect(resultA.potentialSuspiciousSandPositions.count == 83)
    #expect(uniquePositions(resultA.potentialSuspiciousSandPositions).count == 83)
    #expect(resultA.archaeologyLootMarkers.count >= 7)
    #expect(resultA.archaeologyLootMarkers.count <= 8)
    #expect(Set(resultA.archaeologyLootMarkers.map(\.lootTable)) == ["minecraft:archaeology/desert_pyramid"])

    for marker in resultA.chestLootMarkers {
        #expect(resultA.blocks.block(at: marker.pos).type.id == "minecraft:chest")
    }

    for marker in resultA.archaeologyLootMarkers {
        #expect(resultA.blocks.block(at: marker.pos).type.id == "minecraft:suspicious_sand")
    }

    for pos in resultA.potentialSuspiciousSandPositions {
        let blockID = resultA.blocks.block(at: pos).type.id
        #expect(blockID == "minecraft:sand" || blockID == "minecraft:suspicious_sand")
    }
}

@Test func testDesertPyramidRejectsWhenAnyPlacementCornerIsBelowSeaLevel() async throws {
    let context = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        let lowCorner = (pos.x == 0 && pos.z == 0)
        let surfaceY: Int32 = lowCorner ? 62 : 80
        if pos.y <= surfaceY {
            return BlockState(type: Block(withID: "minecraft:sand"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }

    let graph = DesertPyramid.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = DesertPyramid.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    #expect(graph == nil)
    #expect(result == nil)
}

@Test func testRealDesertPyramidAt0Minus3302MatchesTerrainAndStructureLayout() async throws {
    let worldSeed = UInt64(bitPattern: Int64(-724_478_010_606_617_415))
    let startChunk = PosInt2D(x: 0, z: -207)
    let context = try makeRealTempleContext(worldSeed: worldSeed, startChunk: startChunk)
    let enchantmentResources = try loadVanilla12111EnchantmentResources()
    let chestTable = try decodeLootTable("minecraft:chests/desert_pyramid")
    let archaeologyTable = try decodeLootTable("minecraft:archaeology/desert_pyramid")

    let result = DesertPyramid.generate(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: context
    )
    #expect(result != nil)

    guard let result else {
        return
    }

    #expect(result.graph.orientation == .south)
    #expect(result.graph.boundingBox == BoundingBox(minX: 0, minY: 65, minZ: -3312, maxX: 20, maxY: 79, maxZ: -3292))
    #expect(result.graph.pieces.count == 1)
    #expect(result.graph.boundingBox.minY + 1 == 66)
    #expect(result.basementMarkerPos == PosInt3D(x: 17, y: 65, z: -3305))

    #expect(result.blocks.block(at: PosInt3D(x: 10, y: 65, z: -3302)).type.id == "minecraft:blue_terracotta")
    #expect(result.blocks.block(at: PosInt3D(x: 10, y: 54, z: -3302)).type.id == "minecraft:stone_pressure_plate")
    #expect(result.blocks.block(at: PosInt3D(x: 10, y: 52, z: -3302)).type.id == "minecraft:tnt")

    let expectedChests = expectedRealDesertPyramidChests()
    let actualChests = sortMarkers(result.chestLootMarkers)
    try assertExpectedLootMarkers(
        actualChests,
        match: expectedChests,
        expectedLootTable: "minecraft:chests/desert_pyramid",
        using: chestTable,
        enchantmentResources: enchantmentResources
    )

    let expectedArchaeology = expectedRealDesertPyramidArchaeology()
    let actualArchaeology = sortMarkers(result.archaeologyLootMarkers)
    try assertExpectedLootMarkers(
        actualArchaeology,
        match: expectedArchaeology,
        expectedLootTable: "minecraft:archaeology/desert_pyramid",
        using: archaeologyTable,
        enchantmentResources: enchantmentResources
    )

    for marker in result.archaeologyLootMarkers {
        #expect(result.blocks.block(at: marker.pos).type.id == "minecraft:suspicious_sand")
    }
}

@Test func testReferenceDesertPyramidLootFileSeedsAreUsable() async throws {
    let enchantmentResources = try loadVanilla12111EnchantmentResources()
    let chestTable = try decodeLootTable("minecraft:chests/desert_pyramid")
    let archaeologyTable = try decodeLootTable("minecraft:archaeology/desert_pyramid")

    for expected in expectedRealDesertPyramidChests() {
        let generated = try chestTable.generateLoot(
            withContext: makeCheckedContext(seed: expected.seed, enchantmentResources: enchantmentResources)
        )
        #expect(
            normalizedDesertPyramidLoot(generated) == normalizedExpectedDesertPyramidLoot(expected.items),
            "Chest loot mismatch at \(expected.pos) for seed \(expected.seed)"
        )
    }

    for expected in expectedRealDesertPyramidArchaeology() {
        let generated = try archaeologyTable.generateLoot(
            withContext: makeCheckedContext(seed: expected.seed, enchantmentResources: enchantmentResources)
        )
        #expect(
            normalizedDesertPyramidLoot(generated) == normalizedExpectedDesertPyramidLoot(expected.items),
            "Archaeology loot mismatch at \(expected.pos) for seed \(expected.seed)"
        )
    }
}
