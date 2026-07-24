import Foundation

/// The public, inspectable piece graph for a monument.
///
/// The graph mirrors the vanilla piece layout:
/// - one root `monumentBuilding`
/// - a generated set of room pieces derived from the room graph
/// - two wing rooms
/// - one penthouse
///
/// Piece order matches generation order, which matters for overlapping writes.
public typealias OceanMonumentPieceGraph = PieceGraph

public typealias OceanMonumentGenerationContext = StructureGenerationContext

/// A room-grid coordinate within the monument's internal 5x3x5 room lattice.
///
/// This is independent of world orientation. It is the compact graph space that vanilla
/// uses before block generation expands merged rooms into concrete pieces.
struct OceanMonumentRoomCell: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// A test-facing snapshot of one room-derived monument piece.
///
/// `occupiedRoomCells` is the exact merged room footprint after the vanilla room-fitting pass.
/// `connectedPieceRoomIndices` contains neighboring room-derived pieces that remain reachable
/// through still-open room graph edges after random wall closure.
struct OceanMonumentRoomPieceSnapshot {
    let kind: OceanMonumentPieceKind
    let roomIndex: Int
    let occupiedRoomCells: Set<OceanMonumentRoomCell>
    let connectedPieceRoomIndices: Set<Int>
    let supportsCenterPillar: Bool
}

/// A test-facing projection of the merged room-piece graph.
struct OceanMonumentRoomPieceGraphSnapshot {
    let startChunk: PosInt2D
    let orientation: CardinalDirection
    let pieces: [OceanMonumentRoomPieceSnapshot]
}

/// One generated piece in the public graph view.
public typealias OceanMonumentGraphPiece = StructurePiece

public enum OceanMonumentPieceKind: String {
    case monumentBuilding
    case entryRoom
    case coreRoom
    case doubleXRoom
    case doubleXYRoom
    case doubleYRoom
    case doubleYZRoom
    case doubleZRoom
    case simpleRoomDesign0
    case simpleRoomDesign1
    case simpleRoomDesign2
    case simpleTopRoom
    case wingRoomDesign0
    case wingRoomDesign1
    case penthouse
}

/// The generated monument output.
///
/// `blocks` stores only the written structure blocks in a sparse, paletted, sectioned volume.
/// Reads fall back to the caller's `blockSampler`, which lets the monument renderer preserve
/// existing ice and stop support pillars on real terrain without copying an entire chunk region.
public struct OceanMonumentGenerationResult {
    public let graph: OceanMonumentPieceGraph
    public let blocks: StructureBlockVolume
    public let markers: [StructureMarker]
}

/// Namespace for monument generation.
///
/// Notes on fidelity:
/// - The piece graph and the piece-local block layouts are direct ports of the vanilla Java reference.
/// - The renderer intentionally keeps world context minimal and uses the caller's block sampler for reads.
/// - Vanilla structure piece `postProcess` receives a worldgen random tied to chunk decoration.
///   This code currently drives post-processing randomness from the monument's large-feature RNG stream.
///   That is enough to keep the generator deterministic and self-contained, but it is the main remaining place
///   where this implementation may diverge from a literal chunk-by-chunk vanilla execution.
///   In vanilla, chunk-local reprocessing can make optional room details such as center pillars disagree
///   across chunk boundaries when a room is split between multiple chunk `postProcess` calls.
public enum OceanMonument {
    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D) -> OceanMonumentPieceGraph {
        let root = makeRoot(worldSeed: worldSeed, startChunk: startChunk)
        return pieceGraph(from: root, startChunk: startChunk)
    }

    static func generateRoomPieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D) -> OceanMonumentRoomPieceGraphSnapshot {
        let root = makeRoot(worldSeed: worldSeed, startChunk: startChunk)
        return roomPieceGraph(from: root, startChunk: startChunk)
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> OceanMonumentGenerationResult {
        var random = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let root = MonumentBuilding(startChunk: startChunk, random: &random)
        let graph = pieceGraph(from: root, startChunk: startChunk)

        let writeBounds = expandedWriteBounds(for: root, minimumWorldY: context.minimumWorldY)
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY,
            volume: volume
        )
        root.write(in: world, chunkBox: writeBounds, random: &random)
        return OceanMonumentGenerationResult(
            graph: graph,
            blocks: volume,
            markers: world.markers
        )
    }

    private static func makeRoot(worldSeed: WorldSeed, startChunk: PosInt2D) -> MonumentBuilding {
        var random = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        return MonumentBuilding(startChunk: startChunk, random: &random)
    }

    private static func allPieces(from root: MonumentBuilding) -> [MonumentPiece] {
        [root] + root.childPieces
    }

    private static func combinedBounds(for root: MonumentBuilding) -> BoundingBox {
        allPieces(from: root).dropFirst().reduce(root.boundingBox) { partialResult, piece in
            partialResult.union(piece.boundingBox)
        }
    }

    private static func pieceGraph(from root: MonumentBuilding, startChunk: PosInt2D) -> OceanMonumentPieceGraph {
        return OceanMonumentPieceGraph(
            startChunk: startChunk,
            orientation: root.orientation,
            boundingBox: combinedBounds(for: root),
            pieces: allPieces(from: root)
        )
    }

    private static func expandedWriteBounds(for root: MonumentBuilding, minimumWorldY: Int32) -> BoundingBox {
        let union = combinedBounds(for: root)
        return BoundingBox(
            minX: union.minX - 5,
            minY: min(minimumWorldY + 1, union.minY - 1),
            minZ: union.minZ - 5,
            maxX: union.maxX + 5,
            maxY: union.maxY,
            maxZ: union.maxZ + 5
        )
    }

    private static func roomPieceGraph(from root: MonumentBuilding, startChunk: PosInt2D) -> OceanMonumentRoomPieceGraphSnapshot {
        let roomPieces = root.childPieces.filter { !$0.occupiedRooms.isEmpty }
        var roomIndexToRepresentative: [Int: Int] = [:]
        for piece in roomPieces {
            guard let roomIndex = piece.roomDefinition?.index else { continue }
            for room in piece.occupiedRooms where !room.isSpecial() {
                roomIndexToRepresentative[room.index] = roomIndex
            }
        }

        let pieces = roomPieces.compactMap { piece -> OceanMonumentRoomPieceSnapshot? in
            guard let roomIndex = piece.roomDefinition?.index else {
                return nil
            }
            let occupiedRoomCells = Set(
                piece.occupiedRooms
                    .filter { !$0.isSpecial() }
                    .map { roomCell(forRoomIndex: $0.index) }
            )
            var connectedPieceRoomIndices: Set<Int> = []
            for room in piece.occupiedRooms where !room.isSpecial() {
                for directionIndex in 0..<room.hasOpening.count {
                    guard room.hasOpening[directionIndex],
                          let connectedRoom = room.connections[directionIndex],
                          !connectedRoom.isSpecial(),
                          let connectedPieceRoomIndex = roomIndexToRepresentative[connectedRoom.index],
                          connectedPieceRoomIndex != roomIndex
                    else {
                        continue
                    }
                    connectedPieceRoomIndices.insert(connectedPieceRoomIndex)
                }
            }
            return OceanMonumentRoomPieceSnapshot(
                kind: pieceKind(for: piece),
                roomIndex: roomIndex,
                occupiedRoomCells: occupiedRoomCells,
                connectedPieceRoomIndices: connectedPieceRoomIndices,
                supportsCenterPillar: pieceSupportsCenterPillar(piece)
            )
        }

        return OceanMonumentRoomPieceGraphSnapshot(
            startChunk: startChunk,
            orientation: root.orientation,
            pieces: pieces.sorted { left, right in
                left.roomIndex < right.roomIndex
            }
        )
    }

    private static func roomCell(forRoomIndex roomIndex: Int) -> OceanMonumentRoomCell {
        OceanMonumentRoomCell(
            x: roomIndex % 5,
            y: roomIndex / 25,
            z: (roomIndex / 5) % 5
        )
    }

    private static func pieceKind(for piece: MonumentPiece) -> OceanMonumentPieceKind {
        switch piece {
        case is OceanMonumentEntryRoom:
            return .entryRoom
        case is OceanMonumentCoreRoom:
            return .coreRoom
        case is OceanMonumentDoubleXYRoom:
            return .doubleXYRoom
        case is OceanMonumentDoubleYZRoom:
            return .doubleYZRoom
        case is OceanMonumentDoubleXRoom:
            return .doubleXRoom
        case is OceanMonumentDoubleYRoom:
            return .doubleYRoom
        case is OceanMonumentDoubleZRoom:
            return .doubleZRoom
        case is OceanMonumentSimpleTopRoom:
            return .simpleTopRoom
        case is OceanMonumentSimpleRoomDesign0:
            return .simpleRoomDesign0
        case is OceanMonumentSimpleRoomDesign1:
            return .simpleRoomDesign1
        case is OceanMonumentSimpleRoomDesign2:
            return .simpleRoomDesign2
        case is OceanMonumentWingRoomDesign0:
            return .wingRoomDesign0
        case is OceanMonumentWingRoomDesign1:
            return .wingRoomDesign1
        case is OceanMonumentPenthouse:
            return .penthouse
        case is MonumentBuilding:
            return .monumentBuilding
        default:
            fatalError("Unknown monument piece type: \(type(of: piece))")
        }
    }

    static func pieceHasCenterPillar(_ piece: StructurePiece) -> Bool {
        (piece as? OceanMonumentSimpleRoomBase)?.hasCenterPillar ?? false
    }

    static func makeCenterPillarTestPiece(kind: OceanMonumentPieceKind) -> StructurePiece {
        let roomDefinition = RoomDefinition(index: 0)
        roomDefinition.hasOpening[LocalDirection.west.rawValue] = true
        roomDefinition.hasOpening[LocalDirection.east.rawValue] = true
        switch kind {
        case .simpleRoomDesign1:
            return OceanMonumentSimpleRoomDesign1(orientation: .north, definition: roomDefinition)
        case .simpleRoomDesign2:
            return OceanMonumentSimpleRoomDesign2(orientation: .north, definition: roomDefinition)
        default:
            preconditionFailure("Center pillar test piece only supports simple room designs 1 and 2")
        }
    }

    private static func pieceSupportsCenterPillar(_ piece: MonumentPiece) -> Bool {
        guard piece is OceanMonumentSimpleRoomWithOptionalPillar,
              let roomDefinition = piece.roomDefinition
        else {
            return false
        }
        return !roomDefinition.hasOpening[LocalDirection.down.rawValue]
            && !roomDefinition.hasOpening[LocalDirection.up.rawValue]
            && roomDefinition.countOpenings() > 1
    }
}

private final class RoomDefinition {
    let index: Int
    var connections: [RoomDefinition?] = Array(repeating: nil, count: 6)
    var hasOpening: [Bool] = Array(repeating: false, count: 6)
    var claimed = false
    var isSource = false
    var scanIndex = 0

    init(index: Int) {
        self.index = index
    }

    func setConnection(_ direction: LocalDirection, _ definition: RoomDefinition) {
        self.connections[direction.rawValue] = definition
        definition.connections[direction.opposite.rawValue] = self
    }

    func updateOpenings() {
        for i in 0..<6 {
            self.hasOpening[i] = self.connections[i] != nil
        }
    }

    func findSource(_ scanIndex: Int) -> Bool {
        if self.isSource {
            return true
        }
        self.scanIndex = scanIndex
        for i in 0..<6 {
            guard let connection = self.connections[i], self.hasOpening[i], connection.scanIndex != scanIndex else {
                continue
            }
            if connection.findSource(scanIndex) {
                return true
            }
        }
        return false
    }

    func isSpecial() -> Bool {
        self.index >= 75
    }

    func countOpenings() -> Int {
        self.hasOpening.reduce(into: 0) { partialResult, hasOpening in
            if hasOpening {
                partialResult += 1
            }
        }
    }
}

private protocol MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool
    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece
}

private struct FitDoubleXRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[LocalDirection.east.rawValue] && !(definition.connections[LocalDirection.east.rawValue]?.claimed ?? true)
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        definition.connections[LocalDirection.east.rawValue]?.claimed = true
        return OceanMonumentDoubleXRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleXYRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        guard definition.hasOpening[LocalDirection.east.rawValue],
              !(definition.connections[LocalDirection.east.rawValue]?.claimed ?? true),
              definition.hasOpening[LocalDirection.up.rawValue],
              !(definition.connections[LocalDirection.up.rawValue]?.claimed ?? true),
              let east = definition.connections[LocalDirection.east.rawValue]
        else {
            return false
        }
        return east.hasOpening[LocalDirection.up.rawValue] && !(east.connections[LocalDirection.up.rawValue]?.claimed ?? true)
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        definition.connections[LocalDirection.east.rawValue]?.claimed = true
        definition.connections[LocalDirection.up.rawValue]?.claimed = true
        definition.connections[LocalDirection.east.rawValue]?.connections[LocalDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleXYRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleYRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[LocalDirection.up.rawValue] && !(definition.connections[LocalDirection.up.rawValue]?.claimed ?? true)
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        definition.connections[LocalDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleYRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleYZRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        guard definition.hasOpening[LocalDirection.north.rawValue],
              !(definition.connections[LocalDirection.north.rawValue]?.claimed ?? true),
              definition.hasOpening[LocalDirection.up.rawValue],
              !(definition.connections[LocalDirection.up.rawValue]?.claimed ?? true),
              let north = definition.connections[LocalDirection.north.rawValue]
        else {
            return false
        }
        return north.hasOpening[LocalDirection.up.rawValue] && !(north.connections[LocalDirection.up.rawValue]?.claimed ?? true)
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        definition.connections[LocalDirection.north.rawValue]?.claimed = true
        definition.connections[LocalDirection.up.rawValue]?.claimed = true
        definition.connections[LocalDirection.north.rawValue]?.connections[LocalDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleYZRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleZRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[LocalDirection.north.rawValue] && !(definition.connections[LocalDirection.north.rawValue]?.claimed ?? true)
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        let source: RoomDefinition
        if !definition.hasOpening[LocalDirection.north.rawValue] || (definition.connections[LocalDirection.north.rawValue]?.claimed ?? true) {
            source = definition.connections[LocalDirection.south.rawValue]!
        } else {
            source = definition
        }
        source.claimed = true
        source.connections[LocalDirection.north.rawValue]?.claimed = true
        return OceanMonumentDoubleZRoom(orientation: orientation, definition: source)
    }
}

private struct FitSimpleRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool { true }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        return OceanMonumentSimpleRoomBase.create(orientation: orientation, definition: definition, random: &random)
    }
}

private struct FitSimpleTopRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        !definition.hasOpening[LocalDirection.west.rawValue]
            && !definition.hasOpening[LocalDirection.east.rawValue]
            && !definition.hasOpening[LocalDirection.north.rawValue]
            && !definition.hasOpening[LocalDirection.south.rawValue]
            && !definition.hasOpening[LocalDirection.up.rawValue]
    }

    func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        definition.claimed = true
        return OceanMonumentSimpleTopRoom(orientation: orientation, definition: definition)
    }
}

private class MonumentPiece: StructurePiece {
    static let baseGray = Blocks.prismarineState
    static let baseLight = Blocks.prismarineBricksState
    static let baseBlack = Blocks.darkPrismarineState
    static let dotDecoration = Blocks.prismarineBricksState
    static let lampBlock = Blocks.seaLanternState

    let roomDefinition: RoomDefinition?
    let occupiedRooms: [RoomDefinition]

    init(
        orientation: HorizontalDirection,
        boundingBox: BoundingBox,
        roomDefinition: RoomDefinition? = nil,
        occupiedRooms: [RoomDefinition] = []
    ) {
        self.roomDefinition = roomDefinition
        self.occupiedRooms = occupiedRooms
        super.init(
            orientation: orientation.publicValue,
            boundingBox: boundingBox,
            roomIndex: roomDefinition?.index
        )
    }

    init(
        orientation: HorizontalDirection,
        roomDefinition: RoomDefinition,
        occupiedRooms: [RoomDefinition]? = nil,
        roomWidth: Int32,
        roomHeight: Int32,
        roomDepth: Int32
    ) {
        self.roomDefinition = roomDefinition
        self.occupiedRooms = occupiedRooms ?? [roomDefinition]
        super.init(
            orientation: orientation.publicValue,
            boundingBox: MonumentPiece.roomBoundingBox(
                orientation: orientation,
                roomDefinition: roomDefinition,
                roomWidth: roomWidth,
                roomHeight: roomHeight,
                roomDepth: roomDepth
            ),
            roomIndex: roomDefinition.index
        )
    }

    class func roomBoundingBox(
        orientation: HorizontalDirection,
        roomDefinition: RoomDefinition,
        roomWidth: Int32,
        roomHeight: Int32,
        roomDepth: Int32
    ) -> BoundingBox {
        let roomIndex = roomDefinition.index
        let roomX = Int32(roomIndex % 5)
        let roomZ = Int32((roomIndex / 5) % 5)
        let roomY = Int32(roomIndex / 25)
        var box = makeBoundingBox(
            x: 0,
            y: 0,
            z: 0,
            orientation: orientation,
            width: roomWidth * 8,
            height: roomHeight * 4,
            depth: roomDepth * 8
        )
        switch orientation {
        case .north:
            box.move(roomX * 8, roomY * 4, -(roomZ + roomDepth) * 8 + 1)
        case .south:
            box.move(roomX * 8, roomY * 4, roomZ * 8)
        case .west:
            box.move(-(roomZ + roomDepth) * 8 + 1, roomY * 4, roomX * 8)
        case .east:
            box.move(roomZ * 8, roomY * 4, roomX * 8)
        }
        return box
    }

    func generateDefaultFloor(_ world: StructureWorldView, _ chunkBox: BoundingBox, _ xOff: Int32, _ zOff: Int32, _ downOpening: Bool) {
        if downOpening {
            self.generateBox(world, chunkBox, xOff + 0, 0, zOff + 0, xOff + 2, 0, zOff + 7, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xOff + 5, 0, zOff + 0, xOff + 7, 0, zOff + 7, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xOff + 3, 0, zOff + 0, xOff + 4, 0, zOff + 2, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xOff + 3, 0, zOff + 5, xOff + 4, 0, zOff + 7, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xOff + 3, 0, zOff + 2, xOff + 4, 0, zOff + 2, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, xOff + 3, 0, zOff + 5, xOff + 4, 0, zOff + 5, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, xOff + 2, 0, zOff + 3, xOff + 2, 0, zOff + 4, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, xOff + 5, 0, zOff + 3, xOff + 5, 0, zOff + 4, Self.baseLight, Self.baseLight)
        } else {
            self.generateBox(world, chunkBox, xOff + 0, 0, zOff + 0, xOff + 7, 0, zOff + 7, Self.baseGray, Self.baseGray)
        }
    }
}

private final class MonumentBuilding: MonumentPiece {
    static let biomeRangeCheck = 29
    var sourceRoom: RoomDefinition
    var coreRoom: RoomDefinition
    var childPieces: [MonumentPiece] = []

    init<R: Random>(startChunk: PosInt2D, random: inout R) {
        let orientation = HorizontalDirection.random(using: &random)
        let west = startChunk.x * 16 - 29
        let north = startChunk.z * 16 - 29
        let box = makeBoundingBox(x: west, y: 39, z: north, orientation: orientation, width: 58, height: 23, depth: 58)

        var sourceRoomRef: RoomDefinition?
        var coreRoomRef: RoomDefinition?
        self.sourceRoom = RoomDefinition(index: 0)
        self.coreRoom = RoomDefinition(index: 0)
        super.init(orientation: orientation, boundingBox: box)

        let roomDefinitions = MonumentBuilding.generateRoomGraph(random: &random, sourceRoom: &sourceRoomRef, coreRoom: &coreRoomRef)
        self.sourceRoom = sourceRoomRef!
        self.coreRoom = coreRoomRef!
        self.sourceRoom.claimed = true
        self.childPieces.append(OceanMonumentEntryRoom(orientation: orientation, definition: self.sourceRoom))
        self.childPieces.append(OceanMonumentCoreRoom(orientation: orientation, definition: self.coreRoom))

        let fitters: [MonumentRoomFitter] = [
            FitDoubleXYRoom(),
            FitDoubleYZRoom(),
            FitDoubleZRoom(),
            FitDoubleXRoom(),
            FitDoubleYRoom(),
            FitSimpleTopRoom(),
            FitSimpleRoom()
        ]

        for definition in roomDefinitions where !definition.claimed && !definition.isSpecial() {
            for fitter in fitters where fitter.fits(definition) {
                self.childPieces.append(fitter.create(orientation: orientation, definition: definition, random: &random))
                break
            }
        }

        let offset = self.getWorldPos(9, 0, 22)
        for child in self.childPieces {
            child.boundingBox.move(offset.x, offset.y, offset.z)
        }

        let leftWing = BoundingBox.fromCorners(self.getWorldPos(1, 1, 1), self.getWorldPos(23, 8, 21))
        let rightWing = BoundingBox.fromCorners(self.getWorldPos(34, 1, 1), self.getWorldPos(56, 8, 21))
        let penthouse = BoundingBox.fromCorners(self.getWorldPos(22, 13, 22), self.getWorldPos(35, 17, 35))
        var wingRandom = random.nextInt32()
        self.childPieces.append(OceanMonumentWingRoomBase.create(orientation: orientation, boundingBox: leftWing, randomValue: wingRandom))
        wingRandom += 1
        self.childPieces.append(OceanMonumentWingRoomBase.create(orientation: orientation, boundingBox: rightWing, randomValue: wingRandom))
        self.childPieces.append(OceanMonumentPenthouse(orientation: orientation, boundingBox: penthouse))
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let waterHeight = max(world.seaLevel, 64) - self.boundingBox.minY
        self.generateWaterBox(world, chunkBox, 0, 0, 0, 58, waterHeight, 58)
        self.generateWing(false, 0, world, chunkBox)
        self.generateWing(true, 33, world, chunkBox)
        self.generateEntranceArchs(world, chunkBox)
        self.generateEntranceWall(world, chunkBox)
        self.generateRoofPiece(world, chunkBox)
        self.generateLowerWall(world, chunkBox)
        self.generateMiddleWall(world, chunkBox)
        self.generateUpperWall(world, chunkBox)

        for pillarX in 0..<7 {
            var pillarZ = 0
            while pillarZ < 7 {
                if pillarZ == 0 && pillarX == 3 {
                    pillarZ = 6
                }
                let bx = Int32(pillarX * 9)
                let bz = Int32(pillarZ * 9)
                for w in 0..<4 {
                    for d in 0..<4 {
                        self.placeBlock(world, Self.baseLight, bx + Int32(w), 0, bz + Int32(d), chunkBox)
                        self.fillColumnDown(world, Self.baseLight, bx + Int32(w), -1, bz + Int32(d), chunkBox)
                    }
                }
                pillarZ += (pillarX != 0 && pillarX != 6) ? 6 : 1
            }
        }

        for i in 0..<5 {
            let ii = Int32(i)
            self.generateWaterBox(world, chunkBox, -1 - ii, ii * 2, -1 - ii, -1 - ii, 23, 58 + ii)
            self.generateWaterBox(world, chunkBox, 58 + ii, ii * 2, -1 - ii, 58 + ii, 23, 58 + ii)
            self.generateWaterBox(world, chunkBox, 0 - ii, ii * 2, -1 - ii, 57 + ii, 23, -1 - ii)
            self.generateWaterBox(world, chunkBox, 0 - ii, ii * 2, 58 + ii, 57 + ii, 23, 58 + ii)
        }

        for child in self.childPieces where child.boundingBox.intersects(chunkBox) {
            child.write(in: world, chunkBox: chunkBox, random: &random)
        }
    }

    private static func generateRoomGraph<R: Random>(random: inout R, sourceRoom: inout RoomDefinition?, coreRoom: inout RoomDefinition?) -> [RoomDefinition] {
        var roomGrid: [RoomDefinition?] = Array(repeating: nil, count: 75)

        for x in 0..<5 {
            for z in 0..<4 {
                let pos = Self.getRoomIndex(roomX: x, roomY: 0, roomZ: z)
                roomGrid[pos] = RoomDefinition(index: pos)
            }
        }
        for x in 0..<5 {
            for z in 0..<4 {
                let pos = Self.getRoomIndex(roomX: x, roomY: 1, roomZ: z)
                roomGrid[pos] = RoomDefinition(index: pos)
            }
        }
        for x in 1..<4 {
            for z in 0..<2 {
                let pos = Self.getRoomIndex(roomX: x, roomY: 2, roomZ: z)
                roomGrid[pos] = RoomDefinition(index: pos)
            }
        }

        sourceRoom = roomGrid[Self.gridRoomSourceIndex]!

        for x in 0..<5 {
            for z in 0..<5 {
                for y in 0..<3 {
                    let pos = Self.getRoomIndex(roomX: x, roomY: y, roomZ: z)
                    guard let room = roomGrid[pos] else { continue }
                    for direction in LocalDirection.allCases {
                        let neighX = x + Int(direction.stepX)
                        let neighY = y + Int(direction.stepY)
                        let neighZ = z + Int(direction.stepZ)
                        guard neighX >= 0, neighX < 5, neighY >= 0, neighY < 3, neighZ >= 0, neighZ < 5 else { continue }
                        let neighPos = Self.getRoomIndex(roomX: neighX, roomY: neighY, roomZ: neighZ)
                        guard let neigh = roomGrid[neighPos] else { continue }
                        if neighZ == z {
                            room.setConnection(direction, neigh)
                        } else {
                            room.setConnection(direction.opposite, neigh)
                        }
                    }
                }
            }
        }

        let roofRoom = RoomDefinition(index: 1003)
        let leftWing = RoomDefinition(index: 1001)
        let rightWing = RoomDefinition(index: 1002)
        roomGrid[Self.gridRoomTopConnectIndex]!.setConnection(.up, roofRoom)
        roomGrid[Self.gridRoomLeftWingConnectIndex]!.setConnection(.south, leftWing)
        roomGrid[Self.gridRoomRightWingConnectIndex]!.setConnection(.south, rightWing)
        roofRoom.claimed = true
        leftWing.claimed = true
        rightWing.claimed = true
        sourceRoom!.isSource = true

        let core = roomGrid[Self.getRoomIndex(roomX: Int(random.next(bound: 4)), roomY: 0, roomZ: 2)]!
        coreRoom = core
        core.claimed = true
        core.connections[LocalDirection.east.rawValue]!.claimed = true
        core.connections[LocalDirection.north.rawValue]!.claimed = true
        core.connections[LocalDirection.east.rawValue]!.connections[LocalDirection.north.rawValue]!.claimed = true
        core.connections[LocalDirection.up.rawValue]!.claimed = true
        core.connections[LocalDirection.east.rawValue]!.connections[LocalDirection.up.rawValue]!.claimed = true
        core.connections[LocalDirection.north.rawValue]!.connections[LocalDirection.up.rawValue]!.claimed = true
        core.connections[LocalDirection.east.rawValue]!.connections[LocalDirection.north.rawValue]!.connections[LocalDirection.up.rawValue]!.claimed = true

        var roomDefs: [RoomDefinition] = []
        for definition in roomGrid.compactMap({ $0 }) {
            definition.updateOpenings()
            roomDefs.append(definition)
        }
        roofRoom.updateOpenings()
        monumentShuffle(&roomDefs, random: &random)

        var scanIndex = 1
        for definition in roomDefs {
            var closeCount = 0
            var attemptCount = 0
            while closeCount < 2 && attemptCount < 5 {
                attemptCount += 1
                let f = Int(random.next(bound: 6))
                if definition.hasOpening[f] {
                    let of = LocalDirection(rawValue: f)!.opposite.rawValue
                    definition.hasOpening[f] = false
                    definition.connections[f]!.hasOpening[of] = false
                    if definition.findSource(scanIndex) && definition.connections[f]!.findSource(scanIndex + 1) {
                        closeCount += 1
                        scanIndex += 2
                    } else {
                        definition.hasOpening[f] = true
                        definition.connections[f]!.hasOpening[of] = true
                        scanIndex += 2
                    }
                }
            }
        }

        roomDefs.append(roofRoom)
        roomDefs.append(leftWing)
        roomDefs.append(rightWing)
        return roomDefs
    }

    private static func getRoomIndex(roomX: Int, roomY: Int, roomZ: Int) -> Int {
        roomY * 25 + roomZ * 5 + roomX
    }

    private static let gridRoomSourceIndex = getRoomIndex(roomX: 2, roomY: 0, roomZ: 0)
    private static let gridRoomTopConnectIndex = getRoomIndex(roomX: 2, roomY: 2, roomZ: 0)
    private static let gridRoomLeftWingConnectIndex = getRoomIndex(roomX: 0, roomY: 1, roomZ: 0)
    private static let gridRoomRightWingConnectIndex = getRoomIndex(roomX: 4, roomY: 1, roomZ: 0)

    private func generateWing(_ isFlipped: Bool, _ xoff: Int32, _ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, xoff, 0, xoff + 23, 20) {
            self.generateBox(world, chunkBox, xoff + 0, 0, 0, xoff + 24, 0, 20, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, xoff + 0, 1, 0, xoff + 24, 10, 20)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, xoff + ii, ii + 1, ii, xoff + ii, ii + 1, 20, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, xoff + ii + 7, ii + 5, ii + 7, xoff + ii + 7, ii + 5, 20, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, xoff + 17 - ii, ii + 5, ii + 7, xoff + 17 - ii, ii + 5, 20, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, xoff + 24 - ii, ii + 1, ii, xoff + 24 - ii, ii + 1, 20, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, xoff + ii + 1, ii + 1, ii, xoff + 23 - ii, ii + 1, ii, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, xoff + ii + 8, ii + 5, ii + 7, xoff + 16 - ii, ii + 5, ii + 7, Self.baseLight, Self.baseLight)
            }
            self.generateBox(world, chunkBox, xoff + 4, 4, 4, xoff + 6, 4, 20, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xoff + 7, 4, 4, xoff + 17, 4, 6, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xoff + 18, 4, 4, xoff + 20, 4, 20, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xoff + 11, 8, 11, xoff + 13, 8, 20, Self.baseGray, Self.baseGray)
            self.placeBlock(world, Self.dotDecoration, xoff + 12, 9, 12, chunkBox)
            self.placeBlock(world, Self.dotDecoration, xoff + 12, 9, 15, chunkBox)
            self.placeBlock(world, Self.dotDecoration, xoff + 12, 9, 18, chunkBox)
            let leftPos = xoff + (isFlipped ? 19 : 5)
            let rightPos = xoff + (isFlipped ? 5 : 19)
            var z: Int32 = 20
            while z >= 5 {
                self.placeBlock(world, Self.dotDecoration, leftPos, 5, z, chunkBox)
                z -= 3
            }
            z = 19
            while z >= 7 {
                self.placeBlock(world, Self.dotDecoration, rightPos, 5, z, chunkBox)
                z -= 3
            }
            for i in 0..<4 {
                let pos = isFlipped ? xoff + 24 - (17 - Int32(i * 3)) : xoff + 17 - Int32(i * 3)
                self.placeBlock(world, Self.dotDecoration, pos, 5, 5, chunkBox)
            }
            self.placeBlock(world, Self.dotDecoration, rightPos, 5, 5, chunkBox)
            self.generateBox(world, chunkBox, xoff + 11, 1, 12, xoff + 13, 7, 12, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, xoff + 12, 1, 11, xoff + 12, 7, 13, Self.baseGray, Self.baseGray)
        }
    }

    private func generateEntranceArchs(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 22, 5, 35, 17) {
            self.generateWaterBox(world, chunkBox, 25, 0, 0, 32, 8, 20)
            for i in 0..<4 {
                let z = 5 + Int32(i * 4)
                self.generateBox(world, chunkBox, 24, 2, z, 24, 4, z, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 22, 4, z, 23, 4, z, Self.baseLight, Self.baseLight)
                self.placeBlock(world, Self.baseLight, 25, 5, z, chunkBox)
                self.placeBlock(world, Self.baseLight, 26, 6, z, chunkBox)
                self.placeBlock(world, Self.lampBlock, 26, 5, z, chunkBox)
                self.generateBox(world, chunkBox, 33, 2, z, 33, 4, z, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 34, 4, z, 35, 4, z, Self.baseLight, Self.baseLight)
                self.placeBlock(world, Self.baseLight, 32, 5, z, chunkBox)
                self.placeBlock(world, Self.baseLight, 31, 6, z, chunkBox)
                self.placeBlock(world, Self.lampBlock, 31, 5, z, chunkBox)
                self.generateBox(world, chunkBox, 27, 6, z, 30, 6, z, Self.baseGray, Self.baseGray)
            }
        }
    }

    private func generateEntranceWall(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 15, 20, 42, 21) {
            self.generateBox(world, chunkBox, 15, 0, 21, 42, 0, 21, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 26, 1, 21, 31, 3, 21)
            self.generateBox(world, chunkBox, 21, 12, 21, 36, 12, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 17, 11, 21, 40, 11, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 16, 10, 21, 41, 10, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 15, 7, 21, 42, 9, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 16, 6, 21, 41, 6, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 17, 5, 21, 40, 5, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 21, 4, 21, 36, 4, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 22, 3, 21, 26, 3, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 31, 3, 21, 35, 3, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 23, 2, 21, 25, 2, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 32, 2, 21, 34, 2, 21, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 28, 4, 20, 29, 4, 21, Self.baseLight, Self.baseLight)
            self.placeBlock(world, Self.baseLight, 27, 3, 21, chunkBox)
            self.placeBlock(world, Self.baseLight, 30, 3, 21, chunkBox)
            self.placeBlock(world, Self.baseLight, 26, 2, 21, chunkBox)
            self.placeBlock(world, Self.baseLight, 31, 2, 21, chunkBox)
            self.placeBlock(world, Self.baseLight, 25, 1, 21, chunkBox)
            self.placeBlock(world, Self.baseLight, 32, 1, 21, chunkBox)
            for i in 0..<7 {
                let ii = Int32(i)
                self.placeBlock(world, Self.baseBlack, 28 - ii, 6 + ii, 21, chunkBox)
                self.placeBlock(world, Self.baseBlack, 29 + ii, 6 + ii, 21, chunkBox)
            }
            for i in 0..<4 {
                let ii = Int32(i)
                self.placeBlock(world, Self.baseBlack, 28 - ii, 9 + ii, 21, chunkBox)
                self.placeBlock(world, Self.baseBlack, 29 + ii, 9 + ii, 21, chunkBox)
            }
            self.placeBlock(world, Self.baseBlack, 28, 12, 21, chunkBox)
            self.placeBlock(world, Self.baseBlack, 29, 12, 21, chunkBox)
            for i in 0..<3 {
                let ii = Int32(i * 2)
                self.placeBlock(world, Self.baseBlack, 22 - ii, 8, 21, chunkBox)
                self.placeBlock(world, Self.baseBlack, 22 - ii, 9, 21, chunkBox)
                self.placeBlock(world, Self.baseBlack, 35 + ii, 8, 21, chunkBox)
                self.placeBlock(world, Self.baseBlack, 35 + ii, 9, 21, chunkBox)
            }
            self.generateWaterBox(world, chunkBox, 15, 13, 21, 42, 15, 21)
            self.generateWaterBox(world, chunkBox, 15, 1, 21, 15, 6, 21)
            self.generateWaterBox(world, chunkBox, 16, 1, 21, 16, 5, 21)
            self.generateWaterBox(world, chunkBox, 17, 1, 21, 20, 4, 21)
            self.generateWaterBox(world, chunkBox, 21, 1, 21, 21, 3, 21)
            self.generateWaterBox(world, chunkBox, 22, 1, 21, 22, 2, 21)
            self.generateWaterBox(world, chunkBox, 23, 1, 21, 24, 1, 21)
            self.generateWaterBox(world, chunkBox, 42, 1, 21, 42, 6, 21)
            self.generateWaterBox(world, chunkBox, 41, 1, 21, 41, 5, 21)
            self.generateWaterBox(world, chunkBox, 37, 1, 21, 40, 4, 21)
            self.generateWaterBox(world, chunkBox, 36, 1, 21, 36, 3, 21)
            self.generateWaterBox(world, chunkBox, 33, 1, 21, 34, 1, 21)
            self.generateWaterBox(world, chunkBox, 35, 1, 21, 35, 2, 21)
        }
    }

    private func generateRoofPiece(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 21, 21, 36, 36) {
            self.generateBox(world, chunkBox, 21, 0, 22, 36, 0, 36, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 21, 1, 22, 36, 23, 36)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 21 + ii, 13 + ii, 21 + ii, 36 - ii, 13 + ii, 21 + ii, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 21 + ii, 13 + ii, 36 - ii, 36 - ii, 13 + ii, 36 - ii, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 21 + ii, 13 + ii, 22 + ii, 21 + ii, 13 + ii, 35 - ii, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 36 - ii, 13 + ii, 22 + ii, 36 - ii, 13 + ii, 35 - ii, Self.baseLight, Self.baseLight)
            }
            self.generateBox(world, chunkBox, 25, 16, 25, 32, 16, 32, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 25, 17, 25, 25, 19, 25, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 32, 17, 25, 32, 19, 25, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 25, 17, 32, 25, 19, 32, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 32, 17, 32, 32, 19, 32, Self.baseLight, Self.baseLight)
            self.placeBlock(world, Self.baseLight, 26, 20, 26, chunkBox)
            self.placeBlock(world, Self.baseLight, 27, 21, 27, chunkBox)
            self.placeBlock(world, Self.lampBlock, 27, 20, 27, chunkBox)
            self.placeBlock(world, Self.baseLight, 26, 20, 31, chunkBox)
            self.placeBlock(world, Self.baseLight, 27, 21, 30, chunkBox)
            self.placeBlock(world, Self.lampBlock, 27, 20, 30, chunkBox)
            self.placeBlock(world, Self.baseLight, 31, 20, 31, chunkBox)
            self.placeBlock(world, Self.baseLight, 30, 21, 30, chunkBox)
            self.placeBlock(world, Self.lampBlock, 30, 20, 30, chunkBox)
            self.placeBlock(world, Self.baseLight, 31, 20, 26, chunkBox)
            self.placeBlock(world, Self.baseLight, 30, 21, 27, chunkBox)
            self.placeBlock(world, Self.lampBlock, 30, 20, 27, chunkBox)
            self.generateBox(world, chunkBox, 28, 21, 27, 29, 21, 27, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 27, 21, 28, 27, 21, 29, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 28, 21, 30, 29, 21, 30, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 30, 21, 28, 30, 21, 29, Self.baseGray, Self.baseGray)
        }
    }

    private func generateLowerWall(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 0, 21, 6, 58) {
            self.generateBox(world, chunkBox, 0, 0, 21, 6, 0, 57, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 0, 1, 21, 6, 7, 57)
            self.generateBox(world, chunkBox, 4, 4, 21, 6, 4, 53, Self.baseGray, Self.baseGray)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, ii, ii + 1, 21, ii, ii + 1, 57 - ii, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(23), to: Int32(53), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 5, 5, z, chunkBox)
            }
            self.placeBlock(world, Self.dotDecoration, 5, 5, 52, chunkBox)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, ii, ii + 1, 21, ii, ii + 1, 57 - ii, Self.baseLight, Self.baseLight)
            }
            self.generateBox(world, chunkBox, 4, 1, 52, 6, 3, 52, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 5, 1, 51, 5, 3, 53, Self.baseGray, Self.baseGray)
        }
        if self.chunkIntersects(chunkBox, 51, 21, 58, 58) {
            self.generateBox(world, chunkBox, 51, 0, 21, 57, 0, 57, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 51, 1, 21, 57, 7, 57)
            self.generateBox(world, chunkBox, 51, 4, 21, 53, 4, 53, Self.baseGray, Self.baseGray)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 57 - ii, ii + 1, 21, 57 - ii, ii + 1, 57 - ii, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(23), to: Int32(53), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 52, 5, z, chunkBox)
            }
            self.placeBlock(world, Self.dotDecoration, 52, 5, 52, chunkBox)
            self.generateBox(world, chunkBox, 51, 1, 52, 53, 3, 52, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 52, 1, 51, 52, 3, 53, Self.baseGray, Self.baseGray)
        }
        if self.chunkIntersects(chunkBox, 0, 51, 57, 57) {
            self.generateBox(world, chunkBox, 7, 0, 51, 50, 0, 57, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 7, 1, 51, 50, 10, 57)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, ii + 1, ii + 1, 57 - ii, 56 - ii, ii + 1, 57 - ii, Self.baseLight, Self.baseLight)
            }
        }
    }

    private func generateMiddleWall(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 7, 21, 13, 50) {
            self.generateBox(world, chunkBox, 7, 0, 21, 13, 0, 50, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 7, 1, 21, 13, 10, 50)
            self.generateBox(world, chunkBox, 11, 8, 21, 13, 8, 53, Self.baseGray, Self.baseGray)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, ii + 7, ii + 5, 21, ii + 7, ii + 5, 54, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(21), through: Int32(45), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 12, 9, z, chunkBox)
            }
        }
        if self.chunkIntersects(chunkBox, 44, 21, 50, 54) {
            self.generateBox(world, chunkBox, 44, 0, 21, 50, 0, 50, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 44, 1, 21, 50, 10, 50)
            self.generateBox(world, chunkBox, 44, 8, 21, 46, 8, 53, Self.baseGray, Self.baseGray)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 50 - ii, ii + 5, 21, 50 - ii, ii + 5, 54, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(21), through: Int32(45), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 45, 9, z, chunkBox)
            }
        }
        if self.chunkIntersects(chunkBox, 8, 44, 49, 54) {
            self.generateBox(world, chunkBox, 14, 0, 44, 43, 0, 50, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 14, 1, 44, 43, 10, 50)
            for x in stride(from: Int32(12), through: Int32(45), by: 3) {
                self.placeBlock(world, Self.dotDecoration, x, 9, 45, chunkBox)
                self.placeBlock(world, Self.dotDecoration, x, 9, 52, chunkBox)
                if x == 12 || x == 18 || x == 24 || x == 33 || x == 39 || x == 45 {
                    self.placeBlock(world, Self.dotDecoration, x, 9, 47, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 9, 50, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 10, 45, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 10, 46, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 10, 51, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 10, 52, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 11, 47, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 11, 50, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 12, 48, chunkBox)
                    self.placeBlock(world, Self.dotDecoration, x, 12, 49, chunkBox)
                }
            }
            for i in 0..<3 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 8 + ii, 5 + ii, 54, 49 - ii, 5 + ii, 54, Self.baseGray, Self.baseGray)
            }
            self.generateBox(world, chunkBox, 11, 8, 54, 46, 8, 54, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 14, 8, 44, 43, 8, 53, Self.baseGray, Self.baseGray)
        }
    }

    private func generateUpperWall(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        if self.chunkIntersects(chunkBox, 14, 21, 20, 43) {
            self.generateBox(world, chunkBox, 14, 0, 21, 20, 0, 43, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 14, 1, 22, 20, 14, 43)
            self.generateBox(world, chunkBox, 18, 12, 22, 20, 12, 39, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 18, 12, 21, 20, 12, 21, Self.baseLight, Self.baseLight)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, ii + 14, ii + 9, 21, ii + 14, ii + 9, 43 - ii, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(23), through: Int32(39), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 19, 13, z, chunkBox)
            }
        }
        if self.chunkIntersects(chunkBox, 37, 21, 43, 43) {
            self.generateBox(world, chunkBox, 37, 0, 21, 43, 0, 43, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 37, 1, 22, 43, 14, 43)
            self.generateBox(world, chunkBox, 37, 12, 22, 39, 12, 39, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 37, 12, 21, 39, 12, 21, Self.baseLight, Self.baseLight)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 43 - ii, ii + 9, 21, 43 - ii, ii + 9, 43 - ii, Self.baseLight, Self.baseLight)
            }
            for z in stride(from: Int32(23), through: Int32(39), by: 3) {
                self.placeBlock(world, Self.dotDecoration, 38, 13, z, chunkBox)
            }
        }
        if self.chunkIntersects(chunkBox, 15, 37, 42, 43) {
            self.generateBox(world, chunkBox, 21, 0, 37, 36, 0, 43, Self.baseGray, Self.baseGray)
            self.generateWaterBox(world, chunkBox, 21, 1, 37, 36, 14, 43)
            self.generateBox(world, chunkBox, 21, 12, 37, 36, 12, 39, Self.baseGray, Self.baseGray)
            for i in 0..<4 {
                let ii = Int32(i)
                self.generateBox(world, chunkBox, 15 + ii, ii + 9, 43 - ii, 42 - ii, ii + 9, 43 - ii, Self.baseLight, Self.baseLight)
            }
            for x in stride(from: Int32(21), through: Int32(36), by: 3) {
                self.placeBlock(world, Self.dotDecoration, x, 13, 38, chunkBox)
            }
        }
    }
}

private final class OceanMonumentCoreRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        let east = definition.connections[LocalDirection.east.rawValue]!
        let north = definition.connections[LocalDirection.north.rawValue]!
        let up = definition.connections[LocalDirection.up.rawValue]!
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [
                definition,
                east,
                north,
                east.connections[LocalDirection.north.rawValue]!,
                up,
                east.connections[LocalDirection.up.rawValue]!,
                north.connections[LocalDirection.up.rawValue]!,
                east.connections[LocalDirection.north.rawValue]!.connections[LocalDirection.up.rawValue]!
            ],
            roomWidth: 2,
            roomHeight: 2,
            roomDepth: 2
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 0, 14, 8, 14, Self.baseGray)
        self.generateBox(world, chunkBox, 0, 7, 0, 0, 7, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 15, 7, 0, 15, 7, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 7, 0, 15, 7, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 7, 15, 14, 7, 15, Self.baseLight, Self.baseLight)
        for y in 1...6 {
            let block = (y == 2 || y == 6) ? Self.baseGray : Self.baseLight
            for x in [0, 15] {
                self.generateBox(world, chunkBox, Int32(x), Int32(y), 0, Int32(x), Int32(y), 1, block, block)
                self.generateBox(world, chunkBox, Int32(x), Int32(y), 6, Int32(x), Int32(y), 9, block, block)
                self.generateBox(world, chunkBox, Int32(x), Int32(y), 14, Int32(x), Int32(y), 15, block, block)
            }
            self.generateBox(world, chunkBox, 1, Int32(y), 0, 1, Int32(y), 0, block, block)
            self.generateBox(world, chunkBox, 6, Int32(y), 0, 9, Int32(y), 0, block, block)
            self.generateBox(world, chunkBox, 14, Int32(y), 0, 14, Int32(y), 0, block, block)
            self.generateBox(world, chunkBox, 1, Int32(y), 15, 14, Int32(y), 15, block, block)
        }
        self.generateBox(world, chunkBox, 6, 3, 6, 9, 6, 9, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 7, 4, 7, 8, 5, 8, Blocks.goldBlockState, Blocks.goldBlockState)
        for y in stride(from: Int32(3), through: Int32(6), by: 3) {
            for x in stride(from: Int32(6), through: Int32(9), by: 3) {
                self.placeBlock(world, Self.lampBlock, x, y, 6, chunkBox)
                self.placeBlock(world, Self.lampBlock, x, y, 9, chunkBox)
            }
        }
        self.generateBox(world, chunkBox, 5, 1, 6, 5, 2, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 9, 5, 2, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 1, 6, 10, 2, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 1, 9, 10, 2, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 5, 6, 2, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 1, 5, 9, 2, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 10, 6, 2, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 1, 10, 9, 2, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 2, 5, 5, 6, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 2, 10, 5, 6, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 2, 5, 10, 6, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 2, 10, 10, 6, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 7, 1, 5, 7, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 7, 1, 10, 7, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 7, 9, 5, 7, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 7, 9, 10, 7, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 7, 5, 6, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 7, 10, 6, 7, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 7, 5, 14, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 7, 10, 14, 7, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 1, 2, 2, 1, 3, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 1, 2, 3, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 1, 2, 13, 1, 3, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 12, 1, 2, 12, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 1, 12, 2, 1, 13, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 1, 13, 3, 1, 13, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 1, 12, 13, 1, 13, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 12, 1, 13, 12, 1, 13, Self.baseLight, Self.baseLight)
    }
}

private final class OceanMonumentDoubleXRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [definition, definition.connections[LocalDirection.east.rawValue]!],
            roomWidth: 2,
            roomHeight: 1,
            roomDepth: 1
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let east = self.roomDefinition!.connections[LocalDirection.east.rawValue]!
        let west = self.roomDefinition!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 8, 0, east.hasOpening[LocalDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, west.hasOpening[LocalDirection.down.rawValue])
        }
        if west.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 7, 4, 6, Self.baseGray)
        }
        if east.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 8, 4, 1, 14, 4, 6, Self.baseGray)
        }
        self.generateBox(world, chunkBox, 0, 3, 0, 0, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 15, 3, 0, 15, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 0, 15, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 7, 14, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 0, 2, 7, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 15, 2, 0, 15, 2, 7, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 0, 15, 2, 0, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 7, 14, 2, 7, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 15, 1, 0, 15, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 15, 1, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 7, 14, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 0, 10, 1, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 2, 0, 9, 2, 3, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 5, 3, 0, 10, 3, 4, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.lampBlock, 6, 2, 3, chunkBox)
        self.placeBlock(world, Self.lampBlock, 9, 2, 3, chunkBox)
        if west.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if west.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if west.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if east.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 0, 12, 2, 0) }
        if east.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 7, 12, 2, 7) }
        if east.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 1, 3, 15, 2, 4) }
    }
}

private final class OceanMonumentDoubleXYRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        let east = definition.connections[LocalDirection.east.rawValue]!
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [
                definition,
                east,
                definition.connections[LocalDirection.up.rawValue]!,
                east.connections[LocalDirection.up.rawValue]!
            ],
            roomWidth: 2,
            roomHeight: 2,
            roomDepth: 1
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let east = self.roomDefinition!.connections[LocalDirection.east.rawValue]!
        let west = self.roomDefinition!
        let westUp = west.connections[LocalDirection.up.rawValue]!
        let eastUp = east.connections[LocalDirection.up.rawValue]!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 8, 0, east.hasOpening[LocalDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, west.hasOpening[LocalDirection.down.rawValue])
        }
        if westUp.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 1, 7, 8, 6, Self.baseGray)
        }
        if eastUp.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 8, 8, 1, 14, 8, 6, Self.baseGray)
        }
        for y in 1...7 {
            let block = (y == 2 || y == 6) ? Self.baseGray : Self.baseLight
            self.generateBox(world, chunkBox, 0, Int32(y), 0, 0, Int32(y), 7, block, block)
            self.generateBox(world, chunkBox, 15, Int32(y), 0, 15, Int32(y), 7, block, block)
            self.generateBox(world, chunkBox, 1, Int32(y), 0, 15, Int32(y), 0, block, block)
            self.generateBox(world, chunkBox, 1, Int32(y), 7, 14, Int32(y), 7, block, block)
        }
        self.generateBox(world, chunkBox, 2, 1, 3, 2, 7, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 1, 2, 4, 7, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 1, 5, 4, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 1, 3, 13, 7, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 11, 1, 2, 12, 7, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 11, 1, 5, 12, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 3, 5, 3, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 1, 3, 10, 3, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 7, 2, 10, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 5, 2, 5, 7, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 5, 2, 10, 7, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 5, 5, 5, 7, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 5, 5, 10, 7, 5, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.baseLight, 6, 6, 2, chunkBox)
        self.placeBlock(world, Self.baseLight, 9, 6, 2, chunkBox)
        self.placeBlock(world, Self.baseLight, 6, 6, 5, chunkBox)
        self.placeBlock(world, Self.baseLight, 9, 6, 5, chunkBox)
        self.generateBox(world, chunkBox, 5, 4, 3, 6, 4, 4, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 4, 3, 10, 4, 4, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.lampBlock, 5, 4, 2, chunkBox)
        self.placeBlock(world, Self.lampBlock, 5, 4, 5, chunkBox)
        self.placeBlock(world, Self.lampBlock, 10, 4, 2, chunkBox)
        self.placeBlock(world, Self.lampBlock, 10, 4, 5, chunkBox)
        if west.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if west.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if west.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if east.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 0, 12, 2, 0) }
        if east.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 7, 12, 2, 7) }
        if east.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 1, 3, 15, 2, 4) }
        if westUp.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 0, 4, 6, 0) }
        if westUp.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 7, 4, 6, 7) }
        if westUp.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 5, 3, 0, 6, 4) }
        if eastUp.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 5, 0, 12, 6, 0) }
        if eastUp.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 5, 7, 12, 6, 7) }
        if eastUp.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 5, 3, 15, 6, 4) }
    }
}

private final class OceanMonumentDoubleYRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [definition, definition.connections[LocalDirection.up.rawValue]!],
            roomWidth: 1,
            roomHeight: 2,
            roomDepth: 1
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[LocalDirection.down.rawValue])
        }
        let above = self.roomDefinition!.connections[LocalDirection.up.rawValue]!
        if above.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 1, 6, 8, 6, Self.baseGray)
        }
        self.generateBox(world, chunkBox, 0, 4, 0, 0, 4, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 4, 0, 7, 4, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 4, 0, 6, 4, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 4, 7, 6, 4, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 4, 1, 2, 4, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 4, 2, 1, 4, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 4, 1, 5, 4, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 4, 2, 6, 4, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 4, 5, 2, 4, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 4, 5, 1, 4, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 4, 5, 5, 4, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 4, 5, 6, 4, 5, Self.baseLight, Self.baseLight)
        var definition = self.roomDefinition!
        for y in stride(from: Int32(1), through: Int32(5), by: 4) {
            if definition.hasOpening[LocalDirection.south.rawValue] {
                self.generateBox(world, chunkBox, 2, y, 0, 2, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 5, y, 0, 5, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, y + 2, 0, 4, y + 2, 0, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 0, 7, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 0, 7, y + 1, 0, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[LocalDirection.north.rawValue] {
                self.generateBox(world, chunkBox, 2, y, 7, 2, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 5, y, 7, 5, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, y + 2, 7, 4, y + 2, 7, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 7, 7, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 7, 7, y + 1, 7, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[LocalDirection.west.rawValue] {
                self.generateBox(world, chunkBox, 0, y, 2, 0, y + 2, 2, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y, 5, 0, y + 2, 5, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 2, 3, 0, y + 2, 4, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 0, 0, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 0, 0, y + 1, 7, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[LocalDirection.east.rawValue] {
                self.generateBox(world, chunkBox, 7, y, 2, 7, y + 2, 2, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 7, y, 5, 7, y + 2, 5, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 7, y + 2, 3, 7, y + 2, 4, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 7, y, 0, 7, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 7, y + 1, 0, 7, y + 1, 7, Self.baseGray, Self.baseGray)
            }
            definition = above
        }
    }
}

private final class OceanMonumentDoubleYZRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        let north = definition.connections[LocalDirection.north.rawValue]!
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [
                definition,
                north,
                definition.connections[LocalDirection.up.rawValue]!,
                north.connections[LocalDirection.up.rawValue]!
            ],
            roomWidth: 1,
            roomHeight: 2,
            roomDepth: 2
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let north = self.roomDefinition!.connections[LocalDirection.north.rawValue]!
        let south = self.roomDefinition!
        let northUp = north.connections[LocalDirection.up.rawValue]!
        let southUp = south.connections[LocalDirection.up.rawValue]!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 8, north.hasOpening[LocalDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, south.hasOpening[LocalDirection.down.rawValue])
        }
        if southUp.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 1, 6, 8, 7, Self.baseGray)
        }
        if northUp.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 8, 6, 8, 14, Self.baseGray)
        }
        for y in 1...7 {
            let block = (y == 2 || y == 6) ? Self.baseGray : Self.baseLight
            self.generateBox(world, chunkBox, 0, Int32(y), 0, 0, Int32(y), 15, block, block)
            self.generateBox(world, chunkBox, 7, Int32(y), 0, 7, Int32(y), 15, block, block)
            self.generateBox(world, chunkBox, 1, Int32(y), 0, 6, Int32(y), 0, block, block)
            self.generateBox(world, chunkBox, 1, Int32(y), 15, 6, Int32(y), 15, block, block)
        }
        for y in 1...7 {
            let block = (y == 2 || y == 6) ? Self.lampBlock : Self.baseBlack
            self.generateBox(world, chunkBox, 3, Int32(y), 7, 4, Int32(y), 8, block, block)
        }
        if south.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if south.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
        if south.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if north.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 15, 4, 2, 15) }
        if north.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 11, 0, 2, 12) }
        if north.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 11, 7, 2, 12) }
        if southUp.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 0, 4, 6, 0) }
        if southUp.hasOpening[LocalDirection.east.rawValue] {
            self.generateWaterBox(world, chunkBox, 7, 5, 3, 7, 6, 4)
            self.generateBox(world, chunkBox, 5, 4, 2, 6, 4, 5, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 2, 6, 3, 2, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 5, 6, 3, 5, Self.baseLight, Self.baseLight)
        }
        if southUp.hasOpening[LocalDirection.west.rawValue] {
            self.generateWaterBox(world, chunkBox, 0, 5, 3, 0, 6, 4)
            self.generateBox(world, chunkBox, 1, 4, 2, 2, 4, 5, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 2, 1, 3, 2, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 5, 1, 3, 5, Self.baseLight, Self.baseLight)
        }
        if northUp.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 15, 4, 6, 15) }
        if northUp.hasOpening[LocalDirection.west.rawValue] {
            self.generateWaterBox(world, chunkBox, 0, 5, 11, 0, 6, 12)
            self.generateBox(world, chunkBox, 1, 4, 10, 2, 4, 13, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 10, 1, 3, 10, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 13, 1, 3, 13, Self.baseLight, Self.baseLight)
        }
        if northUp.hasOpening[LocalDirection.east.rawValue] {
            self.generateWaterBox(world, chunkBox, 7, 5, 11, 7, 6, 12)
            self.generateBox(world, chunkBox, 5, 4, 10, 6, 4, 13, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 10, 6, 3, 10, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 13, 6, 3, 13, Self.baseLight, Self.baseLight)
        }
    }
}

private final class OceanMonumentDoubleZRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(
            orientation: orientation,
            roomDefinition: definition,
            occupiedRooms: [definition, definition.connections[LocalDirection.north.rawValue]!],
            roomWidth: 1,
            roomHeight: 1,
            roomDepth: 2
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let north = self.roomDefinition!.connections[LocalDirection.north.rawValue]!
        let south = self.roomDefinition!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 8, north.hasOpening[LocalDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, south.hasOpening[LocalDirection.down.rawValue])
        }
        if south.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 7, Self.baseGray)
        }
        if north.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 8, 6, 4, 14, Self.baseGray)
        }
        self.generateBox(world, chunkBox, 0, 3, 0, 0, 3, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 3, 0, 7, 3, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 0, 7, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 15, 6, 3, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 0, 2, 15, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 7, 2, 0, 7, 2, 15, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 0, 7, 2, 0, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 15, 6, 2, 15, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 0, 7, 1, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 7, 1, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 15, 6, 1, 15, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 1, 1, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 1, 6, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 1, 1, 3, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 3, 1, 6, 3, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 13, 1, 1, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 13, 6, 1, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 13, 1, 3, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 3, 13, 6, 3, 14, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 1, 6, 2, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 6, 5, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 1, 9, 2, 3, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 9, 5, 3, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 2, 6, 4, 2, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 3, 2, 9, 4, 2, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 2, 7, 2, 2, 8, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 2, 7, 5, 2, 8, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.lampBlock, 2, 2, 5, chunkBox)
        self.placeBlock(world, Self.lampBlock, 5, 2, 5, chunkBox)
        self.placeBlock(world, Self.lampBlock, 2, 2, 10, chunkBox)
        self.placeBlock(world, Self.lampBlock, 5, 2, 10, chunkBox)
        self.placeBlock(world, Self.baseLight, 2, 3, 5, chunkBox)
        self.placeBlock(world, Self.baseLight, 5, 3, 5, chunkBox)
        self.placeBlock(world, Self.baseLight, 2, 3, 10, chunkBox)
        self.placeBlock(world, Self.baseLight, 5, 3, 10, chunkBox)
        if south.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if south.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
        if south.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if north.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 15, 4, 2, 15) }
        if north.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 11, 0, 2, 12) }
        if north.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 11, 7, 2, 12) }
    }
}

private final class OceanMonumentEntryRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.generateBox(world, chunkBox, 0, 3, 0, 2, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 3, 0, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 1, 2, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 2, 0, 7, 2, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 0, 7, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 7, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 2, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
        if self.roomDefinition!.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if self.roomDefinition!.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 1, 2, 4) }
        if self.roomDefinition!.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 6, 1, 3, 7, 2, 4) }
    }
}

private final class OceanMonumentPenthouse: MonumentPiece {
    init(orientation: HorizontalDirection, boundingBox: BoundingBox) {
        super.init(orientation: orientation, boundingBox: boundingBox)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.generateBox(world, chunkBox, 2, -1, 2, 11, -1, 11, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, -1, 0, 1, -1, 11, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 12, -1, 0, 13, -1, 11, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 2, -1, 0, 11, -1, 1, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 2, -1, 12, 11, -1, 13, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 0, 0, 0, 0, 0, 13, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 0, 0, 13, 0, 13, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 0, 0, 12, 0, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 0, 13, 12, 0, 13, Self.baseLight, Self.baseLight)
        for i in stride(from: Int32(2), through: Int32(11), by: 3) {
            self.placeBlock(world, Self.lampBlock, 0, 0, i, chunkBox)
            self.placeBlock(world, Self.lampBlock, 13, 0, i, chunkBox)
            self.placeBlock(world, Self.lampBlock, i, 0, 0, chunkBox)
        }
        self.generateBox(world, chunkBox, 2, 0, 3, 4, 0, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 0, 3, 11, 0, 9, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 4, 0, 9, 9, 0, 11, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.baseLight, 5, 0, 8, chunkBox)
        self.placeBlock(world, Self.baseLight, 8, 0, 8, chunkBox)
        self.placeBlock(world, Self.baseLight, 10, 0, 10, chunkBox)
        self.placeBlock(world, Self.baseLight, 3, 0, 10, chunkBox)
        self.generateBox(world, chunkBox, 3, 0, 3, 3, 0, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 10, 0, 3, 10, 0, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 6, 0, 10, 7, 0, 10, Self.baseBlack, Self.baseBlack)
        for x in [Int32(3), Int32(10)] {
            for z in stride(from: Int32(2), through: Int32(8), by: 3) {
                self.generateBox(world, chunkBox, x, 0, z, x, 2, z, Self.baseLight, Self.baseLight)
            }
        }
        self.generateBox(world, chunkBox, 5, 0, 10, 5, 2, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 8, 0, 10, 8, 2, 10, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, -1, 7, 7, -1, 8, Self.baseBlack, Self.baseBlack)
        self.generateWaterBox(world, chunkBox, 6, -1, 3, 7, -1, 4)
        self.placeMarker(world, chunkBox, 6, 1, 6, represents: "minecraft:elder_guardian")
    }
}

private class OceanMonumentSimpleRoomBase: MonumentPiece {
    private(set) var hasCenterPillar = false

    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1)
    }

    class func create<R: Random>(orientation: HorizontalDirection, definition: RoomDefinition, random: inout R) -> MonumentPiece {
        switch random.next(bound: 3) {
        case 0:
            return OceanMonumentSimpleRoomDesign0(orientation: orientation, definition: definition)
        case 1:
            return OceanMonumentSimpleRoomDesign1(orientation: orientation, definition: definition)
        default:
            return OceanMonumentSimpleRoomDesign2(orientation: orientation, definition: definition)
        }
    }

    var supportsCenterPillar: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[LocalDirection.down.rawValue])
        }
        if self.roomDefinition!.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 6, Self.baseGray)
        }

        let hasCenterPillar = self.shouldGenerateCenterPillar(using: &random)
        self.hasCenterPillar = hasCenterPillar
        self.generateInterior(world, chunkBox)

        if hasCenterPillar {
            self.generateBox(world, chunkBox, 3, 1, 3, 4, 1, 4, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 3, 2, 3, 4, 2, 4, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 3, 3, 3, 4, 3, 4, Self.baseLight, Self.baseLight)
        }
    }

    private func shouldGenerateCenterPillar<R: Random>(using random: inout R) -> Bool {
        guard self.supportsCenterPillar else { return false }
        let pillarRollMatches = random.next(bound: 2) == 0
        return pillarRollMatches
            && !self.roomDefinition!.hasOpening[LocalDirection.down.rawValue]
            && !self.roomDefinition!.hasOpening[LocalDirection.up.rawValue]
            && self.roomDefinition!.countOpenings() > 1
    }

    func generateInterior(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        fatalError("Subclasses must implement generateInterior")
    }
}

private final class OceanMonumentSimpleRoomDesign0: OceanMonumentSimpleRoomBase {
    override func generateInterior(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        self.generateBox(world, chunkBox, 0, 1, 0, 2, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 3, 0, 2, 3, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 0, 2, 2, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 0, 2, 2, 0, Self.baseGray, Self.baseGray)
        self.placeBlock(world, Self.lampBlock, 1, 2, 1, chunkBox)
        self.generateBox(world, chunkBox, 5, 1, 0, 7, 1, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 3, 0, 7, 3, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 2, 0, 7, 2, 2, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 5, 2, 0, 6, 2, 0, Self.baseGray, Self.baseGray)
        self.placeBlock(world, Self.lampBlock, 6, 2, 1, chunkBox)
        self.generateBox(world, chunkBox, 0, 1, 5, 2, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 3, 5, 2, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 5, 0, 2, 7, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 1, 2, 7, 2, 2, 7, Self.baseGray, Self.baseGray)
        self.placeBlock(world, Self.lampBlock, 1, 2, 6, chunkBox)
        self.generateBox(world, chunkBox, 5, 1, 5, 7, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 3, 5, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 2, 5, 7, 2, 7, Self.baseGray, Self.baseGray)
        self.generateBox(world, chunkBox, 5, 2, 7, 6, 2, 7, Self.baseGray, Self.baseGray)
        self.placeBlock(world, Self.lampBlock, 6, 2, 6, chunkBox)
        if self.roomDefinition!.hasOpening[LocalDirection.south.rawValue] {
            self.generateBox(world, chunkBox, 3, 3, 0, 4, 3, 0, Self.baseLight, Self.baseLight)
        } else {
            self.generateBox(world, chunkBox, 3, 3, 0, 4, 3, 1, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 3, 2, 0, 4, 2, 0, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 3, 1, 0, 4, 1, 1, Self.baseLight, Self.baseLight)
        }
        if self.roomDefinition!.hasOpening[LocalDirection.north.rawValue] {
            self.generateBox(world, chunkBox, 3, 3, 7, 4, 3, 7, Self.baseLight, Self.baseLight)
        } else {
            self.generateBox(world, chunkBox, 3, 3, 6, 4, 3, 7, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 3, 2, 7, 4, 2, 7, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 3, 1, 6, 4, 1, 7, Self.baseLight, Self.baseLight)
        }
        if self.roomDefinition!.hasOpening[LocalDirection.west.rawValue] {
            self.generateBox(world, chunkBox, 0, 3, 3, 0, 3, 4, Self.baseLight, Self.baseLight)
        } else {
            self.generateBox(world, chunkBox, 0, 3, 3, 1, 3, 4, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 0, 2, 3, 0, 2, 4, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 0, 1, 3, 1, 1, 4, Self.baseLight, Self.baseLight)
        }
        if self.roomDefinition!.hasOpening[LocalDirection.east.rawValue] {
            self.generateBox(world, chunkBox, 7, 3, 3, 7, 3, 4, Self.baseLight, Self.baseLight)
        } else {
            self.generateBox(world, chunkBox, 6, 3, 3, 7, 3, 4, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 7, 2, 3, 7, 2, 4, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 6, 1, 3, 7, 1, 4, Self.baseLight, Self.baseLight)
        }
    }
}

private class OceanMonumentSimpleRoomWithOptionalPillar: OceanMonumentSimpleRoomBase {
    override var supportsCenterPillar: Bool { true }
}

private final class OceanMonumentSimpleRoomDesign1: OceanMonumentSimpleRoomWithOptionalPillar {
    override func generateInterior(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        self.generateBox(world, chunkBox, 2, 1, 2, 2, 3, 2, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 2, 1, 5, 2, 3, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 5, 5, 3, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 2, 5, 3, 2, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.lampBlock, 2, 2, 2, chunkBox)
        self.placeBlock(world, Self.lampBlock, 2, 2, 5, chunkBox)
        self.placeBlock(world, Self.lampBlock, 5, 2, 5, chunkBox)
        self.placeBlock(world, Self.lampBlock, 5, 2, 2, chunkBox)
        self.generateBox(world, chunkBox, 0, 1, 0, 1, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 1, 0, 3, 1, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 7, 1, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 6, 0, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 7, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 6, 7, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 1, 0, 7, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 1, 7, 3, 1, Self.baseLight, Self.baseLight)
        self.placeBlock(world, Self.baseGray, 1, 2, 0, chunkBox)
        self.placeBlock(world, Self.baseGray, 0, 2, 1, chunkBox)
        self.placeBlock(world, Self.baseGray, 1, 2, 7, chunkBox)
        self.placeBlock(world, Self.baseGray, 0, 2, 6, chunkBox)
        self.placeBlock(world, Self.baseGray, 6, 2, 7, chunkBox)
        self.placeBlock(world, Self.baseGray, 7, 2, 6, chunkBox)
        self.placeBlock(world, Self.baseGray, 6, 2, 0, chunkBox)
        self.placeBlock(world, Self.baseGray, 7, 2, 1, chunkBox)
        if !self.roomDefinition!.hasOpening[LocalDirection.south.rawValue] {
            self.generateBox(world, chunkBox, 1, 3, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 2, 0, 6, 2, 0, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 1, 1, 0, 6, 1, 0, Self.baseLight, Self.baseLight)
        }
        if !self.roomDefinition!.hasOpening[LocalDirection.north.rawValue] {
            self.generateBox(world, chunkBox, 1, 3, 7, 6, 3, 7, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 2, 7, 6, 2, 7, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 1, 1, 7, 6, 1, 7, Self.baseLight, Self.baseLight)
        }
        if !self.roomDefinition!.hasOpening[LocalDirection.west.rawValue] {
            self.generateBox(world, chunkBox, 0, 3, 1, 0, 3, 6, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 0, 2, 1, 0, 2, 6, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 0, 1, 1, 0, 1, 6, Self.baseLight, Self.baseLight)
        }
        if !self.roomDefinition!.hasOpening[LocalDirection.east.rawValue] {
            self.generateBox(world, chunkBox, 7, 3, 1, 7, 3, 6, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 7, 2, 1, 7, 2, 6, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 7, 1, 1, 7, 1, 6, Self.baseLight, Self.baseLight)
        }
    }
}

private final class OceanMonumentSimpleRoomDesign2: OceanMonumentSimpleRoomWithOptionalPillar {
    override func generateInterior(_ world: StructureWorldView, _ chunkBox: BoundingBox) {
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 0, 7, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 6, 1, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 7, 6, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 0, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 7, 2, 0, 7, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 1, 2, 0, 6, 2, 0, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 1, 2, 7, 6, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 0, 3, 0, 0, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 3, 0, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 7, 6, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 3, 0, 2, 4, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 7, 1, 3, 7, 2, 4, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 3, 1, 0, 4, 2, 0, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 3, 1, 7, 4, 2, 7, Self.baseBlack, Self.baseBlack)
        if self.roomDefinition!.hasOpening[LocalDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if self.roomDefinition!.hasOpening[LocalDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if self.roomDefinition!.hasOpening[LocalDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if self.roomDefinition!.hasOpening[LocalDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
    }
}

private final class OceanMonumentSimpleTopRoom: MonumentPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[LocalDirection.down.rawValue])
        }
        if self.roomDefinition!.connections[LocalDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 6, Self.baseGray)
        }
        for x in 1...6 {
            for z in 1...6 {
                if random.next(bound: 3) != 0 {
                    let y0: Int32 = 2 + (random.next(bound: 4) == 0 ? 0 : 1)
                    self.generateBox(world, chunkBox, Int32(x), y0, Int32(z), Int32(x), 3, Int32(z), Blocks.wetSpongeState, Blocks.wetSpongeState)
                }
            }
        }
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 0, 7, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 6, 1, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 7, 6, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 0, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 7, 2, 0, 7, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 1, 2, 0, 6, 2, 0, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 1, 2, 7, 6, 2, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 0, 3, 0, 0, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 3, 0, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 3, 7, 6, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 3, 0, 2, 4, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 7, 1, 3, 7, 2, 4, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 3, 1, 0, 4, 2, 0, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 3, 1, 7, 4, 2, 7, Self.baseBlack, Self.baseBlack)
        if self.roomDefinition!.hasOpening[LocalDirection.south.rawValue] {
            self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0)
        }
    }
}

private class OceanMonumentWingRoomBase: MonumentPiece {
    init(orientation: HorizontalDirection, boundingBox: BoundingBox) {
        super.init(orientation: orientation, boundingBox: boundingBox)
    }

    class func create(orientation: HorizontalDirection, boundingBox: BoundingBox, randomValue: Int32) -> MonumentPiece {
        if randomValue & 1 == 0 {
            return OceanMonumentWingRoomDesign0(orientation: orientation, boundingBox: boundingBox)
        }
        return OceanMonumentWingRoomDesign1(orientation: orientation, boundingBox: boundingBox)
    }
}

private final class OceanMonumentWingRoomDesign0: OceanMonumentWingRoomBase {
    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        for i in 0..<4 {
            let ii = Int32(i)
            self.generateBox(world, chunkBox, 10 - ii, 3 - ii, 20 - ii, 12 + ii, 3 - ii, 20, Self.baseLight, Self.baseLight)
        }
        self.generateBox(world, chunkBox, 7, 0, 6, 15, 0, 16, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 0, 6, 6, 3, 20, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 16, 0, 6, 16, 3, 20, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 7, 7, 1, 20, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 15, 1, 7, 15, 1, 20, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 6, 9, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 1, 6, 15, 3, 6, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 8, 1, 7, 9, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 1, 7, 14, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 0, 5, 13, 0, 5, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 10, 0, 7, 12, 0, 7, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 8, 0, 10, 8, 0, 12, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 14, 0, 10, 14, 0, 12, Self.baseBlack, Self.baseBlack)
        for z in stride(from: Int32(18), through: Int32(7), by: -3) {
            self.placeBlock(world, Self.lampBlock, 6, 3, z, chunkBox)
            self.placeBlock(world, Self.lampBlock, 16, 3, z, chunkBox)
        }
        self.placeBlock(world, Self.lampBlock, 10, 0, 10, chunkBox)
        self.placeBlock(world, Self.lampBlock, 12, 0, 10, chunkBox)
        self.placeBlock(world, Self.lampBlock, 10, 0, 12, chunkBox)
        self.placeBlock(world, Self.lampBlock, 12, 0, 12, chunkBox)
        self.placeBlock(world, Self.lampBlock, 8, 3, 6, chunkBox)
        self.placeBlock(world, Self.lampBlock, 14, 3, 6, chunkBox)
        self.placeBlock(world, Self.baseLight, 4, 2, 4, chunkBox)
        self.placeBlock(world, Self.lampBlock, 4, 1, 4, chunkBox)
        self.placeBlock(world, Self.baseLight, 4, 0, 4, chunkBox)
        self.placeBlock(world, Self.baseLight, 18, 2, 4, chunkBox)
        self.placeBlock(world, Self.lampBlock, 18, 1, 4, chunkBox)
        self.placeBlock(world, Self.baseLight, 18, 0, 4, chunkBox)
        self.placeBlock(world, Self.baseLight, 4, 2, 18, chunkBox)
        self.placeBlock(world, Self.lampBlock, 4, 1, 18, chunkBox)
        self.placeBlock(world, Self.baseLight, 4, 0, 18, chunkBox)
        self.placeBlock(world, Self.baseLight, 18, 2, 18, chunkBox)
        self.placeBlock(world, Self.lampBlock, 18, 1, 18, chunkBox)
        self.placeBlock(world, Self.baseLight, 18, 0, 18, chunkBox)
        self.placeBlock(world, Self.baseLight, 9, 7, 20, chunkBox)
        self.placeBlock(world, Self.baseLight, 13, 7, 20, chunkBox)
        self.generateBox(world, chunkBox, 6, 0, 21, 7, 4, 21, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 15, 0, 21, 16, 4, 21, Self.baseLight, Self.baseLight)
        self.placeMarker(world, chunkBox, 11, 2, 16, represents: "minecraft:elder_guardian")
    }
}

private final class OceanMonumentWingRoomDesign1: OceanMonumentWingRoomBase {
    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.generateBox(world, chunkBox, 9, 3, 18, 13, 3, 20, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 9, 0, 18, 9, 2, 18, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 13, 0, 18, 13, 2, 18, Self.baseLight, Self.baseLight)
        var x: Int32 = 9
        for _ in 0..<2 {
            self.placeBlock(world, Self.baseLight, x, 6, 20, chunkBox)
            self.placeBlock(world, Self.lampBlock, x, 5, 20, chunkBox)
            self.placeBlock(world, Self.baseLight, x, 4, 20, chunkBox)
            x = 13
        }
        self.generateBox(world, chunkBox, 7, 3, 7, 15, 3, 14, Self.baseLight, Self.baseLight)
        var var14: Int32 = 10
        for _ in 0..<2 {
            self.generateBox(world, chunkBox, var14, 0, 10, var14, 6, 10, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, var14, 0, 12, var14, 6, 12, Self.baseLight, Self.baseLight)
            self.placeBlock(world, Self.lampBlock, var14, 0, 10, chunkBox)
            self.placeBlock(world, Self.lampBlock, var14, 0, 12, chunkBox)
            self.placeBlock(world, Self.lampBlock, var14, 4, 10, chunkBox)
            self.placeBlock(world, Self.lampBlock, var14, 4, 12, chunkBox)
            var14 = 12
        }
        var14 = 8
        for _ in 0..<2 {
            self.generateBox(world, chunkBox, var14, 0, 7, var14, 2, 7, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, var14, 0, 14, var14, 2, 14, Self.baseLight, Self.baseLight)
            var14 = 14
        }
        self.generateBox(world, chunkBox, 8, 3, 8, 8, 3, 13, Self.baseBlack, Self.baseBlack)
        self.generateBox(world, chunkBox, 14, 3, 8, 14, 3, 13, Self.baseBlack, Self.baseBlack)
        self.placeMarker(world, chunkBox, 11, 5, 13, represents: "minecraft:elder_guardian")
    }
}

private func monumentShuffle<T, R: Random>(_ values: inout [T], random: inout R) {
    guard values.count > 1 else { return }
    for index in stride(from: values.count - 1, through: 1, by: -1) {
        let swapIndex = Int(random.next(bound: UInt32(index + 1)))
        if swapIndex != index {
            values.swapAt(index, swapIndex)
        }
    }
}
