import Foundation
import Testing
@testable import DPReader

private func pieceTypeNames(_ pieces: [StructurePiece]) -> [String] {
    pieces.map { String(describing: type(of: $0)) }
}

private struct ScriptedRandom: Random {
    typealias Splitter = CheckedRandomSplitter

    var nextValues: [UInt32]

    mutating func next(bound: UInt32) -> UInt32 {
        precondition(!self.nextValues.isEmpty)
        return self.nextValues.removeFirst() % bound
    }

    mutating func nextLong() -> UInt64 { 0 }
    mutating func nextInt32() -> Int32 { 0 }
    mutating func nextFloat() -> Float { 0 }
    mutating func nextDouble() -> Double { 0 }
    mutating func nextSplitter() -> CheckedRandomSplitter { CheckedRandomSplitter(seed: 0) }
    mutating func skip(calls: UInt) {}
}

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

private struct ExpectedMonumentReferenceCase {
    let name: String
    let occupiedCellsByLabel: [String: Set<OceanMonumentRoomCell>]
    let expectedEdges: Set<String>
    let labelsByTypeNumber: [Int: [String]]
    let expectedTypeMapping: [Int: MonumentReferenceRoomSignature]?
    let worldSeed: WorldSeed
    let startChunk: PosInt2D
    let expectedExtraPieceCells: Set<Set<OceanMonumentRoomCell>>
}

private struct MonumentReferenceRoomSignature: Equatable, Hashable, CustomStringConvertible {
    let kind: OceanMonumentPieceKind
    let hasCenterPillar: Bool

    var description: String {
        if self.hasCenterPillar {
            return "\(self.kind.rawValue)(centerPillar: true)"
        }
        return self.kind.rawValue
    }
}

private func cell(_ x: Int, _ y: Int, _ z: Int) -> OceanMonumentRoomCell {
    OceanMonumentRoomCell(x: x, y: y, z: z)
}

private func cells(_ coords: (Int, Int, Int)...) -> Set<OceanMonumentRoomCell> {
    Set(coords.map { OceanMonumentRoomCell(x: $0.0, y: $0.1, z: $0.2) })
}

private func edge(_ a: String, _ b: String) -> String {
    [a, b].sorted().joined(separator: " <-> ")
}

private func edgeSet(_ pairs: [(String, String)]) -> Set<String> {
    Set(pairs.map { edge($0.0, $0.1) })
}

private func oldUserProvidedMonumentReference() -> ExpectedMonumentReferenceCase {
    ExpectedMonumentReferenceCase(
        name: "user reference at seed 123456789 block 1200,0",
        occupiedCellsByLabel: [
            "1": cells((2, 0, 3)),
            "2": cells((2, 1, 2), (2, 1, 3)),
            "3": cells((3, 1, 2), (3, 1, 3)),
            "4": cells((3, 2, 3)),
            "5": cells((2, 2, 3)),
            "6": cells((4, 0, 2), (4, 1, 2)),
            "7": cells((4, 1, 3)),
            "8": cells((4, 0, 3)),
            "9": cells((1, 1, 2)),
            "A": cells((1, 1, 3)),
            "B": cells((0, 0, 3), (1, 0, 3)),
            "C": cells((1, 0, 2), (2, 0, 2)),
            "D": cells((3, 0, 2), (3, 0, 3)),
            "E": cells((3, 0, 1)),
            "F": cells((4, 0, 1)),
            "G": cells((4, 0, 0)),
            "H": cells((3, 1, 1), (4, 1, 1)),
            "I": cells((2, 0, 1), (2, 1, 1)),
            "J": cells((0, 0, 0), (1, 0, 0), (0, 0, 1), (1, 0, 1), (0, 1, 0), (1, 1, 0), (0, 1, 1), (1, 1, 1)),
            "K": cells((0, 0, 2), (0, 1, 2)),
            "L": cells((2, 0, 0)),
            "M": cells((2, 1, 0), (3, 1, 0)),
            "N": cells((4, 1, 0)),
            "O": cells((3, 0, 0)),
            "P": cells((1, 2, 2), (2, 2, 2)),
            "Q": cells((1, 2, 3)),
            "R": cells((3, 2, 2))
        ],
        expectedEdges: edgeSet([
            ("1", "2"), ("2", "3"), ("3", "4"), ("4", "5"), ("3", "6"), ("6", "7"), ("6", "8"),
            ("2", "9"), ("9", "A"), ("A", "B"), ("9", "C"), ("C", "D"), ("D", "E"), ("E", "F"),
            ("F", "G"), ("F", "H"), ("E", "I"), ("C", "I"), ("C", "J"), ("J", "K"), ("J", "L"),
            ("L", "M"), ("M", "N"), ("L", "O"), ("2", "P"), ("A", "Q"), ("3", "R")
        ]),
        labelsByTypeNumber: [:],
        expectedTypeMapping: nil,
        worldSeed: 123456789,
        startChunk: PosInt2D(x: 75, z: 0),
        expectedExtraPieceCells: [Set([cell(0, 1, 3)])]
    )
}

private func parseExpectedMonumentReference(_ text: String) -> ExpectedMonumentReferenceCase {
    let lines = text.components(separatedBy: .newlines)
    var index = 0
    var occupiedCellsByLabel: [String: Set<OceanMonumentRoomCell>] = [:]

    for floorIndex in 0..<3 {
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        precondition(index < lines.count)
        precondition(lines[index] == "Floor \(floorIndex + 1)")
        index += 1
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        for z in 0..<4 {
            let row = Array(lines[index + z])
            precondition(row.count == 5)
            for (x, character) in row.enumerated() where character != "-" {
                occupiedCellsByLabel[String(character), default: []].insert(
                    OceanMonumentRoomCell(x: x, y: floorIndex, z: z)
                )
            }
        }
        index += 4
    }

    while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
    }
    precondition(index < lines.count)
    precondition(lines[index] == "Room types:")
    index += 1

    var labelsByTypeNumber: [Int: [String]] = [:]
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        index += 1
        if line.isEmpty {
            continue
        }
        if line.hasPrefix("Seed ") {
            let components = line
                .replacingOccurrences(of: "Seed ", with: "")
                .components(separatedBy: ", ")
            precondition(components.count == 3)
            let worldSeed = UInt64(bitPattern: Int64(components[0])!)
            let blockX = Int32(components[1].replacingOccurrences(of: "X = ", with: ""))!
            let blockZ = Int32(components[2].replacingOccurrences(of: "Z = ", with: ""))!
            precondition(blockX % 16 == 0)
            precondition(blockZ % 16 == 0)
            return ExpectedMonumentReferenceCase(
                name: "vanilla monument reference fixture",
                occupiedCellsByLabel: occupiedCellsByLabel,
                expectedEdges: [],
                labelsByTypeNumber: labelsByTypeNumber,
                expectedTypeMapping: [
                    1: MonumentReferenceRoomSignature(kind: .doubleYZRoom, hasCenterPillar: false),
                    2: MonumentReferenceRoomSignature(kind: .simpleRoomDesign1, hasCenterPillar: false),
                    3: MonumentReferenceRoomSignature(kind: .coreRoom, hasCenterPillar: false),
                    4: MonumentReferenceRoomSignature(kind: .doubleZRoom, hasCenterPillar: false),
                    5: MonumentReferenceRoomSignature(kind: .simpleRoomDesign0, hasCenterPillar: false),
                    6: MonumentReferenceRoomSignature(kind: .doubleXRoom, hasCenterPillar: false),
                    7: MonumentReferenceRoomSignature(kind: .doubleYRoom, hasCenterPillar: false),
                    8: MonumentReferenceRoomSignature(kind: .simpleRoomDesign2, hasCenterPillar: false),
                    9: MonumentReferenceRoomSignature(kind: .entryRoom, hasCenterPillar: false),
                    10: MonumentReferenceRoomSignature(kind: .simpleRoomDesign2, hasCenterPillar: false)
                ],
                worldSeed: worldSeed,
                startChunk: PosInt2D(x: blockX / 16, z: blockZ / 16),
                expectedExtraPieceCells: []
            )
        }

        let parts = line.components(separatedBy: ": ")
        precondition(parts.count == 2)
        labelsByTypeNumber[Int(parts[0])!] = parts[1].components(separatedBy: ", ")
    }

    fatalError("Missing seed line in monument reference")
}

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

private func matchingDisplayCells(
    for snapshot: OceanMonumentRoomPieceGraphSnapshot,
    expectedCells: Set<Set<OceanMonumentRoomCell>>,
    expectedExtraPieceCells: Set<Set<OceanMonumentRoomCell>>
) -> [Int: Set<OceanMonumentRoomCell>]? {
    var matches: [[Int: Set<OceanMonumentRoomCell>]] = []
    for flipX in [false, true] {
        for flipZ in [false, true] {
            let transformed = transformedDisplayCells(for: snapshot, flipX: flipX, flipZ: flipZ)
            let actualCells = Set(transformed.values)
            if expectedCells.subtracting(actualCells).isEmpty
                && actualCells.subtracting(expectedCells) == expectedExtraPieceCells
            {
                matches.append(transformed)
            }
        }
    }
    precondition(matches.count <= 1)
    return matches.first
}

@Test func testOceanMonumentBlockVolumeSamplerFallback() async throws {
    let bounds = BoundingBox(minX: 0, minY: 0, minZ: 0, maxX: 31, maxY: 31, maxZ: 31)
    let volume = StructureBlockVolume(bounds: bounds) { _ in
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
    #expect(pieceTypeNames(graphA.pieces) == pieceTypeNames(graphB.pieces))
    #expect(graphA.pieces.map(\.boundingBox) == graphB.pieces.map(\.boundingBox))
    #expect(graphA.pieces.map(\.orientation) == graphB.pieces.map(\.orientation))
    #expect(graphA.pieces.map(\.roomIndex) == graphB.pieces.map(\.roomIndex))
    #expect(graphA.pieces.count == 32)
    #expect(graphA.boundingBox == BoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
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
    #expect(result.graph.boundingBox == BoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
    #expect(result.blocks.allTouchedBlocks().count == 16547)
    #expect(
        result.markers == [
            StructureMarker(pos: PosInt3D(x: -17, y: 42, z: -12), represents: "minecraft:elder_guardian"),
            StructureMarker(pos: PosInt3D(x: 16, y: 45, z: -15), represents: "minecraft:elder_guardian"),
            StructureMarker(pos: PosInt3D(x: -1, y: 53, z: -1), represents: "minecraft:elder_guardian")
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

@Test func testOceanMonumentRoomPieceGraphMatchesReferenceFixtures() async throws {
    let references = [
        oldUserProvidedMonumentReference(),
        parseExpectedMonumentReference(try String(contentsOf: URL(filePath: "vanilla/monument_ref.txt"), encoding: .utf8))
    ]

    for expected in references {
        let snapshot = OceanMonument.generateRoomPieceGraph(
            worldSeed: expected.worldSeed,
            startChunk: expected.startChunk
        )
        let expectedCells = Set(expected.occupiedCellsByLabel.values)

        guard let transformed = matchingDisplayCells(
            for: snapshot,
            expectedCells: expectedCells,
            expectedExtraPieceCells: expected.expectedExtraPieceCells
        ) else {
            Issue.record("\(expected.name): monument reference letter grid does not match any display transform")
            continue
        }

        let matchedPieceRoomIndices = Set(
            transformed.compactMap { roomIndex, cells in
                expectedCells.contains(cells) ? roomIndex : nil
            }
        )
        let labelByRoomIndex: [Int: String] = Dictionary(uniqueKeysWithValues: transformed.compactMap { roomIndex, cells in
            guard let label = expected.occupiedCellsByLabel.first(where: { $0.value == cells })?.key else {
                return nil
            }
            return (roomIndex, label)
        })

        if !expected.expectedEdges.isEmpty {
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
                        return edge(label, connectedLabel)
                    }
                }.flatMap { $0 }
            )

            #expect(actualEdges == expected.expectedEdges)
        }

        guard let expectedTypeMapping = expected.expectedTypeMapping else {
            continue
        }

        let generated = OceanMonument.generate(
            worldSeed: expected.worldSeed,
            startChunk: expected.startChunk,
            context: oceanMonumentTestContext()
        )
        let pieceByLabel: [String: OceanMonumentRoomPieceSnapshot] = Dictionary(uniqueKeysWithValues: snapshot.pieces.compactMap { piece -> (String, OceanMonumentRoomPieceSnapshot)? in
            guard let label = labelByRoomIndex[piece.roomIndex] else {
                return nil
            }
            return (label, piece)
        })
        let graphPieceByRoomIndex: [Int: StructurePiece] = Dictionary(uniqueKeysWithValues: generated.graph.pieces.compactMap { piece -> (Int, StructurePiece)? in
            guard let roomIndex = piece.roomIndex else {
                return nil
            }
            return (roomIndex, piece)
        })

        #expect(Set(pieceByLabel.keys) == Set(expected.occupiedCellsByLabel.keys))

        let inferredMapping: [Int: MonumentReferenceRoomSignature] = Dictionary(uniqueKeysWithValues: expected.labelsByTypeNumber.keys.sorted().map { number in
            let signatures: Set<MonumentReferenceRoomSignature> = Set(expected.labelsByTypeNumber[number, default: []].compactMap { label in
                guard let snapshotPiece = pieceByLabel[label],
                      let graphPiece = graphPieceByRoomIndex[snapshotPiece.roomIndex]
                else {
                    return nil
                }
                return MonumentReferenceRoomSignature(
                    kind: snapshotPiece.kind,
                    hasCenterPillar: OceanMonument.pieceHasCenterPillar(graphPiece)
                )
            })
            #expect(signatures.count == 1)
            return (number, signatures.first!)
        })

        #expect(inferredMapping == expectedTypeMapping)
    }
}

@Test func testOceanMonumentOptionalCenterPillarIsEncodedInPlacementLogic() async throws {
    let context = oceanMonumentTestContext()

    // The handwritten fixture labels room V as "10" in one chunk image and "8" in another.
    // That does not require a code change here: the same design-2 room can be reprocessed with a
    // different chunk-local RNG state when vanilla runs piece post-processing per intersecting chunk.
    // This test checks the underlying feature directly on synthetic design-1/design-2 rooms that
    // satisfy the pillar preconditions, then forces the branch with a scripted RNG.
    func renderPiece<R: Random>(kind: OceanMonumentPieceKind, random: inout R) -> (hasCenterPillar: Bool, centerBlockID: String) {
        let piece = OceanMonument.makeCenterPillarTestPiece(kind: kind)
        let bounds = piece.boundingBox
        let volume = StructureBlockVolume(bounds: bounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY,
            volume: volume
        )
        piece.write(in: world, chunkBox: bounds, random: &random)

        let centerPos = piece.getWorldPos(3, 1, 3)
        return (OceanMonument.pieceHasCenterPillar(piece), volume.block(at: centerPos).type.id)
    }

    for kind in [OceanMonumentPieceKind.simpleRoomDesign1, .simpleRoomDesign2] {
        var pillarRandom = ScriptedRandom(nextValues: [0])
        let withPillar = renderPiece(kind: kind, random: &pillarRandom)
        var noPillarRandom = ScriptedRandom(nextValues: [1])
        let withoutPillar = renderPiece(kind: kind, random: &noPillarRandom)

        #expect(withPillar.hasCenterPillar)
        #expect(!withoutPillar.hasCenterPillar)
        #expect(withPillar.centerBlockID == "minecraft:prismarine_bricks")
        #expect(withoutPillar.centerBlockID == "minecraft:stone")
    }
}
