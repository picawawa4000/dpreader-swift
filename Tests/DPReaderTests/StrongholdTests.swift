import Foundation
import Testing
@testable import DPReader

private func strongholdTestContext() -> StructureGenerationContext {
    StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y <= 63 {
            return BlockState(type: Block(withID: "minecraft:stone"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

private func strongholdChestMarker(
    in markers: [StrongholdLootChestMarker],
    at pos: PosInt3D
) -> StrongholdLootChestMarker? {
    markers.first { $0.pos == pos }
}

@Test func testReferenceStrongholdGenerationMatchesReferenceFixture() async throws {
    let worldSeed = UInt64(bitPattern: Int64(-5_340_060_218_582_311_607))
    let startChunk = PosInt2D(x: -18, z: 86)
    let result = Stronghold.generate(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: strongholdTestContext()
    )

    let startPiece = try #require(result.graph.pieces.first)
    #expect(startPiece.boundingBox.minX + 2 == -284)
    #expect(startPiece.boundingBox.minZ + 2 == 1380)

    let corridorChest = try #require(
        strongholdChestMarker(in: result.chestLootMarkers, at: PosInt3D(x: -311, y: -24, z: 1361))
    )
    #expect(corridorChest.lootTable == "minecraft:chests/stronghold_corridor")

    let crossingChest = try #require(
        strongholdChestMarker(in: result.chestLootMarkers, at: PosInt3D(x: -313, y: -10, z: 1373))
    )
    #expect(crossingChest.lootTable == "minecraft:chests/stronghold_crossing")

    let libraryChest = try #require(
        strongholdChestMarker(in: result.chestLootMarkers, at: PosInt3D(x: -276, y: -13, z: 1348))
    )
    #expect(libraryChest.lootTable == "minecraft:chests/stronghold_library")

    let portalCenter = PosInt3D(x: -310, y: -13, z: 1348)
    #expect(result.blocks.block(at: portalCenter).type.id == "minecraft:lava")
    #expect(!result.markers.contains { $0.represents == "minecraft:end_portal" })

    let portalFramePositions = [
        PosInt3D(x: -311, y: -11, z: 1346),
        PosInt3D(x: -310, y: -11, z: 1346),
        PosInt3D(x: -309, y: -11, z: 1346),
        PosInt3D(x: -311, y: -11, z: 1350),
        PosInt3D(x: -310, y: -11, z: 1350),
        PosInt3D(x: -309, y: -11, z: 1350),
        PosInt3D(x: -312, y: -11, z: 1347),
        PosInt3D(x: -312, y: -11, z: 1348),
        PosInt3D(x: -312, y: -11, z: 1349),
        PosInt3D(x: -308, y: -11, z: 1347),
        PosInt3D(x: -308, y: -11, z: 1348),
        PosInt3D(x: -308, y: -11, z: 1349)
    ]
    for pos in portalFramePositions {
        let state = result.blocks.block(at: pos)
        #expect(state.type.id == "minecraft:end_portal_frame")
    }
}

@Test func testStrongholdLootOnlyGenerationMatchesFullGeneration() async throws {
    let worldSeed = UInt64(bitPattern: Int64(-5_340_060_218_582_311_607))
    let startChunk = PosInt2D(x: -18, z: 86)
    let context = strongholdTestContext()
    let full = Stronghold.generate(worldSeed: worldSeed, startChunk: startChunk, context: context)
    let loot = Stronghold.generateLoot(worldSeed: worldSeed, startChunk: startChunk, context: context)
    let expected = full.chestLootMarkers.map {
        StructureLootContainer(block: "minecraft:chest", pos: $0.pos, lootTable: $0.lootTable, lootSeed: $0.lootSeed)
    }

    #expect(loot == expected)
}

@Test func testSeed123458StrongholdChestLoot() async throws {
    let containers = Stronghold.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: -6, z: -95),
        context: strongholdTestContext()
    )
    let chest = try #require(containers.first { $0.pos == PosInt3D(x: -90, y: -24, z: -1_488) })

    #expect(chest.lootTable == "minecraft:chests/stronghold_corridor")
    #expect(chest.lootSeed == -6_825_683_577_099_892_493)
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let tableURL = root.appendingPathComponent("vanilla/1.21.11/data/minecraft/loot_table/chests/stronghold_corridor.json")
    let table = try JSONDecoder().decode(LootTable.self, from: Data(contentsOf: tableURL))
    let items = try table.generateLoot(
        withContext: LootContext(random: CheckedRandom(seed: UInt64(bitPattern: chest.lootSeed)))
    )
    #expect(items.map { "\($0.count)x \($0.itemName)" }.sorted() == [
        "1x minecraft:diamond_horse_armor",
        "1x minecraft:iron_leggings"
    ])
}
