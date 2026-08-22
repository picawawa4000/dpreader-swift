import Foundation
import Testing
@testable import DPReader

private struct MansionReferenceRoom {
    let floor: Int
    let templateName: String
    let cells: [PosInt2D]
    let lootSeeds: [Int64]
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
            return BlockState(type: Block(withID: "minecraft:sand"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

private func mansionTestContext() throws -> StructureGenerationContext {
    let pack = try DataPack(
        fromRootPath: repositoryRootURL().appendingPathComponent("vanilla/1.21.11"),
        loadingOptions: [
            .noDensityFunctions,
            .noNoises,
            .noNoiseSettings,
            .noDimensions,
            .noBiomes,
            .noStructures,
            .noStructureSets,
            .noEnchantments
        ]
    )
    return StructureGenerationContext(
        seaLevel: 63,
        minimumWorldY: -64,
        usingDataPacks: [pack]
    ) { pos in
        if pos.y <= 80 {
            return BlockState(type: Block(withID: "minecraft:stone"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
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
        BlockState(type: Block(withID: "minecraft:water"))
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
        #expect(generatedResult.blocks.block(at: marker.pos).type.id == "minecraft:chest")
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

@Test func testStructureDispatchRejectsUnsupportedTypes() async throws {
    let structure = Structure(
        type: "minecraft:fortress",
        biomes: .rawID("minecraft:nether_wastes"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:fortress")) {
        _ = try structure.generatePieceGraph(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:fortress")) {
        _ = try structure.generate(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:fortress")) {
        _ = try structure.generateLoot(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }
}
