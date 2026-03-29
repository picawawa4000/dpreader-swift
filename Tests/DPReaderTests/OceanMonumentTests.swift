import Foundation
import Testing
@testable import DPReader

private func oceanMonumentTestContext() -> OceanMonumentGenerationContext {
    OceanMonumentGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y < 30 {
            return BlockState(type: Block(withID: "minecraft:stone"))
        }
        if pos.y <= 63 {
            return BlockState(type: Block(withID: "minecraft:water"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

private struct ExpectedMonumentPieceGraph {
    let occupiedCellsByLabel: [String: Set<OceanMonumentRoomCell>]
    let edges: Set<String>
}

private func parseExpectedMonumentPieceGraph(_ text: String) -> ExpectedMonumentPieceGraph {
    let sections = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n\n")
    precondition(sections.count == 4)

    var occupiedCellsByLabel: [String: Set<OceanMonumentRoomCell>] = [:]
    for (floorIndex, gridSection) in sections.prefix(3).enumerated() {
        let rows = gridSection.split(separator: "\n").map(String.init)
        precondition(rows.count == 4)
        for (z, row) in rows.enumerated() {
            precondition(row.count == 5)
            for (x, character) in row.enumerated() where character != "0" {
                occupiedCellsByLabel[String(character), default: []].insert(
                    OceanMonumentRoomCell(x: x, y: floorIndex, z: z)
                )
            }
        }
    }

    let edges = Set(
        sections[3]
            .split(separator: "\n")
            .map { line -> String in
                let parts = line.split(separator: "-").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                precondition(parts.count == 2)
                return parts.sorted().joined(separator: " <-> ")
            }
    )

    return ExpectedMonumentPieceGraph(occupiedCellsByLabel: occupiedCellsByLabel, edges: edges)
}

private let userProvidedMonumentGraph = """
JJLOG
JJIEF
KCCD6
BB1D8

JJMMN
JJIHH
K9236
0A237

00000
00000
0PPR0
0Q540

1 - 2
2 - 3
3 - 4
4 - 5
3 - 6
6 - 7
6 - 8
2 - 9
9 - A
A - B
9 - C
C - D
D - E
E - F
F - G
F - H
E - I
C - I
C - J
J - K
J - L
L - M
M - N
L - O
2 - P
A - Q
3 - R
"""

private func transformedDisplayCells(
    for snapshot: OceanMonumentRoomPieceGraphSnapshot,
    flipX: Bool,
    flipZ: Bool
) -> [Int: Set<OceanMonumentRoomCell>] {
    Dictionary(uniqueKeysWithValues: snapshot.pieces.map { piece in
        let transformed = Set(piece.occupiedRoomCells.map { cell in
            let x = flipX ? 4 - cell.x : cell.x
            let displayZBase = if cell.y == 2 {
                flipZ ? 1 - cell.z : cell.z
            } else {
                flipZ ? 3 - cell.z : cell.z
            }
            let z = cell.y == 2 ? displayZBase + 2 : displayZBase
            return OceanMonumentRoomCell(x: x, y: cell.y, z: z)
        })
        return (piece.roomIndex, transformed)
    })
}

@Test func testOceanMonumentBlockVolumeSamplerFallback() async throws {
    let bounds = OceanMonumentBoundingBox(minX: 0, minY: 0, minZ: 0, maxX: 31, maxY: 31, maxZ: 31)
    let volume = OceanMonumentBlockVolume(bounds: bounds) { _ in
        BlockState(type: Block(withID: "minecraft:stone"))
    }

    #expect(volume.block(at: PosInt3D(x: 1, y: 2, z: 3)).type.id == "minecraft:stone")

    volume.setBlock(BlockState(type: Block(withID: "minecraft:water")), at: PosInt3D(x: 1, y: 2, z: 3))
    #expect(volume.block(at: PosInt3D(x: 1, y: 2, z: 3)).type.id == "minecraft:water")
    #expect(volume.block(at: PosInt3D(x: 2, y: 2, z: 3)).type.id == "minecraft:stone")
}

@Test func testOceanMonumentPieceGraphIsDeterministic() async throws {
    let graphA = OceanMonument.generatePieceGraph(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0))
    let graphB = OceanMonument.generatePieceGraph(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0))

    #expect(graphA.orientation == graphB.orientation)
    #expect(graphA.boundingBox == graphB.boundingBox)
    #expect(graphA.pieces.count == graphB.pieces.count)
    #expect(graphA.pieces.map(\.kind) == graphB.pieces.map(\.kind))
    #expect(graphA.pieces.count == 32)
    #expect(graphA.boundingBox == OceanMonumentBoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
}

@Test func testOceanMonumentGenerationSnapshot() async throws {
    let result = OceanMonument.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: oceanMonumentTestContext()
    )

    let counts = result.blocks.allTouchedBlocks().reduce(into: [String: Int]()) { partialResult, entry in
        partialResult[entry.1.type.id, default: 0] += 1
    }
    let hash = result.blocks.allTouchedBlocks().reduce(into: UInt64(1469598103934665603)) { partialResult, entry in
        partialResult ^= UInt64(bitPattern: Int64(entry.0.x))
        partialResult &*= 1099511628211
        partialResult ^= UInt64(bitPattern: Int64(entry.0.y))
        partialResult &*= 1099511628211
        partialResult ^= UInt64(bitPattern: Int64(entry.0.z))
        partialResult &*= 1099511628211
        for byte in entry.1.type.id.utf8 {
            partialResult ^= UInt64(byte)
            partialResult &*= 1099511628211
        }
    }

    #expect(result.graph.pieces.count == 32)
    #expect(result.graph.boundingBox == OceanMonumentBoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
    #expect(result.blocks.allTouchedBlocks().count == 16547)
    #expect(
        result.elderGuardians == [
            PosInt3D(x: -17, y: 42, z: -12),
            PosInt3D(x: 16, y: 45, z: -15),
            PosInt3D(x: -1, y: 53, z: -1)
        ]
    )
    #expect(counts == [
        "minecraft:dark_prismarine": 275,
        "minecraft:gold_block": 8,
        "minecraft:prismarine": 6582,
        "minecraft:prismarine_bricks": 9494,
        "minecraft:sea_lantern": 122,
        "minecraft:water": 66
    ])
    #expect(hash == 6749865940407714986)
}

@Test func testOceanMonumentRoomPieceGraphMatchesUserReferenceAtSeed123456789Block1200_0() async throws {
    // The handwritten reference is keyed by the monument's block-aligned start position `(1200, 0)`,
    // so the corresponding start chunk is `(75, 0)`.
    let snapshot = OceanMonument.generateRoomPieceGraph(worldSeed: 123456789, startChunk: PosInt2D(x: 75, z: 0))
    let expected = parseExpectedMonumentPieceGraph(userProvidedMonumentGraph)
    let transformed = transformedDisplayCells(for: snapshot, flipX: true, flipZ: true)
    let expectedCells = Set(expected.occupiedCellsByLabel.values)
    let actualCells = Set(transformed.values)

    let matchedPieceRoomIndices = Set(
        transformed.compactMap { roomIndex, cells in
            expectedCells.contains(cells) ? roomIndex : nil
        }
    )
    let extraPieceCells = actualCells.subtracting(expectedCells)

    #expect(expectedCells.subtracting(actualCells).isEmpty)
    #expect(extraPieceCells == Set([Set([OceanMonumentRoomCell(x: 0, y: 1, z: 3)])]))

    let labelByRoomIndex: [Int: String] = Dictionary(uniqueKeysWithValues: transformed.compactMap { roomIndex, cells in
        guard let label = expected.occupiedCellsByLabel.first(where: { $0.value == cells })?.key else {
            return nil
        }
        return (roomIndex, label)
    })
    let actualEdges = Set(
        snapshot.pieces.compactMap { piece -> [String]? in
            guard matchedPieceRoomIndices.contains(piece.roomIndex),
                  let label = labelByRoomIndex[piece.roomIndex]
            else {
                return nil
            }
            return piece.connectedPieceRoomIndices.compactMap { connectedRoomIndex in
                guard matchedPieceRoomIndices.contains(connectedRoomIndex),
                      let connectedLabel = labelByRoomIndex[connectedRoomIndex]
                else {
                    return nil
                }
                return [label, connectedLabel].sorted().joined(separator: " <-> ")
            }
        }.flatMap { $0 }
    )

    #expect(actualEdges == expected.edges)
}
