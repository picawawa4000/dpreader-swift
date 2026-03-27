import Foundation

/// Samples the existing world state for ocean monument generation.
///
/// The generator only needs three pieces of external world context:
/// - `seaLevel`, because vanilla monument water boxes emit air above sea level and water below it.
/// - `minimumWorldY`, because the support pillars use a downward fill operation that must know when to stop.
/// - `blockSampler`, because both water-box filling and support pillars depend on the pre-existing block state.
///
/// Everything else, including the room graph, orientation, piece bounds, and local block layout, is generated
/// directly from the structure seed and the start chunk.
public struct OceanMonumentGenerationContext {
    public let seaLevel: Int32
    public let minimumWorldY: Int32
    public let blockSampler: (PosInt3D) -> BlockState

    public init(
        seaLevel: Int32,
        minimumWorldY: Int32,
        blockSampler: @escaping (PosInt3D) -> BlockState = { _ in BlockState(type: Block(withID: "minecraft:air")) }
    ) {
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.blockSampler = blockSampler
    }
}

/// The public, inspectable piece graph for a monument.
///
/// The graph mirrors the vanilla piece layout:
/// - one root `monumentBuilding`
/// - a generated set of room pieces derived from the room graph
/// - two wing rooms
/// - one penthouse
///
/// Piece order matches generation order, which matters for overlapping writes.
public struct OceanMonumentPieceGraph {
    public let startChunk: PosInt2D
    public let orientation: OceanMonumentOrientation
    public let boundingBox: OceanMonumentBoundingBox
    public let pieces: [OceanMonumentGraphPiece]
}

/// One generated piece in the public graph view.
public struct OceanMonumentGraphPiece {
    public let kind: OceanMonumentPieceKind
    public let orientation: OceanMonumentOrientation
    public let boundingBox: OceanMonumentBoundingBox
    public let roomIndex: Int?
    public let design: Int?
}

public enum OceanMonumentPieceKind: String {
    case monumentBuilding
    case entryRoom
    case coreRoom
    case doubleXRoom
    case doubleXYRoom
    case doubleYRoom
    case doubleYZRoom
    case doubleZRoom
    case simpleRoom
    case simpleTopRoom
    case wingRoom
    case penthouse
}

public enum OceanMonumentOrientation: String {
    case north
    case east
    case south
    case west
}

/// A public bounding box type used by the monument APIs.
public struct OceanMonumentBoundingBox: Equatable {
    public let minX: Int32
    public let minY: Int32
    public let minZ: Int32
    public let maxX: Int32
    public let maxY: Int32
    public let maxZ: Int32

    public init(minX: Int32, minY: Int32, minZ: Int32, maxX: Int32, maxY: Int32, maxZ: Int32) {
        self.minX = minX
        self.minY = minY
        self.minZ = minZ
        self.maxX = maxX
        self.maxY = maxY
        self.maxZ = maxZ
    }

    public func contains(_ pos: PosInt3D) -> Bool {
        pos.x >= self.minX && pos.x <= self.maxX
            && pos.y >= self.minY && pos.y <= self.maxY
            && pos.z >= self.minZ && pos.z <= self.maxZ
    }
}

/// The generated monument output.
///
/// `blocks` stores only the written structure blocks in a sparse, paletted, sectioned volume.
/// Reads fall back to the caller's `blockSampler`, which lets the monument renderer preserve
/// existing ice and stop support pillars on real terrain without copying an entire chunk region.
public struct OceanMonumentGenerationResult {
    public let graph: OceanMonumentPieceGraph
    public let blocks: OceanMonumentBlockVolume
    public let elderGuardians: [PosInt3D]
}

/// A sparse block volume backed by per-section paletted storage.
///
/// The storage is intentionally simple:
/// - the world is divided into 16x16x16 sections
/// - each touched section stores a dense palette/index array plus a touched bitset
/// - untouched cells read through to the caller-provided world sampler
///
/// This keeps the implementation compact while still giving structure generation the same
/// "read world, then overlay writes" model that vanilla piece code expects.
public final class OceanMonumentBlockVolume {
    public let bounds: OceanMonumentBoundingBox

    private struct SectionKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private final class Section {
        private let storage = PalettedChunkBlockStorage(filledWith: OceanMonumentBlocks.airState)
        private var touched = [UInt64](repeating: 0, count: 64)

        func set(_ state: BlockState, at localPos: PosInt3D) {
            self.storage.setBlock(state, at: localPos)
            let index = (Int(localPos.y) << 8) | (Int(localPos.z) << 4) | Int(localPos.x)
            self.touched[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }

        func get(at localPos: PosInt3D) -> BlockState? {
            let index = (Int(localPos.y) << 8) | (Int(localPos.z) << 4) | Int(localPos.x)
            let mask = UInt64(1) << UInt64(index & 63)
            guard (self.touched[index >> 6] & mask) != 0 else {
                return nil
            }
            return self.storage.getBlock(at: localPos)
        }
    }

    private let fallbackSampler: (PosInt3D) -> BlockState
    private var sections: [SectionKey: Section] = [:]

    public init(bounds: OceanMonumentBoundingBox, fallbackSampler: @escaping (PosInt3D) -> BlockState) {
        self.bounds = bounds
        self.fallbackSampler = fallbackSampler
    }

    public func block(at pos: PosInt3D) -> BlockState {
        guard self.bounds.contains(pos) else {
            return self.fallbackSampler(pos)
        }
        let (key, localPos) = self.sectionKeyAndLocalPos(for: pos)
        if let section = self.sections[key], let state = section.get(at: localPos) {
            return state
        }
        return self.fallbackSampler(pos)
    }

    public func setBlock(_ state: BlockState, at pos: PosInt3D) {
        guard self.bounds.contains(pos) else {
            return
        }
        let (key, localPos) = self.sectionKeyAndLocalPos(for: pos)
        let section: Section
        if let existing = self.sections[key] {
            section = existing
        } else {
            let created = Section()
            self.sections[key] = created
            section = created
        }
        section.set(state, at: localPos)
    }

    public func allTouchedBlocks() -> [(PosInt3D, BlockState)] {
        var result: [(PosInt3D, BlockState)] = []
        for (key, section) in self.sections {
            for localY in 0..<16 {
                for localZ in 0..<16 {
                    for localX in 0..<16 {
                        let local = PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ))
                        guard let state = section.get(at: local) else { continue }
                        let worldPos = PosInt3D(
                            x: key.x &* 16 &+ Int32(localX),
                            y: key.y &* 16 &+ Int32(localY),
                            z: key.z &* 16 &+ Int32(localZ)
                        )
                        result.append((worldPos, state))
                    }
                }
            }
        }
        result.sort { left, right in
            if left.0.y != right.0.y { return left.0.y < right.0.y }
            if left.0.z != right.0.z { return left.0.z < right.0.z }
            return left.0.x < right.0.x
        }
        return result
    }

    private func sectionKeyAndLocalPos(for pos: PosInt3D) -> (SectionKey, PosInt3D) {
        let sectionX = monumentFloorDiv(pos.x, 16)
        let sectionY = monumentFloorDiv(pos.y, 16)
        let sectionZ = monumentFloorDiv(pos.z, 16)
        let localX = pos.x - sectionX * 16
        let localY = pos.y - sectionY * 16
        let localZ = pos.z - sectionZ * 16
        return (
            SectionKey(x: sectionX, y: sectionY, z: sectionZ),
            PosInt3D(x: localX, y: localY, z: localZ)
        )
    }
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
public enum OceanMonument {
    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D) -> OceanMonumentPieceGraph {
        var random = monumentLargeFeatureRandom(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let root = MonumentBuilding(startChunk: startChunk, random: &random)
        return pieceGraph(from: root, startChunk: startChunk)
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: OceanMonumentGenerationContext
    ) -> OceanMonumentGenerationResult {
        var random = monumentLargeFeatureRandom(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let root = MonumentBuilding(startChunk: startChunk, random: &random)
        let graph = pieceGraph(from: root, startChunk: startChunk)

        let writeBounds = expandedWriteBounds(for: root, minimumWorldY: context.minimumWorldY)
        let volume = OceanMonumentBlockVolume(bounds: writeBounds.publicValue, fallbackSampler: context.blockSampler)
        let world = MonumentWorld(
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY,
            volume: volume
        )
        root.postProcess(in: world, chunkBox: writeBounds, random: &random)
        return OceanMonumentGenerationResult(
            graph: graph,
            blocks: volume,
            elderGuardians: world.elderGuardians
        )
    }

    private static func pieceGraph(from root: MonumentBuilding, startChunk: PosInt2D) -> OceanMonumentPieceGraph {
        let pieces = ([root] + root.childPieces).map { $0.graphPiece() }
        let bounds = ([root] + root.childPieces).reduce(root.boundingBox) { partialResult, piece in
            partialResult.union(piece.boundingBox)
        }
        return OceanMonumentPieceGraph(
            startChunk: startChunk,
            orientation: root.orientation.publicValue,
            boundingBox: bounds.publicValue,
            pieces: pieces
        )
    }

    private static func expandedWriteBounds(for root: MonumentBuilding, minimumWorldY: Int32) -> MonumentBoundingBox {
        let union = ([root] + root.childPieces).reduce(root.boundingBox) { partialResult, piece in
            partialResult.union(piece.boundingBox)
        }
        return MonumentBoundingBox(
            minX: union.minX - 5,
            minY: min(minimumWorldY + 1, union.minY - 1),
            minZ: union.minZ - 5,
            maxX: union.maxX + 5,
            maxY: union.maxY,
            maxZ: union.maxZ + 5
        )
    }
}

private enum OceanMonumentBlocks {
    static let air = Block(withID: "minecraft:air")
    static let water = Block(withID: "minecraft:water")
    static let prismarine = Block(withID: "minecraft:prismarine")
    static let prismarineBricks = Block(withID: "minecraft:prismarine_bricks")
    static let darkPrismarine = Block(withID: "minecraft:dark_prismarine")
    static let seaLantern = Block(withID: "minecraft:sea_lantern")
    static let ice = Block(withID: "minecraft:ice")
    static let packedIce = Block(withID: "minecraft:packed_ice")
    static let blueIce = Block(withID: "minecraft:blue_ice")
    static let goldBlock = Block(withID: "minecraft:gold_block")
    static let wetSponge = Block(withID: "minecraft:wet_sponge")
    static let kelp = Block(withID: "minecraft:kelp")
    static let kelpPlant = Block(withID: "minecraft:kelp_plant")
    static let seagrass = Block(withID: "minecraft:seagrass")
    static let tallSeagrass = Block(withID: "minecraft:tall_seagrass")

    static let airState = BlockState(type: air)
    static let waterState = BlockState(type: water)
    static let prismarineState = BlockState(type: prismarine)
    static let prismarineBricksState = BlockState(type: prismarineBricks)
    static let darkPrismarineState = BlockState(type: darkPrismarine)
    static let seaLanternState = BlockState(type: seaLantern)
    static let goldBlockState = BlockState(type: goldBlock)
    static let wetSpongeState = BlockState(type: wetSponge)
}

private enum MonumentDirection: Int, CaseIterable {
    case down = 0
    case up = 1
    case north = 2
    case south = 3
    case west = 4
    case east = 5

    var opposite: MonumentDirection {
        switch self {
        case .down: return .up
        case .up: return .down
        case .north: return .south
        case .south: return .north
        case .west: return .east
        case .east: return .west
        }
    }

    var stepX: Int32 {
        switch self {
        case .west: return -1
        case .east: return 1
        default: return 0
        }
    }

    var stepY: Int32 {
        switch self {
        case .down: return -1
        case .up: return 1
        default: return 0
        }
    }

    var stepZ: Int32 {
        switch self {
        case .north: return -1
        case .south: return 1
        default: return 0
        }
    }
}

private enum HorizontalDirection: CaseIterable {
    case north
    case east
    case south
    case west

    var publicValue: OceanMonumentOrientation {
        switch self {
        case .north: return .north
        case .east: return .east
        case .south: return .south
        case .west: return .west
        }
    }

    static func random(using random: inout CheckedRandom) -> HorizontalDirection {
        switch Int(random.next(bound: 4)) {
        case 0: return .north
        case 1: return .east
        case 2: return .south
        default: return .west
        }
    }
}

private struct MonumentBoundingBox: Equatable {
    var minX: Int32
    var minY: Int32
    var minZ: Int32
    var maxX: Int32
    var maxY: Int32
    var maxZ: Int32

    var publicValue: OceanMonumentBoundingBox {
        OceanMonumentBoundingBox(minX: self.minX, minY: self.minY, minZ: self.minZ, maxX: self.maxX, maxY: self.maxY, maxZ: self.maxZ)
    }

    mutating func move(_ dx: Int32, _ dy: Int32, _ dz: Int32) {
        self.minX += dx
        self.maxX += dx
        self.minY += dy
        self.maxY += dy
        self.minZ += dz
        self.maxZ += dz
    }

    func union(_ other: MonumentBoundingBox) -> MonumentBoundingBox {
        MonumentBoundingBox(
            minX: min(self.minX, other.minX),
            minY: min(self.minY, other.minY),
            minZ: min(self.minZ, other.minZ),
            maxX: max(self.maxX, other.maxX),
            maxY: max(self.maxY, other.maxY),
            maxZ: max(self.maxZ, other.maxZ)
        )
    }

    func intersects(_ other: MonumentBoundingBox) -> Bool {
        self.maxX >= other.minX
            && self.minX <= other.maxX
            && self.maxY >= other.minY
            && self.minY <= other.maxY
            && self.maxZ >= other.minZ
            && self.minZ <= other.maxZ
    }

    func intersects(minX: Int32, minZ: Int32, maxX: Int32, maxZ: Int32) -> Bool {
        self.maxX >= minX
            && self.minX <= maxX
            && self.maxZ >= minZ
            && self.minZ <= maxZ
    }

    func contains(_ pos: PosInt3D) -> Bool {
        pos.x >= self.minX && pos.x <= self.maxX
            && pos.y >= self.minY && pos.y <= self.maxY
            && pos.z >= self.minZ && pos.z <= self.maxZ
    }

    static func fromCorners(_ a: PosInt3D, _ b: PosInt3D) -> MonumentBoundingBox {
        MonumentBoundingBox(
            minX: min(a.x, b.x),
            minY: min(a.y, b.y),
            minZ: min(a.z, b.z),
            maxX: max(a.x, b.x),
            maxY: max(a.y, b.y),
            maxZ: max(a.z, b.z)
        )
    }
}

private func makeBoundingBox(
    x: Int32,
    y: Int32,
    z: Int32,
    orientation: HorizontalDirection,
    width: Int32,
    height: Int32,
    depth: Int32
) -> MonumentBoundingBox {
    switch orientation {
    case .north:
        return MonumentBoundingBox(minX: x, minY: y, minZ: z - depth + 1, maxX: x + width - 1, maxY: y + height - 1, maxZ: z)
    case .south:
        return MonumentBoundingBox(minX: x, minY: y, minZ: z, maxX: x + width - 1, maxY: y + height - 1, maxZ: z + depth - 1)
    case .west:
        return MonumentBoundingBox(minX: x - depth + 1, minY: y, minZ: z, maxX: x, maxY: y + height - 1, maxZ: z + width - 1)
    case .east:
        return MonumentBoundingBox(minX: x, minY: y, minZ: z, maxX: x + depth - 1, maxY: y + height - 1, maxZ: z + width - 1)
    }
}

private final class MonumentWorld {
    let seaLevel: Int32
    let minimumWorldY: Int32
    let volume: OceanMonumentBlockVolume
    var elderGuardians: [PosInt3D] = []

    init(seaLevel: Int32, minimumWorldY: Int32, volume: OceanMonumentBlockVolume) {
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.volume = volume
    }

    func block(at pos: PosInt3D) -> BlockState {
        self.volume.block(at: pos)
    }

    func setBlock(_ state: BlockState, at pos: PosInt3D) {
        self.volume.setBlock(state, at: pos)
    }

    func isReplaceableForStructure(_ state: BlockState) -> Bool {
        let id = state.type.id
        return state.type.isAir
            || id == "minecraft:water"
            || id == "minecraft:lava"
            || id == "minecraft:kelp"
            || id == "minecraft:kelp_plant"
            || id == "minecraft:seagrass"
            || id == "minecraft:tall_seagrass"
            || id == "minecraft:bubble_column"
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

    func setConnection(_ direction: MonumentDirection, _ definition: RoomDefinition) {
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
    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece
}

private struct FitDoubleXRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[MonumentDirection.east.rawValue] && !(definition.connections[MonumentDirection.east.rawValue]?.claimed ?? true)
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        definition.connections[MonumentDirection.east.rawValue]?.claimed = true
        return OceanMonumentDoubleXRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleXYRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        guard definition.hasOpening[MonumentDirection.east.rawValue],
              !(definition.connections[MonumentDirection.east.rawValue]?.claimed ?? true),
              definition.hasOpening[MonumentDirection.up.rawValue],
              !(definition.connections[MonumentDirection.up.rawValue]?.claimed ?? true),
              let east = definition.connections[MonumentDirection.east.rawValue]
        else {
            return false
        }
        return east.hasOpening[MonumentDirection.up.rawValue] && !(east.connections[MonumentDirection.up.rawValue]?.claimed ?? true)
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        definition.connections[MonumentDirection.east.rawValue]?.claimed = true
        definition.connections[MonumentDirection.up.rawValue]?.claimed = true
        definition.connections[MonumentDirection.east.rawValue]?.connections[MonumentDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleXYRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleYRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[MonumentDirection.up.rawValue] && !(definition.connections[MonumentDirection.up.rawValue]?.claimed ?? true)
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        definition.connections[MonumentDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleYRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleYZRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        guard definition.hasOpening[MonumentDirection.north.rawValue],
              !(definition.connections[MonumentDirection.north.rawValue]?.claimed ?? true),
              definition.hasOpening[MonumentDirection.up.rawValue],
              !(definition.connections[MonumentDirection.up.rawValue]?.claimed ?? true),
              let north = definition.connections[MonumentDirection.north.rawValue]
        else {
            return false
        }
        return north.hasOpening[MonumentDirection.up.rawValue] && !(north.connections[MonumentDirection.up.rawValue]?.claimed ?? true)
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        definition.connections[MonumentDirection.north.rawValue]?.claimed = true
        definition.connections[MonumentDirection.up.rawValue]?.claimed = true
        definition.connections[MonumentDirection.north.rawValue]?.connections[MonumentDirection.up.rawValue]?.claimed = true
        return OceanMonumentDoubleYZRoom(orientation: orientation, definition: definition)
    }
}

private struct FitDoubleZRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        definition.hasOpening[MonumentDirection.north.rawValue] && !(definition.connections[MonumentDirection.north.rawValue]?.claimed ?? true)
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        let source: RoomDefinition
        if !definition.hasOpening[MonumentDirection.north.rawValue] || (definition.connections[MonumentDirection.north.rawValue]?.claimed ?? true) {
            source = definition.connections[MonumentDirection.south.rawValue]!
        } else {
            source = definition
        }
        source.claimed = true
        source.connections[MonumentDirection.north.rawValue]?.claimed = true
        return OceanMonumentDoubleZRoom(orientation: orientation, definition: source)
    }
}

private struct FitSimpleRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool { true }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        return OceanMonumentSimpleRoom(orientation: orientation, definition: definition, random: &random)
    }
}

private struct FitSimpleTopRoom: MonumentRoomFitter {
    func fits(_ definition: RoomDefinition) -> Bool {
        !definition.hasOpening[MonumentDirection.west.rawValue]
            && !definition.hasOpening[MonumentDirection.east.rawValue]
            && !definition.hasOpening[MonumentDirection.north.rawValue]
            && !definition.hasOpening[MonumentDirection.south.rawValue]
            && !definition.hasOpening[MonumentDirection.up.rawValue]
    }

    func create(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) -> PlacedPiece {
        definition.claimed = true
        return OceanMonumentSimpleTopRoom(orientation: orientation, definition: definition)
    }
}

private class PlacedPiece {
    static let baseGray = OceanMonumentBlocks.prismarineState
    static let baseLight = OceanMonumentBlocks.prismarineBricksState
    static let baseBlack = OceanMonumentBlocks.darkPrismarineState
    static let dotDecoration = OceanMonumentBlocks.prismarineBricksState
    static let lampBlock = OceanMonumentBlocks.seaLanternState
    static let fillBlock = OceanMonumentBlocks.waterState
    static let fillKeep: Set<String> = [
        "minecraft:ice",
        "minecraft:packed_ice",
        "minecraft:blue_ice",
        "minecraft:water"
    ]

    let kind: OceanMonumentPieceKind
    let orientation: HorizontalDirection
    var boundingBox: MonumentBoundingBox
    let roomDefinition: RoomDefinition?
    let design: Int?

    init(kind: OceanMonumentPieceKind, orientation: HorizontalDirection, boundingBox: MonumentBoundingBox, roomDefinition: RoomDefinition? = nil, design: Int? = nil) {
        self.kind = kind
        self.orientation = orientation
        self.boundingBox = boundingBox
        self.roomDefinition = roomDefinition
        self.design = design
    }

    init(
        kind: OceanMonumentPieceKind,
        orientation: HorizontalDirection,
        roomDefinition: RoomDefinition,
        roomWidth: Int32,
        roomHeight: Int32,
        roomDepth: Int32,
        design: Int? = nil
    ) {
        self.kind = kind
        self.orientation = orientation
        self.boundingBox = PlacedPiece.roomBoundingBox(
            orientation: orientation,
            roomDefinition: roomDefinition,
            roomWidth: roomWidth,
            roomHeight: roomHeight,
            roomDepth: roomDepth
        )
        self.roomDefinition = roomDefinition
        self.design = design
    }

    class func roomBoundingBox(
        orientation: HorizontalDirection,
        roomDefinition: RoomDefinition,
        roomWidth: Int32,
        roomHeight: Int32,
        roomDepth: Int32
    ) -> MonumentBoundingBox {
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

    func graphPiece() -> OceanMonumentGraphPiece {
        OceanMonumentGraphPiece(
            kind: self.kind,
            orientation: self.orientation.publicValue,
            boundingBox: self.boundingBox.publicValue,
            roomIndex: self.roomDefinition?.index,
            design: self.design
        )
    }

    func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
    }

    func getWorldX(_ x: Int32, _ z: Int32) -> Int32 {
        switch self.orientation {
        case .north, .south:
            return self.boundingBox.minX + x
        case .west:
            return self.boundingBox.maxX - z
        case .east:
            return self.boundingBox.minX + z
        }
    }

    func getWorldY(_ y: Int32) -> Int32 {
        self.boundingBox.minY + y
    }

    func getWorldZ(_ x: Int32, _ z: Int32) -> Int32 {
        switch self.orientation {
        case .north:
            return self.boundingBox.maxZ - z
        case .south:
            return self.boundingBox.minZ + z
        case .west, .east:
            return self.boundingBox.minZ + x
        }
    }

    func getWorldPos(_ x: Int32, _ y: Int32, _ z: Int32) -> PosInt3D {
        PosInt3D(x: self.getWorldX(x, z), y: self.getWorldY(y), z: self.getWorldZ(x, z))
    }

    func placeBlock(_ world: MonumentWorld, _ state: BlockState, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: MonumentBoundingBox) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        world.setBlock(state, at: pos)
    }

    func getBlock(_ world: MonumentWorld, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: MonumentBoundingBox) -> BlockState {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else {
            return OceanMonumentBlocks.airState
        }
        return world.block(at: pos)
    }

    func generateBox(
        _ world: MonumentWorld,
        _ chunkBox: MonumentBoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        _ boundary: BlockState,
        _ interior: BlockState
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    let block = (x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1) ? boundary : interior
                    self.placeBlock(world, block, x, y, z, chunkBox)
                }
            }
        }
    }

    func generateWaterBox(
        _ world: MonumentWorld,
        _ chunkBox: MonumentBoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    let block = self.getBlock(world, x, y, z, chunkBox)
                    if !Self.fillKeep.contains(block.type.id) {
                        if self.getWorldY(y) >= world.seaLevel && !statesEqual(block, Self.fillBlock) {
                            self.placeBlock(world, OceanMonumentBlocks.airState, x, y, z, chunkBox)
                        } else {
                            self.placeBlock(world, Self.fillBlock, x, y, z, chunkBox)
                        }
                    }
                }
            }
        }
    }

    func generateBoxOnFillOnly(
        _ world: MonumentWorld,
        _ chunkBox: MonumentBoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        _ state: BlockState
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    if statesEqual(self.getBlock(world, x, y, z, chunkBox), Self.fillBlock) {
                        self.placeBlock(world, state, x, y, z, chunkBox)
                    }
                }
            }
        }
    }

    func fillColumnDown(_ world: MonumentWorld, _ state: BlockState, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: MonumentBoundingBox) {
        var pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        while pos.y > world.minimumWorldY + 1 && world.isReplaceableForStructure(world.block(at: pos)) {
            world.setBlock(state, at: pos)
            pos = PosInt3D(x: pos.x, y: pos.y - 1, z: pos.z)
        }
    }

    func generateDefaultFloor(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox, _ xOff: Int32, _ zOff: Int32, _ downOpening: Bool) {
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

    func chunkIntersects(_ chunkBox: MonumentBoundingBox, _ x0: Int32, _ z0: Int32, _ x1: Int32, _ z1: Int32) -> Bool {
        let wx0 = self.getWorldX(x0, z0)
        let wz0 = self.getWorldZ(x0, z0)
        let wx1 = self.getWorldX(x1, z1)
        let wz1 = self.getWorldZ(x1, z1)
        return chunkBox.intersects(minX: min(wx0, wx1), minZ: min(wz0, wz1), maxX: max(wx0, wx1), maxZ: max(wz0, wz1))
    }

    func spawnElder(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox, _ x: Int32, _ y: Int32, _ z: Int32) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        world.elderGuardians.append(pos)
    }
}

private final class MonumentBuilding: PlacedPiece {
    static let biomeRangeCheck = 29
    var sourceRoom: RoomDefinition
    var coreRoom: RoomDefinition
    var childPieces: [PlacedPiece] = []

    init(startChunk: PosInt2D, random: inout CheckedRandom) {
        let orientation = HorizontalDirection.random(using: &random)
        let west = startChunk.x * 16 - 29
        let north = startChunk.z * 16 - 29
        let box = makeBoundingBox(x: west, y: 39, z: north, orientation: orientation, width: 58, height: 23, depth: 58)

        var sourceRoomRef: RoomDefinition?
        var coreRoomRef: RoomDefinition?
        self.sourceRoom = RoomDefinition(index: 0)
        self.coreRoom = RoomDefinition(index: 0)
        super.init(kind: .monumentBuilding, orientation: orientation, boundingBox: box)

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

        let leftWing = MonumentBoundingBox.fromCorners(self.getWorldPos(1, 1, 1), self.getWorldPos(23, 8, 21))
        let rightWing = MonumentBoundingBox.fromCorners(self.getWorldPos(34, 1, 1), self.getWorldPos(56, 8, 21))
        let penthouse = MonumentBoundingBox.fromCorners(self.getWorldPos(22, 13, 22), self.getWorldPos(35, 17, 35))
        var wingRandom = Int32(bitPattern: random.next(bits: 32))
        self.childPieces.append(OceanMonumentWingRoom(orientation: orientation, boundingBox: leftWing, randomValue: wingRandom))
        wingRandom += 1
        self.childPieces.append(OceanMonumentWingRoom(orientation: orientation, boundingBox: rightWing, randomValue: wingRandom))
        self.childPieces.append(OceanMonumentPenthouse(orientation: orientation, boundingBox: penthouse))
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
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
            child.postProcess(in: world, chunkBox: chunkBox, random: &random)
        }
    }

    private static func generateRoomGraph(random: inout CheckedRandom, sourceRoom: inout RoomDefinition?, coreRoom: inout RoomDefinition?) -> [RoomDefinition] {
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
                    for direction in MonumentDirection.allCases {
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
        core.connections[MonumentDirection.east.rawValue]!.claimed = true
        core.connections[MonumentDirection.north.rawValue]!.claimed = true
        core.connections[MonumentDirection.east.rawValue]!.connections[MonumentDirection.north.rawValue]!.claimed = true
        core.connections[MonumentDirection.up.rawValue]!.claimed = true
        core.connections[MonumentDirection.east.rawValue]!.connections[MonumentDirection.up.rawValue]!.claimed = true
        core.connections[MonumentDirection.north.rawValue]!.connections[MonumentDirection.up.rawValue]!.claimed = true
        core.connections[MonumentDirection.east.rawValue]!.connections[MonumentDirection.north.rawValue]!.connections[MonumentDirection.up.rawValue]!.claimed = true

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
                    let of = MonumentDirection(rawValue: f)!.opposite.rawValue
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

    private func generateWing(_ isFlipped: Bool, _ xoff: Int32, _ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateEntranceArchs(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateEntranceWall(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateRoofPiece(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateLowerWall(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateMiddleWall(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

    private func generateUpperWall(_ world: MonumentWorld, _ chunkBox: MonumentBoundingBox) {
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

private final class OceanMonumentCoreRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .coreRoom, orientation: orientation, roomDefinition: definition, roomWidth: 2, roomHeight: 2, roomDepth: 2)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
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
        self.generateBox(world, chunkBox, 7, 4, 7, 8, 5, 8, OceanMonumentBlocks.goldBlockState, OceanMonumentBlocks.goldBlockState)
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

private final class OceanMonumentDoubleXRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .doubleXRoom, orientation: orientation, roomDefinition: definition, roomWidth: 2, roomHeight: 1, roomDepth: 1)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        let east = self.roomDefinition!.connections[MonumentDirection.east.rawValue]!
        let west = self.roomDefinition!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 8, 0, east.hasOpening[MonumentDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, west.hasOpening[MonumentDirection.down.rawValue])
        }
        if west.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 7, 4, 6, Self.baseGray)
        }
        if east.connections[MonumentDirection.up.rawValue] == nil {
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
        if west.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if west.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if west.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if east.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 0, 12, 2, 0) }
        if east.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 7, 12, 2, 7) }
        if east.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 1, 3, 15, 2, 4) }
    }
}

private final class OceanMonumentDoubleXYRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .doubleXYRoom, orientation: orientation, roomDefinition: definition, roomWidth: 2, roomHeight: 2, roomDepth: 1)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        let east = self.roomDefinition!.connections[MonumentDirection.east.rawValue]!
        let west = self.roomDefinition!
        let westUp = west.connections[MonumentDirection.up.rawValue]!
        let eastUp = east.connections[MonumentDirection.up.rawValue]!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 8, 0, east.hasOpening[MonumentDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, west.hasOpening[MonumentDirection.down.rawValue])
        }
        if westUp.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 1, 7, 8, 6, Self.baseGray)
        }
        if eastUp.connections[MonumentDirection.up.rawValue] == nil {
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
        if west.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if west.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if west.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if east.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 0, 12, 2, 0) }
        if east.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 1, 7, 12, 2, 7) }
        if east.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 1, 3, 15, 2, 4) }
        if westUp.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 0, 4, 6, 0) }
        if westUp.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 7, 4, 6, 7) }
        if westUp.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 5, 3, 0, 6, 4) }
        if eastUp.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 11, 5, 0, 12, 6, 0) }
        if eastUp.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 11, 5, 7, 12, 6, 7) }
        if eastUp.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 15, 5, 3, 15, 6, 4) }
    }
}

private final class OceanMonumentDoubleYRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .doubleYRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 2, roomDepth: 1)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[MonumentDirection.down.rawValue])
        }
        let above = self.roomDefinition!.connections[MonumentDirection.up.rawValue]!
        if above.connections[MonumentDirection.up.rawValue] == nil {
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
            if definition.hasOpening[MonumentDirection.south.rawValue] {
                self.generateBox(world, chunkBox, 2, y, 0, 2, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 5, y, 0, 5, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, y + 2, 0, 4, y + 2, 0, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 0, 7, y + 2, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 0, 7, y + 1, 0, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[MonumentDirection.north.rawValue] {
                self.generateBox(world, chunkBox, 2, y, 7, 2, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 5, y, 7, 5, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, y + 2, 7, 4, y + 2, 7, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 7, 7, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 7, 7, y + 1, 7, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[MonumentDirection.west.rawValue] {
                self.generateBox(world, chunkBox, 0, y, 2, 0, y + 2, 2, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y, 5, 0, y + 2, 5, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 2, 3, 0, y + 2, 4, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, y, 0, 0, y + 2, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, y + 1, 0, 0, y + 1, 7, Self.baseGray, Self.baseGray)
            }
            if definition.hasOpening[MonumentDirection.east.rawValue] {
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

private final class OceanMonumentDoubleYZRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .doubleYZRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 2, roomDepth: 2)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        let north = self.roomDefinition!.connections[MonumentDirection.north.rawValue]!
        let south = self.roomDefinition!
        let northUp = north.connections[MonumentDirection.up.rawValue]!
        let southUp = south.connections[MonumentDirection.up.rawValue]!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 8, north.hasOpening[MonumentDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, south.hasOpening[MonumentDirection.down.rawValue])
        }
        if southUp.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 8, 1, 6, 8, 7, Self.baseGray)
        }
        if northUp.connections[MonumentDirection.up.rawValue] == nil {
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
        if south.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if south.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
        if south.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if north.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 15, 4, 2, 15) }
        if north.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 11, 0, 2, 12) }
        if north.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 11, 7, 2, 12) }
        if southUp.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 0, 4, 6, 0) }
        if southUp.hasOpening[MonumentDirection.east.rawValue] {
            self.generateWaterBox(world, chunkBox, 7, 5, 3, 7, 6, 4)
            self.generateBox(world, chunkBox, 5, 4, 2, 6, 4, 5, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 2, 6, 3, 2, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 5, 6, 3, 5, Self.baseLight, Self.baseLight)
        }
        if southUp.hasOpening[MonumentDirection.west.rawValue] {
            self.generateWaterBox(world, chunkBox, 0, 5, 3, 0, 6, 4)
            self.generateBox(world, chunkBox, 1, 4, 2, 2, 4, 5, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 2, 1, 3, 2, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 5, 1, 3, 5, Self.baseLight, Self.baseLight)
        }
        if northUp.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 5, 15, 4, 6, 15) }
        if northUp.hasOpening[MonumentDirection.west.rawValue] {
            self.generateWaterBox(world, chunkBox, 0, 5, 11, 0, 6, 12)
            self.generateBox(world, chunkBox, 1, 4, 10, 2, 4, 13, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 10, 1, 3, 10, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 1, 1, 13, 1, 3, 13, Self.baseLight, Self.baseLight)
        }
        if northUp.hasOpening[MonumentDirection.east.rawValue] {
            self.generateWaterBox(world, chunkBox, 7, 5, 11, 7, 6, 12)
            self.generateBox(world, chunkBox, 5, 4, 10, 6, 4, 13, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 10, 6, 3, 10, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 6, 1, 13, 6, 3, 13, Self.baseLight, Self.baseLight)
        }
    }
}

private final class OceanMonumentDoubleZRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .doubleZRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 2)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        let north = self.roomDefinition!.connections[MonumentDirection.north.rawValue]!
        let south = self.roomDefinition!
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 8, north.hasOpening[MonumentDirection.down.rawValue])
            self.generateDefaultFloor(world, chunkBox, 0, 0, south.hasOpening[MonumentDirection.down.rawValue])
        }
        if south.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 7, Self.baseGray)
        }
        if north.connections[MonumentDirection.up.rawValue] == nil {
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
        if south.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
        if south.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
        if south.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
        if north.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 15, 4, 2, 15) }
        if north.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 11, 0, 2, 12) }
        if north.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 11, 7, 2, 12) }
    }
}

private final class OceanMonumentEntryRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .entryRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        self.generateBox(world, chunkBox, 0, 3, 0, 2, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 3, 0, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 2, 0, 1, 2, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 6, 2, 0, 7, 2, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 0, 0, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 7, 1, 0, 7, 1, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 0, 1, 7, 7, 3, 7, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 1, 1, 0, 2, 3, 0, Self.baseLight, Self.baseLight)
        self.generateBox(world, chunkBox, 5, 1, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
        if self.roomDefinition!.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
        if self.roomDefinition!.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 1, 2, 4) }
        if self.roomDefinition!.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 6, 1, 3, 7, 2, 4) }
    }
}

private final class OceanMonumentPenthouse: PlacedPiece {
    init(orientation: HorizontalDirection, boundingBox: MonumentBoundingBox) {
        super.init(kind: .penthouse, orientation: orientation, boundingBox: boundingBox)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
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
        self.spawnElder(world, chunkBox, 6, 1, 6)
    }
}

private final class OceanMonumentSimpleRoom: PlacedPiece {
    private let mainDesign: Int

    init(orientation: HorizontalDirection, definition: RoomDefinition, random: inout CheckedRandom) {
        let design = Int(random.next(bound: 3))
        self.mainDesign = design
        super.init(kind: .simpleRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1, design: design)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[MonumentDirection.down.rawValue])
        }
        if self.roomDefinition!.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 6, Self.baseGray)
        }
        let centerPillar = self.mainDesign != 0
            && random.next(bound: 2) == 0
            && !self.roomDefinition!.hasOpening[MonumentDirection.down.rawValue]
            && !self.roomDefinition!.hasOpening[MonumentDirection.up.rawValue]
            && self.roomDefinition!.countOpenings() > 1
        switch self.mainDesign {
        case 0:
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
            if self.roomDefinition!.hasOpening[MonumentDirection.south.rawValue] {
                self.generateBox(world, chunkBox, 3, 3, 0, 4, 3, 0, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 3, 3, 0, 4, 3, 1, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, 2, 0, 4, 2, 0, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 3, 1, 0, 4, 1, 1, Self.baseLight, Self.baseLight)
            }
            if self.roomDefinition!.hasOpening[MonumentDirection.north.rawValue] {
                self.generateBox(world, chunkBox, 3, 3, 7, 4, 3, 7, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 3, 3, 6, 4, 3, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 3, 2, 7, 4, 2, 7, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 3, 1, 6, 4, 1, 7, Self.baseLight, Self.baseLight)
            }
            if self.roomDefinition!.hasOpening[MonumentDirection.west.rawValue] {
                self.generateBox(world, chunkBox, 0, 3, 3, 0, 3, 4, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 0, 3, 3, 1, 3, 4, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, 2, 3, 0, 2, 4, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 0, 1, 3, 1, 1, 4, Self.baseLight, Self.baseLight)
            }
            if self.roomDefinition!.hasOpening[MonumentDirection.east.rawValue] {
                self.generateBox(world, chunkBox, 7, 3, 3, 7, 3, 4, Self.baseLight, Self.baseLight)
            } else {
                self.generateBox(world, chunkBox, 6, 3, 3, 7, 3, 4, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 7, 2, 3, 7, 2, 4, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 6, 1, 3, 7, 1, 4, Self.baseLight, Self.baseLight)
            }
        case 1:
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
            if !self.roomDefinition!.hasOpening[MonumentDirection.south.rawValue] {
                self.generateBox(world, chunkBox, 1, 3, 0, 6, 3, 0, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 1, 2, 0, 6, 2, 0, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 1, 1, 0, 6, 1, 0, Self.baseLight, Self.baseLight)
            }
            if !self.roomDefinition!.hasOpening[MonumentDirection.north.rawValue] {
                self.generateBox(world, chunkBox, 1, 3, 7, 6, 3, 7, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 1, 2, 7, 6, 2, 7, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 1, 1, 7, 6, 1, 7, Self.baseLight, Self.baseLight)
            }
            if !self.roomDefinition!.hasOpening[MonumentDirection.west.rawValue] {
                self.generateBox(world, chunkBox, 0, 3, 1, 0, 3, 6, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 0, 2, 1, 0, 2, 6, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 0, 1, 1, 0, 1, 6, Self.baseLight, Self.baseLight)
            }
            if !self.roomDefinition!.hasOpening[MonumentDirection.east.rawValue] {
                self.generateBox(world, chunkBox, 7, 3, 1, 7, 3, 6, Self.baseLight, Self.baseLight)
                self.generateBox(world, chunkBox, 7, 2, 1, 7, 2, 6, Self.baseGray, Self.baseGray)
                self.generateBox(world, chunkBox, 7, 1, 1, 7, 1, 6, Self.baseLight, Self.baseLight)
            }
        default:
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
            if self.roomDefinition!.hasOpening[MonumentDirection.south.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0) }
            if self.roomDefinition!.hasOpening[MonumentDirection.north.rawValue] { self.generateWaterBox(world, chunkBox, 3, 1, 7, 4, 2, 7) }
            if self.roomDefinition!.hasOpening[MonumentDirection.west.rawValue] { self.generateWaterBox(world, chunkBox, 0, 1, 3, 0, 2, 4) }
            if self.roomDefinition!.hasOpening[MonumentDirection.east.rawValue] { self.generateWaterBox(world, chunkBox, 7, 1, 3, 7, 2, 4) }
        }
        if centerPillar {
            self.generateBox(world, chunkBox, 3, 1, 3, 4, 1, 4, Self.baseLight, Self.baseLight)
            self.generateBox(world, chunkBox, 3, 2, 3, 4, 2, 4, Self.baseGray, Self.baseGray)
            self.generateBox(world, chunkBox, 3, 3, 3, 4, 3, 4, Self.baseLight, Self.baseLight)
        }
    }
}

private final class OceanMonumentSimpleTopRoom: PlacedPiece {
    init(orientation: HorizontalDirection, definition: RoomDefinition) {
        super.init(kind: .simpleTopRoom, orientation: orientation, roomDefinition: definition, roomWidth: 1, roomHeight: 1, roomDepth: 1)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        if self.roomDefinition!.index / 25 > 0 {
            self.generateDefaultFloor(world, chunkBox, 0, 0, self.roomDefinition!.hasOpening[MonumentDirection.down.rawValue])
        }
        if self.roomDefinition!.connections[MonumentDirection.up.rawValue] == nil {
            self.generateBoxOnFillOnly(world, chunkBox, 1, 4, 1, 6, 4, 6, Self.baseGray)
        }
        for x in 1...6 {
            for z in 1...6 {
                if random.next(bound: 3) != 0 {
                    let y0: Int32 = 2 + (random.next(bound: 4) == 0 ? 0 : 1)
                    self.generateBox(world, chunkBox, Int32(x), y0, Int32(z), Int32(x), 3, Int32(z), OceanMonumentBlocks.wetSpongeState, OceanMonumentBlocks.wetSpongeState)
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
        if self.roomDefinition!.hasOpening[MonumentDirection.south.rawValue] {
            self.generateWaterBox(world, chunkBox, 3, 1, 0, 4, 2, 0)
        }
    }
}

private final class OceanMonumentWingRoom: PlacedPiece {
    private let mainDesign: Int

    init(orientation: HorizontalDirection, boundingBox: MonumentBoundingBox, randomValue: Int32) {
        self.mainDesign = Int(randomValue & 1)
        super.init(kind: .wingRoom, orientation: orientation, boundingBox: boundingBox, design: self.mainDesign)
    }

    override func postProcess(in world: MonumentWorld, chunkBox: MonumentBoundingBox, random: inout CheckedRandom) {
        if self.mainDesign == 0 {
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
            self.spawnElder(world, chunkBox, 11, 2, 16)
        } else {
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
            self.spawnElder(world, chunkBox, 11, 5, 13)
        }
    }
}

private func monumentLargeFeatureRandom(worldSeed: WorldSeed, chunkX: Int32, chunkZ: Int32) -> CheckedRandom {
    var random = CheckedRandom(seed: worldSeed)
    let multiplierX = checkedRandomNextLongExact(&random)
    let multiplierZ = checkedRandomNextLongExact(&random)
    let mixed = (multiplierX &* overflow(Int64(chunkX)))
        ^ (multiplierZ &* overflow(Int64(chunkZ)))
        ^ worldSeed
    return CheckedRandom(seed: mixed)
}

private func checkedRandomNextLongExact(_ random: inout CheckedRandom) -> UInt64 {
    let high = Int64(Int32(bitPattern: random.next(bits: 32)))
    let low = Int64(Int32(bitPattern: random.next(bits: 32)))
    return UInt64(bitPattern: (high << 32) &+ low)
}

private func monumentFloorDiv(_ value: Int32, _ divisor: Int32) -> Int32 {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

private func statesEqual(_ lhs: BlockState, _ rhs: BlockState) -> Bool {
    lhs.type.id == rhs.type.id && lhs.properties == rhs.properties
}

private func monumentShuffle<T>(_ values: inout [T], random: inout CheckedRandom) {
    guard values.count > 1 else { return }
    for index in stride(from: values.count - 1, through: 1, by: -1) {
        let swapIndex = Int(random.next(bound: UInt32(index + 1)))
        if swapIndex != index {
            values.swapAt(index, swapIndex)
        }
    }
}
