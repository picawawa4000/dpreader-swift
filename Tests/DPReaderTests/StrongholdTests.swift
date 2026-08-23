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

    // A minimal cave-air fixture: skipped stronghold boundary cells also skip their
    // RNG draws. Five such cells align this regression with the vanilla chest seed.
    let chestPos = PosInt3D(x: 1_348, y: 49, z: 743)
    let graph = Stronghold.generatePieceGraph(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: 85, z: 46),
        context: strongholdTestContext()
    )
    let library = try #require(graph.pieces.first {
        $0.boundingBox.contains(chestPos)
            && $0.boundingBox.maxX - $0.boundingBox.minX + 1 >= 13
            && $0.boundingBox.maxZ - $0.boundingBox.minZ + 1 >= 13
    })
    func worldPos(localX: Int32, localY: Int32, localZ: Int32) -> PosInt3D {
        let box = library.boundingBox
        switch library.orientation {
        case .north:
            return PosInt3D(x: box.minX + localX, y: box.minY + localY, z: box.maxZ - localZ)
        case .south:
            return PosInt3D(x: box.minX + localX, y: box.minY + localY, z: box.minZ + localZ)
        case .west:
            return PosInt3D(x: box.maxX - localZ, y: box.minY + localY, z: box.minZ + localX)
        case .east:
            return PosInt3D(x: box.minX + localZ, y: box.minY + localY, z: box.minZ + localX)
        }
    }
    let localMaxY = library.boundingBox.maxY - library.boundingBox.minY
    var caveAir: [PosInt3D] = []
    for y in Int32(0)...localMaxY {
        for x in Int32(0)...13 {
            for z in Int32(0)...14 {
                let boundary = x == 0 || x == 13 || y == 0 || y == localMaxY || z == 0 || z == 14
                guard boundary else { continue }
                let pos = worldPos(localX: x, localY: y, localZ: z)
                guard pos.x >> 4 == 84 && pos.z >> 4 == 46 else { continue }
                caveAir.append(pos)
                if caveAir.count == 5 { break }
            }
            if caveAir.count == 5 { break }
        }
        if caveAir.count == 5 { break }
    }
    let secondContext = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        BlockState(type: Block(withID: caveAir.contains(pos) ? "minecraft:air" : "minecraft:stone"))
    }
    let secondStronghold = Stronghold.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: 85, z: 46),
        context: secondContext
    )
    let secondChest = try #require(secondStronghold.first { $0.pos == chestPos })
    #expect(secondChest.lootSeed == 4_406_998_950_581_121_497)
}
