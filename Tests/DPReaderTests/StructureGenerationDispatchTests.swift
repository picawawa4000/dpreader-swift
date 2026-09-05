import Foundation
import Testing
@testable import DPReader

private struct MansionReferenceRoom {
    let floor: Int
    let templateName: String
    let cells: [PosInt2D]
    let lootSeeds: [Int64]
}

private struct MansionNormalizedEnchantment: Equatable {
    let id: String
    let level: Int
}

private struct MansionNormalizedLootItem: Equatable {
    let name: String
    let count: Int
    let enchantments: [MansionNormalizedEnchantment]
}

private struct ExpectedMansionChest {
    let pos: PosInt3D
    let seed: Int64
    let items: [MansionNormalizedLootItem]
}

private enum MansionReferenceError: Error {
    case invalidHeader(String)
    case invalidRoomMapping(String)
}

private let mansionReferenceText = #"""
mansion at (-7232, 288) on 4609964304437707654

first floor

-----------
-AA       -
-AA JJ  K -
-BB JJLL**-
-BB MMNN**-
-   EE  F -
-CCDD     -
-CC--GHHII-
-----------

A = 2x2_a1
B = 2x2_a3
C = 2x2_a2
D = 1x2_b4 (loot seed -7633204163614576248)
E = 1x2_a8
F = 1x1_a2
G = 1x1_a4 (loot seed 8989461160035876180)
H = 1x2_a2
I = 1x2_a5
J = 2x2_a3
K = 1x1_a2
L = 1x2_a9
M = 1x2_b3 (loot seed 1359470290335969847)
N = 1x2_a8

second floor

-----------
-AA       -
-BB KK  L -
-BB NNMM**-
-CC NNMM**-
-   EE  J -
-^^FF     -
-EE--GGHHI-
-----------

A = 1x2_d2
B = 2x2_b4
C = 1x2_d4
E = 1x2_se1 (loot seeds 1946659658194553513, 5432081203293451251)
F = 1x2_c1
G = 1x2_c2
H = 1x2_c1
I = 1x1_b1
J = 1x1_b1
K = 1x2_c4
L = 1x1_b3
M = 2x2_b2
N = 2x2_b1

third floor

----
-^^-
-A -
----

A = 1x1_b4
"""#

private func repositoryRootURL(from filePath: StaticString = #file) -> URL {
    URL(fileURLWithPath: "\(filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func structureDispatchContext() -> StructureGenerationContext {
    StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y <= 63 {
            return BlockState(id: "minecraft:sand")
        }
        return BlockState(id: "minecraft:air")
    }
}

@Test func testReferenceBuriedTreasureGeneration() async throws {
    let structure = Structure(
        type: "minecraft:buried_treasure",
        biomes: .rawID("minecraft:beach"),
        spawnOverrides: [:],
        step: "underground_structures"
    )
    // The reference chest is at ocean-floor Y=65, above sandstone at Y=64.
    let context = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { position in
        position.y <= 64 ? BlockState(id: "minecraft:sandstone") : BlockState(id: "minecraft:air")
    }
    let containers = try #require(try structure.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: 13, z: -113),
        context: context
    ))

    #expect(containers == [
        StructureLootContainer(
            block: "minecraft:chest",
            pos: PosInt3D(x: 217, y: 65, z: -1_799),
            lootTable: "minecraft:chests/buried_treasure",
            lootSeed: -7_406_929_932_979_763_269
        )
    ])

    let lootURL = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/loot_table/chests/buried_treasure.json")
    let lootTable = try makeTestingJSONDecoder(.latestSupported).decode(LootTable.self, from: Data(contentsOf: lootURL))
    let items = try lootTable.generateLoot(withContext: LootContext(
        random: CheckedRandom(seed: UInt64(bitPattern: containers[0].lootSeed))
    ))
    let counts = Dictionary(grouping: items, by: \.itemName).mapValues { $0.reduce(0) { $0 + $1.count } }
    #expect(counts == [
        "minecraft:potion": 1,
        "minecraft:diamond": 1,
        "minecraft:gold_ingot": 1,
        "minecraft:emerald": 8,
        "minecraft:iron_ingot": 11,
        "minecraft:cooked_salmon": 5,
        "minecraft:heart_of_the_sea": 1
    ])
}

private func oceanRuinTestContext(terrainTopY: Int32) throws -> StructureGenerationContext {
    let pack = try DataPack(
        fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"),
        loadingOptions: [
            .noDensityFunctions,
            .noNoises,
            .noNoiseSettings,
            .noDimensions,
            .noBiomes,
            .noStructureSets,
            .noEnchantments
        ]
    )
    return StructureGenerationContext(
        seaLevel: 63,
        minimumWorldY: -64,
        usingDataPacks: [pack]
    ) { position in
        if position.y <= terrainTopY { return BlockState(id: "minecraft:sand") }
        if position.y <= 63 { return BlockState(id: "minecraft:water") }
        return BlockState(id: "minecraft:air")
    }
}

@Test func testSeed123458OceanRuinLootReference() async throws {
    let coldURL = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/ocean_ruin_cold.json")
    let cold = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: coldURL))
    let first = try #require(try cold.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: -80, z: -14),
        context: try oceanRuinTestContext(terrainTopY: 50)
    ))
    let expectedFirst = [
        StructureLootContainer(block: "minecraft:suspicious_gravel", pos: PosInt3D(x: -1_284, y: 53, z: -220), lootTable: "minecraft:archaeology/ocean_ruin_cold", lootSeed: 210_021_809_879_268_742),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: -1_284, y: 51, z: -220), lootTable: "minecraft:chests/underwater_ruin_small", lootSeed: 7_060_055_725_571_229_747),
        StructureLootContainer(block: "minecraft:suspicious_gravel", pos: PosInt3D(x: -1_284, y: 51, z: -221), lootTable: "minecraft:archaeology/ocean_ruin_cold", lootSeed: 4_705_947_991_733_436_050),
        StructureLootContainer(block: "minecraft:suspicious_gravel", pos: PosInt3D(x: -1_280, y: 51, z: -221), lootTable: "minecraft:archaeology/ocean_ruin_cold", lootSeed: 6_281_515_458_314_742_408),
        StructureLootContainer(block: "minecraft:suspicious_gravel", pos: PosInt3D(x: -1_280, y: 51, z: -222), lootTable: "minecraft:archaeology/ocean_ruin_cold", lootSeed: 3_572_718_140_151_180_765)
    ]
    for container in expectedFirst { #expect(first.contains(container)) }

    let warmURL = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/ocean_ruin_warm.json")
    let warm = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: warmURL))
    let second = try #require(try warm.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: -113, z: -12),
        context: try oceanRuinTestContext(terrainTopY: 39)
    ))
    #expect(second.contains(StructureLootContainer(
        block: "minecraft:chest",
        pos: PosInt3D(x: -1_807, y: 40, z: -190),
        lootTable: "minecraft:chests/underwater_ruin_small",
        lootSeed: 2_708_431_354_643_074_529
    )))
}

@Test func testSeed123458ShipwreckLootReference() async throws {
    let url = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/shipwreck.json")
    let shipwreck = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: url))
    let containers = try #require(try shipwreck.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: -303, z: 42),
        context: try oceanRuinTestContext(terrainTopY: 46)
    ))
    #expect(containers == [
        StructureLootContainer(
            block: "minecraft:chest", pos: PosInt3D(x: -4_846, y: 51, z: 690),
            lootTable: "minecraft:chests/shipwreck_treasure", lootSeed: 4_690_697_583_387_820_557
        ),
        StructureLootContainer(
            block: "minecraft:chest", pos: PosInt3D(x: -4_845, y: 49, z: 696),
            lootTable: "minecraft:chests/shipwreck_map", lootSeed: 8_822_147_397_372_835_995
        )
    ])
    let treasureURL = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/loot_table/chests/shipwreck_treasure.json")
    let treasureTable = try makeTestingJSONDecoder(.latestSupported).decode(LootTable.self, from: Data(contentsOf: treasureURL))
    let treasureItems = try treasureTable.generateLoot(withContext: LootContext(
        random: CheckedRandom(seed: UInt64(bitPattern: containers[0].lootSeed))
    ))
    let treasureCounts = Dictionary(grouping: treasureItems, by: \.itemName).mapValues { $0.reduce(0) { $0 + $1.count } }
    #expect(treasureCounts == ["minecraft:iron_nugget": 3, "minecraft:iron_ingot": 18, "minecraft:lapis_lazuli": 9])
}

@Test func testSeed123458NetherFossilDriedGhastReference() throws {
    let pack = try DataPack(fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"))
    let context = StructureGenerationContext(
        seaLevel: 32, minimumWorldY: 0, maximumWorldY: 255, usingDataPacks: [pack]
    ) { position in
        // The reference fossil's support terrain is below Y=73; keep the
        // recorded dried-ghast position air so the post-process can place it.
        if position.y <= 73 && position != PosInt3D(x: -218, y: 73, z: 491) {
            return BlockState(id: "minecraft:netherrack")
        }
        return BlockState(id: "minecraft:air")
    }
    let url = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/nether_fossil.json")
    let fossil = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: url))

    let first = try #require(try fossil.generate(
        worldSeed: 123_458, startChunk: PosInt2D(x: -14, z: 30), context: context
    ))
    guard case .netherFossil(let firstResult) = first else {
        Issue.record("Expected a Nether fossil result")
        return
    }
    #expect(firstResult.blocks.block(at: PosInt3D(x: -218, y: 73, z: 491)).id == "minecraft:dried_ghast")

    let second = try #require(try fossil.generate(
        worldSeed: 123_458, startChunk: PosInt2D(x: -12, z: 32), context: context
    ))
    guard case .netherFossil(let secondResult) = second else {
        Issue.record("Expected a Nether fossil result")
        return
    }
    #expect(!secondResult.blocks.allTouchedBlocks().contains { $0.1.id == "minecraft:dried_ghast" })
}

@Test func testSeed123458IglooLootReference() async throws {
    let url = repositoryRootURL().appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/igloo.json")
    let igloo = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: url))
    let context = try oceanRuinTestContext(terrainTopY: 69)
    #expect(try igloo.generateLoot(
        worldSeed: 123_458, startChunk: PosInt2D(x: 229, z: 151), context: context
    ) == [])
    let containers = try #require(try igloo.generateLoot(
        worldSeed: 123_458, startChunk: PosInt2D(x: 183, z: 224), context: context
    ))
    #expect(containers == [StructureLootContainer(
        block: "minecraft:chest", pos: PosInt3D(x: 2_932, y: 52, z: 3_587),
        lootTable: "minecraft:chests/igloo_chest", lootSeed: 732_956_429_499_200_025
    )])
    let lootURL = repositoryRootURL().appendingPathComponent("vanilla/1.21.11/data/minecraft/loot_table/chests/igloo_chest.json")
    let lootTable = try makeTestingJSONDecoder(.latestSupported).decode(LootTable.self, from: Data(contentsOf: lootURL))
    let items = try lootTable.generateLoot(withContext: LootContext(
        random: CheckedRandom(seed: UInt64(bitPattern: containers[0].lootSeed))
    ))
    let counts = Dictionary(grouping: items, by: \.itemName).mapValues { $0.reduce(0) { $0 + $1.count } }
    #expect(counts == ["minecraft:coal": 4, "minecraft:golden_apple": 1])
}

@Test func testSwampHutGenerationDispatch() async throws {
    let url = repositoryRootURL().appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/structure/swamp_hut.json")
    let hut = try makeTestingJSONDecoder(.latestSupported).decode(Structure.self, from: Data(contentsOf: url))
    let generated = try #require(try hut.generate(
        worldSeed: 123_458, startChunk: PosInt2D(x: 0, z: 0), context: structureDispatchContext()
    ))
    guard case .swampHut(let result) = generated else {
        Issue.record("Expected swamp-hut generation result")
        return
    }
    #expect(result.lootContainers.isEmpty)
    #expect(result.graph.boundingBox.maxY - result.graph.boundingBox.minY == 6)
}

private func mansionTestContext(terrainTopY: Int32 = 80) throws -> StructureGenerationContext {
    let pack = try DataPack(
        fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"),
        loadingOptions: [
            .noDensityFunctions,
            .noNoises,
            .noNoiseSettings,
            .noDimensions,
            .noBiomes,
            .noStructureSets,
            .noEnchantments
        ]
    )
    return StructureGenerationContext(
        seaLevel: 63,
        minimumWorldY: -64,
        usingDataPacks: [pack]
    ) { pos in
        if pos.y <= terrainTopY {
            return BlockState(id: "minecraft:stone")
        }
        return BlockState(id: "minecraft:air")
    }
}

@Test func testNetherFortressLayoutIsIndependentOfTerrain() async throws {
    let fortress = Structure(
        type: "minecraft:fortress",
        biomes: .rawID("minecraft:nether_wastes"),
        spawnOverrides: [:],
        step: "underground_decoration"
    )
    let start = PosInt2D(x: -20, z: 29)
    let lowTerrain = try #require(try fortress.generatePieceGraph(
        worldSeed: 123_458, startChunk: start, context: try mansionTestContext(terrainTopY: 32)
    ))
    let highTerrain = try #require(try fortress.generatePieceGraph(
        worldSeed: 123_458, startChunk: start, context: try mansionTestContext(terrainTopY: 96)
    ))

    #expect(lowTerrain.orientation == highTerrain.orientation)
    #expect(lowTerrain.boundingBox == highTerrain.boundingBox)
    #expect(lowTerrain.pieces.map(\.boundingBox) == highTerrain.pieces.map(\.boundingBox))
    // Official 1.21.11 at this start has 127 children, including the start.
    #expect(lowTerrain.pieces.count == 127)
}

@Test func testNetherTerrainAtFortressReferenceAreaIsDeterministic() throws {
    let pack = try DataPack(fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"))
    let generator = try WorldGenerator(
        withWorldSeed: 123_458,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:nether")
    )
    let chunkPosition = PosInt2D(x: -23, z: 28) // Contains the first reference chest.
    let first = ProtoChunk()
    let second = ProtoChunk()
    try generator.generateInto(first, at: chunkPosition)
    try generator.generateInto(second, at: chunkPosition)
    // Match vanilla's terrain stages before comparing server terrain. Features
    // such as basalt pillars are placed later and are not density terrain.
    try generator.applySurfaceRules(to: first, at: chunkPosition)
    try generator.applySurfaceRules(to: second, at: chunkPosition)
    try generator.carve(first, at: chunkPosition)
    try generator.carve(second, at: chunkPosition)

    var terrainBlocks = 0
    var lavaBlocks = 0
    for y in Int32(0)..<128 {
        for x in Int32(0)..<16 {
            for z in Int32(0)..<16 {
                let local = PosInt3D(x: x, y: y, z: z)
                terrainBlocks += first.isTerrain(atLocal: local) ? 1 : 0
                lavaBlocks += first.block(atLocal: local).id == "minecraft:lava" ? 1 : 0
                #expect(first.block(atLocal: local) == second.block(atLocal: local))
            }
        }
    }
    #expect(terrainBlocks > 0)
    #expect(lavaBlocks > 0)
}


@Test func testLoadedStructureDecorationParameters() async throws {
    let context = try mansionTestContext()
    let mansion = try #require(
        context.structureDecorationParameters(forStructureID: "minecraft:mansion")
    )
    #expect(mansion.step == 4)
    #expect(mansion.index == 5)

    let pyramid = try #require(
        context.structureDecorationParameters(forStructureID: "minecraft:desert_pyramid")
    )
    #expect(pyramid.step == 4)
    #expect(pyramid.index == 1)

    let stronghold = try #require(
        context.structureDecorationParameters(forStructureID: "minecraft:stronghold")
    )
    #expect(stronghold.step == 4)
    #expect(stronghold.index == 19)
}

private func loadMansionLootEnchantmentResources() throws -> LootEnchantmentResources {
    let pack = try DataPack(
        fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"),
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

private func decodeVanillaMansionLootTable() throws -> LootTable {
    let url = repositoryRootURL()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/loot_table/chests/woodland_mansion.json")
    return try makeTestingJSONDecoder(.latestSupported).decode(LootTable.self, from: Data(contentsOf: url))
}

private func normalizeMansionLoot(_ items: [ItemStack]) -> [MansionNormalizedLootItem] {
    var combined: [MansionNormalizedLootItem] = []
    for item in items {
        let normalized = MansionNormalizedLootItem(
            name: item.itemName,
            count: item.count,
            enchantments: item.enchantmentLevels
                .map { MansionNormalizedEnchantment(id: $0.key, level: $0.value) }
                .sorted { $0.id < $1.id }
        )
        if let index = combined.firstIndex(where: {
            $0.name == normalized.name && $0.enchantments == normalized.enchantments
        }) {
            let existing = combined[index]
            combined[index] = MansionNormalizedLootItem(
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
        return String(describing: left.enchantments) < String(describing: right.enchantments)
    }
}

private func sortedCells(_ cells: [PosInt2D]) -> [PosInt2D] {
    cells.sorted { left, right in
        if left.z != right.z { return left.z < right.z }
        return left.x < right.x
    }
}

private func roomCellKey(floor: Int, cells: [PosInt2D]) -> String {
    let roomCells = sortedCells(cells).map { "\($0.x),\($0.z)" }.joined(separator: "|")
    return "\(floor):\(roomCells)"
}

private func roomSortKey(floor: Int, cells: [PosInt2D]) -> (Int, Int32, Int32) {
    let sorted = sortedCells(cells)
    return (floor, sorted.first?.z ?? 0, sorted.first?.x ?? 0)
}

private func parseLootSeeds(from line: String) -> [Int64] {
    guard let start = line.firstIndex(of: "("), let end = line.lastIndex(of: ")"), start < end else {
        return []
    }
    let contents = line[line.index(after: start)..<end]
    return contents
        .split(whereSeparator: { !($0.isNumber || $0 == "-") })
        .compactMap { Int64($0) }
}

private func loadMansionReferenceRooms() throws -> [MansionReferenceRoom] {
    let lines = mansionReferenceText.components(separatedBy: .newlines)

    let floorIndexByName: [String: Int] = [
        "first floor": 0,
        "second floor": 1,
        "third floor": 2
    ]
    var currentFloor: Int?
    var currentGrid: [String] = []
    var currentMappings: [Character: (templateName: String, lootSeeds: [Int64])] = [:]
    var rooms: [MansionReferenceRoom] = []

    func flushCurrentFloor() throws {
        guard let currentFloor else { return }
        var cellsByLabel: [Character: [PosInt2D]] = [:]
        for (row, line) in currentGrid.enumerated() {
            for (column, character) in line.enumerated() where character.isUppercase {
                cellsByLabel[character, default: []].append(PosInt2D(x: Int32(column), z: Int32(row)))
            }
        }

        for (label, cells) in cellsByLabel {
            guard let mapping = currentMappings[label] else {
                throw MansionReferenceError.invalidRoomMapping("Missing mapping for \(label) on floor \(currentFloor)")
            }
            rooms.append(
                MansionReferenceRoom(
                    floor: currentFloor,
                    templateName: mapping.templateName,
                    cells: sortedCells(cells),
                    lootSeeds: mapping.lootSeeds.sorted()
                )
            )
        }
    }

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if let floor = floorIndexByName[line] {
            try flushCurrentFloor()
            currentFloor = floor
            currentGrid = []
            currentMappings = [:]
            continue
        }
        guard currentFloor != nil else { continue }
        if line.isEmpty {
            continue
        }
        if line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let label = parts[0].trimmingCharacters(in: .whitespaces).first
            else {
                throw MansionReferenceError.invalidRoomMapping(line)
            }
            let details = parts[1].trimmingCharacters(in: .whitespaces)
            let templateName = details.split(separator: "(", maxSplits: 1).first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? details
            currentMappings[label] = (templateName, parseLootSeeds(from: details))
        } else if line.allSatisfy({ $0 == "-" || $0 == " " || $0 == "*" || $0 == "^" || $0.isUppercase }) {
            currentGrid.append(line)
        } else if line.starts(with: "mansion at") {
            continue
        } else {
            throw MansionReferenceError.invalidHeader(line)
        }
    }

    try flushCurrentFloor()
    return rooms.sorted {
        roomSortKey(floor: $0.floor, cells: $0.cells) < roomSortKey(floor: $1.floor, cells: $1.cells)
    }
}

@Test func testStructureDispatchGeneratesDesertPyramid() async throws {
    let structure = Structure(
        type: "minecraft:desert_pyramid",
        biomes: .rawID("minecraft:desert"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected desert pyramid piece graph")
        return
    }
    guard case .desertPyramid(let generatedResult)? = result else {
        Issue.record("Expected desert pyramid generation result")
        return
    }

    #expect(generatedGraph.pieces.count == 1)
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)
}

@Test func testStructureDispatchGeneratesOceanMonument() async throws {
    let structure = Structure(
        type: "minecraft:ocean_monument",
        biomes: .rawID("minecraft:deep_ocean"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { _ in
        BlockState(id: "minecraft:water")
    }

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected ocean monument piece graph")
        return
    }
    guard case .oceanMonument(let generatedResult)? = result else {
        Issue.record("Expected ocean monument generation result")
        return
    }

    #expect(generatedGraph.pieces.count > 1)
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)
    #expect(try structure.generateLoot(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0), context: context) == [])
}

@Test func testStructureDispatchGeneratesStronghold() async throws {
    let structure = Structure(
        type: "minecraft:stronghold",
        biomes: .rawID("minecraft:plains"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected stronghold piece graph")
        return
    }
    guard case .stronghold(let generatedResult)? = result else {
        Issue.record("Expected stronghold generation result")
        return
    }

    #expect(generatedGraph.pieces.count > 5)
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)
    #expect(!generatedResult.blocks.allTouchedBlocks().isEmpty)
    #expect(!generatedResult.chestLootMarkers.isEmpty)
    #expect(generatedResult.markers.contains { $0.represents == "minecraft:silverfish_spawner" })
    #expect(generatedGraph.pieces.contains { String(describing: type(of: $0)).contains("PortalRoom") })
}

@Test func testStructureDispatchGeneratesWoodlandMansion() async throws {
    let structure = Structure(
        type: "minecraft:woodland_mansion",
        biomes: .rawID("minecraft:dark_forest"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = try mansionTestContext()

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected woodland mansion piece graph")
        return
    }
    guard case .woodlandMansion(let generatedResult)? = result else {
        Issue.record("Expected woodland mansion generation result")
        return
    }

    #expect(generatedGraph.pieces.count > 20)
    #expect(!generatedResult.blocks.allTouchedBlocks().isEmpty)
    #expect(!generatedResult.chestLootMarkers.isEmpty)
    #expect(generatedResult.chestLootMarkers.allSatisfy { $0.lootTable == "minecraft:chests/woodland_mansion" })
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)

    let loot = try #require(
        try structure.generateLoot(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0), context: context)
    )
    let expected = generatedResult.chestLootMarkers.map {
        StructureLootContainer(block: "minecraft:chest", pos: $0.pos, lootTable: $0.lootTable, lootSeed: $0.lootSeed)
    }
    #expect(loot == expected)
}

@Test func testReferenceWoodlandMansionReplacesLootStructureBlocksWithChests() async throws {
    let structure = Structure(
        type: "minecraft:woodland_mansion",
        biomes: .rawID("minecraft:dark_forest"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = try mansionTestContext()
    let expectedRooms = try loadMansionReferenceRooms()
    let worldSeed: WorldSeed = 4_609_964_304_437_707_654
    let startChunk = PosInt2D(x: -452, z: 18)

    guard let roomPlacements = try WoodlandMansion.generateRoomPlacements(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: context
    ) else {
        Issue.record("Expected woodland mansion room placements")
        return
    }
    guard case .woodlandMansion(let generatedResult)? = try structure.generate(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: context
    ) else {
        Issue.record("Expected woodland mansion generation result")
        return
    }

    let expectedLootRoomCount = expectedRooms.filter { !$0.lootSeeds.isEmpty }.count
    #expect(Set(roomPlacements.map(\.floor)) == [0, 1, 2])
    #expect(roomPlacements.count >= expectedRooms.count)
    #expect(generatedResult.chestLootMarkers.count >= expectedLootRoomCount)

    for marker in generatedResult.chestLootMarkers {
        #expect(marker.lootTable == "minecraft:chests/woodland_mansion")
        #expect(generatedResult.blocks.block(at: marker.pos).id == "minecraft:chest")
    }
}

@Test func testReferenceWoodlandMansionRoomOnlyGenerationMatchesAdjustedRoomPlacements() async throws {
    let context = try mansionTestContext()
    let worldSeed: WorldSeed = 4_609_964_304_437_707_654
    let startChunk = PosInt2D(x: -452, z: 18)

    guard let adjustedRooms = try WoodlandMansion.generateRoomPlacements(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: context
    ) else {
        Issue.record("Expected adjusted woodland mansion room placements")
        return
    }
    guard let roomOnly = try WoodlandMansion.generateRoomPlacements(
        worldSeed: worldSeed,
        startChunk: startChunk,
        context: context,
        adjustToTerrain: false
    ) else {
        Issue.record("Expected room-only woodland mansion placements")
        return
    }

    let adjustedByKey = Dictionary(uniqueKeysWithValues: adjustedRooms.map { (roomCellKey(floor: $0.floor, cells: $0.cells), $0) })
    let roomOnlyByKey = Dictionary(uniqueKeysWithValues: roomOnly.map { (roomCellKey(floor: $0.floor, cells: $0.cells), $0) })

    #expect(adjustedByKey.keys == roomOnlyByKey.keys)

    let yOffsets = Set(adjustedByKey.keys.map { adjustedByKey[$0]!.boundingBox.minY - roomOnlyByKey[$0]!.boundingBox.minY })
    #expect(yOffsets == [81])

    for key in adjustedByKey.keys {
        let adjusted = adjustedByKey[key]!
        let raw = roomOnlyByKey[key]!
        #expect(adjusted.templateName == raw.templateName)
        #expect(adjusted.boundingBox.minX == raw.boundingBox.minX)
        #expect(adjusted.boundingBox.maxX == raw.boundingBox.maxX)
        #expect(adjusted.boundingBox.minZ == raw.boundingBox.minZ)
        #expect(adjusted.boundingBox.maxZ == raw.boundingBox.maxZ)
        #expect(adjusted.boundingBox.maxY - adjusted.boundingBox.minY == raw.boundingBox.maxY - raw.boundingBox.minY)
    }
}

@Test func testSeed123458WoodlandMansionLoot() async throws {
    let expected = [
        ExpectedMansionChest(
            pos: PosInt3D(x: -747, y: 97, z: -2_061),
            seed: -1_293_741_683_892_666_748,
            items: [
                MansionNormalizedLootItem(name: "minecraft:lead", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:vex_armor_trim_smithing_template", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:bread", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:pumpkin_seeds", count: 3, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:gunpowder", count: 3, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:string", count: 6, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:resin_clump", count: 8, enchantments: [])
            ]
        ),
        ExpectedMansionChest(
            pos: PosInt3D(x: -745, y: 86, z: -2_042),
            seed: -442_613_113_036_912_047,
            items: [
                MansionNormalizedLootItem(name: "minecraft:name_tag", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:rotten_flesh", count: 3, enchantments: []),
                MansionNormalizedLootItem(
                    name: "minecraft:enchanted_book",
                    count: 1,
                    enchantments: [MansionNormalizedEnchantment(id: "minecraft:impaling", level: 3)]
                ),
                MansionNormalizedLootItem(name: "minecraft:wheat", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:gunpowder", count: 3, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:coal", count: 2, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:string", count: 8, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:music_disc_13", count: 1, enchantments: [])
            ]
        ),
        ExpectedMansionChest(
            pos: PosInt3D(x: -707, y: 86, z: -2_050),
            seed: -5_834_824_498_661_224_473,
            items: [
                MansionNormalizedLootItem(name: "minecraft:string", count: 5, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:name_tag", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:resin_clump", count: 2, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:wheat", count: 4, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:rotten_flesh", count: 2, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:music_disc_cat", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:gunpowder", count: 1, enchantments: [])
            ]
        ),
        ExpectedMansionChest(
            pos: PosInt3D(x: -750, y: 72, z: -2_037),
            seed: -873_225_616_246_710_491,
            items: [
                MansionNormalizedLootItem(name: "minecraft:resin_clump", count: 6, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:bone", count: 13, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:redstone", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:diamond_hoe", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:diamond_chestplate", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:vex_armor_trim_smithing_template", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:rotten_flesh", count: 7, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:lead", count: 1, enchantments: [])
            ]
        ),
        ExpectedMansionChest(
            pos: PosInt3D(x: -761, y: 72, z: -2_030),
            seed: -5_294_497_027_672_139_194,
            items: [
                MansionNormalizedLootItem(name: "minecraft:resin_clump", count: 4, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:name_tag", count: 1, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:rotten_flesh", count: 5, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:chainmail_chestplate", count: 2, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:string", count: 7, enchantments: []),
                MansionNormalizedLootItem(name: "minecraft:melon_seeds", count: 2, enchantments: [])
            ]
        )
    ]
    let structure = Structure(
        type: "minecraft:woodland_mansion",
        biomes: .rawID("minecraft:dark_forest"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = try mansionTestContext(terrainTopY: 70)
    let containers = try #require(
        try structure.generateLoot(
            worldSeed: 123_458,
            startChunk: PosInt2D(x: -44, z: -129),
            context: context
        )
    )
    let lootTable = try decodeVanillaMansionLootTable()
    let enchantmentResources = try loadMansionLootEnchantmentResources()

    for expectedChest in expected {
        let actual = try #require(
            containers.first { $0.pos == expectedChest.pos },
            "Generated chests: \(containers.map { "\($0.pos) -> \($0.lootSeed)" })"
        )
        #expect(actual.block == "minecraft:chest")
        #expect(actual.lootTable == "minecraft:chests/woodland_mansion")
        #expect(actual.lootSeed == expectedChest.seed)
        let generated = try lootTable.generateLoot(
            withContext: LootContext(
                random: CheckedRandom(seed: UInt64(bitPattern: actual.lootSeed)),
                enchantmentResources: enchantmentResources
            )
        )
        #expect(normalizeMansionLoot(generated) == normalizeMansionLoot(expectedChest.items.map {
            ItemStack(itemName: $0.name, count: $0.count).settingEnchantments(
                Dictionary(uniqueKeysWithValues: $0.enchantments.map { ($0.id, $0.level) })
            )
        }))
    }
}

@Test func testSeed123458WoodlandMansionChestPosition() async throws {
    let structure = Structure(
        type: "minecraft:woodland_mansion",
        biomes: .rawID("minecraft:dark_forest"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let containers = try #require(
        try structure.generateLoot(
            worldSeed: 123_458,
            startChunk: PosInt2D(x: -44, z: -129),
            context: mansionTestContext(terrainTopY: 70)
        )
    )

    #expect(containers.contains { $0.pos == PosInt3D(x: -724, y: 77, z: -2_038) })
    #expect(!containers.contains { $0.pos == PosInt3D(x: -727, y: 77, z: -2_034) })
}

@Test func testSeed123458JungleTempleLootContainers() async throws {
    let structure = Structure(
        type: "minecraft:jungle_temple",
        biomes: .rawID("minecraft:jungle"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        // Heightmaps return the first air block; the real fixture has heightmap Y=95.
        BlockState(id: pos.y <= 94 ? "minecraft:stone" : "minecraft:air")
    }
    let containers = try #require(try structure.generateLoot(
        worldSeed: 123_458,
        startChunk: PosInt2D(x: 19, z: -79),
        context: context
    ))
    #expect(containers.sorted {
        $0.pos.x == $1.pos.x ? $0.pos.y < $1.pos.y : $0.pos.x < $1.pos.x
    } == [
        StructureLootContainer(block: "minecraft:dispenser", pos: PosInt3D(x: 307, y: 93, z: -1251), lootTable: "minecraft:chests/jungle_temple_dispenser", lootSeed: -922_536_149_578_112_079),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 312, y: 92, z: -1253), lootTable: "minecraft:chests/jungle_temple", lootSeed: -8_998_445_778_454_986_147),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 313, y: 92, z: -1260), lootTable: "minecraft:chests/jungle_temple", lootSeed: 3_998_629_534_634_752_572),
        StructureLootContainer(block: "minecraft:dispenser", pos: PosInt3D(x: 313, y: 93, z: -1253), lootTable: "minecraft:chests/jungle_temple_dispenser", lootSeed: 2_229_079_904_170_270_178)
    ])
}

@Test func testStructureDispatchRejectsUnsupportedTypes() async throws {
    let structure = Structure(
        type: "minecraft:unsupported_structure",
        biomes: .rawID("minecraft:end_highlands"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:unsupported_structure")) {
        _ = try structure.generatePieceGraph(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:unsupported_structure")) {
        _ = try structure.generate(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:unsupported_structure")) {
        _ = try structure.generateLoot(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }
}

@Test func testSeed123458EndCityReferenceLootContainers() async throws {
    let structure = Structure(type: "minecraft:end_city", biomes: .rawID("minecraft:end_highlands"), spawnOverrides: [:], step: "surface_structures")
    // The positions and seeds below are the End City entries in
    // vanilla/vanilla_structure_ref.txt.  The listed positive-Z chest positions
    // identify its chunk as (64, 24); the header's Z sign is stale.
    let result = try #require(try structure.generate(worldSeed: 123_458, startChunk: PosInt2D(x: 64, z: 24), context: mansionTestContext(terrainTopY: 64)))
    guard case .endCity(let city) = result else { Issue.record("Expected End City"); return }
    #expect(city.lootContainers.sorted { $0.pos.x == $1.pos.x ? $0.pos.y < $1.pos.y : $0.pos.x < $1.pos.x } == [
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 1029, y: 90, z: 414), lootTable: "minecraft:chests/end_city_treasure", lootSeed: 1_531_354_062_817_683_618),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 1032, y: 142, z: 405), lootTable: "minecraft:chests/end_city_treasure", lootSeed: -2_383_628_156_103_950_367),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 1034, y: 142, z: 407), lootTable: "minecraft:chests/end_city_treasure", lootSeed: -1_607_583_170_481_175_037),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 1106, y: 132, z: 409), lootTable: "minecraft:chests/end_city_treasure", lootSeed: -2_121_263_389_488_661_811),
        StructureLootContainer(block: "minecraft:chest", pos: PosInt3D(x: 1106, y: 132, z: 411), lootTable: "minecraft:chests/end_city_treasure", lootSeed: -7_934_366_909_957_453_390)
    ])
}
