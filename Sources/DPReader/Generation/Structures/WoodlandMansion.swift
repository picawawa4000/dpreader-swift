import Foundation

/// The positioned piece graph for a generated woodland mansion.
public typealias WoodlandMansionPieceGraph = PieceGraph

/// A legacy marker describing one generated woodland-mansion chest.
public struct WoodlandMansionLootChestMarker: Equatable {
    public let pos: PosInt3D
    public let lootTable: String
    public let lootSeed: Int64
}

/// A selected mansion room template and its position in the generated layout.
public struct WoodlandMansionRoomPlacement: Equatable {
    public let floor: Int
    public let templateName: String
    public let boundingBox: BoundingBox
    public let cells: [PosInt2D]

    public static func == (lhs: WoodlandMansionRoomPlacement, rhs: WoodlandMansionRoomPlacement) -> Bool {
        lhs.floor == rhs.floor
            && lhs.templateName == rhs.templateName
            && lhs.boundingBox == rhs.boundingBox
            && lhs.cells.count == rhs.cells.count
            && zip(lhs.cells, rhs.cells).allSatisfy(==)
    }

    func moved(y: Int32) -> WoodlandMansionRoomPlacement {
        WoodlandMansionRoomPlacement(
            floor: self.floor,
            templateName: self.templateName,
            boundingBox: BoundingBox(
                minX: self.boundingBox.minX,
                minY: self.boundingBox.minY + y,
                minZ: self.boundingBox.minZ,
                maxX: self.boundingBox.maxX,
                maxY: self.boundingBox.maxY + y,
                maxZ: self.boundingBox.maxZ
            ),
            cells: self.cells
        )
    }
}

/// The complete block, piece, loot, and entity-marker output of mansion generation.
public struct WoodlandMansionGenerationResult {
    public let graph: WoodlandMansionPieceGraph
    public let blocks: StructureBlockVolume
    public let chestLootMarkers: [WoodlandMansionLootChestMarker]
    public let markers: [StructureMarker]
}

/// Entry points for deterministic vanilla woodland-mansion generation.
public enum WoodlandMansion {
    static let chestLootTable = "minecraft:chests/woodland_mansion"
    private static let foundationState = BlockState(id: "minecraft:cobblestone")

    /// Generates loot chests from the selected mansion templates without placing their blocks.
    public static func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> [StructureLootContainer]? {
        guard let decoration = context.structureDecorationParameters(forStructureID: "minecraft:mansion") else {
            throw StructureGenerationError.missingStructureDecorationParameters("minecraft:mansion")
        }
        return try generateLoot(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: context,
            decoration: decoration
        )
    }

    static func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext,
        decoration: StructureDecorationParameters
    ) throws -> [StructureLootContainer]? {
        guard let graph = try generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context) else {
            return nil
        }
        let mansionPieces = graph.pieces.compactMap { $0 as? WoodlandMansionPiece }
        var containers: [StructureLootContainer] = []
        let bounds = graph.boundingBox
        for chunkZ in (bounds.minZ >> 4)...(bounds.maxZ >> 4) {
            for chunkX in (bounds.minX >> 4)...(bounds.maxX >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16,
                    minY: context.minimumWorldY,
                    minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15,
                    maxY: Int32.max,
                    maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed,
                    chunkX: chunkX,
                    chunkZ: chunkZ,
                    decoratorIndex: decoration.index,
                    decoratorStep: decoration.step
                )
                for piece in mansionPieces where piece.boundingBox.intersects(chunkBox) {
                    containers.append(contentsOf: piece.generateLoot(in: chunkBox, random: &random))
                }
            }
        }
        return containers
    }

    /// Selects mansion templates and adjusts their piece graph to terrain without placing blocks.
    public static func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> WoodlandMansionPieceGraph? {
        guard let layout = try generateLayout(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: context,
            includeAuxiliaryPieces: true,
            adjustToTerrain: true
        ) else {
            return nil
        }
        return WoodlandMansionPieceGraph(
            startChunk: startChunk,
            orientation: layout.rotation.publicDirection,
            boundingBox: combinedBounds(for: layout.pieces),
            pieces: layout.pieces
        )
    }

    /// Returns the selected room templates and their absolute bounds.
    ///
    /// Set `adjustToTerrain` to `false` to inspect the raw layout around Y zero.
    public static func generateRoomPlacements(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext,
        adjustToTerrain: Bool = true
    ) throws -> [WoodlandMansionRoomPlacement]? {
        try generateLayout(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: context,
            includeAuxiliaryPieces: adjustToTerrain,
            adjustToTerrain: adjustToTerrain
        )?.rooms
    }

    /// Generates the mansion's templates, foundation, loot chests, and entity markers.
    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> WoodlandMansionGenerationResult? {
        guard let decoration = context.structureDecorationParameters(forStructureID: "minecraft:mansion") else {
            throw StructureGenerationError.missingStructureDecorationParameters("minecraft:mansion")
        }
        return try generate(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: context,
            decoration: decoration
        )
    }

    static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext,
        decoration: StructureDecorationParameters
    ) throws -> WoodlandMansionGenerationResult? {
        guard let graph = try generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context) else {
            return nil
        }

        var random = getStructureGenerationRandom(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z,
            decoratorIndex: decoration.index,
            decoratorStep: decoration.step
        )
        let writeBounds = expandedWriteBounds(for: graph.boundingBox, minimumWorldY: context.minimumWorldY)
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY,
            volume: volume
        )
        for piece in graph.pieces {
            piece.write(in: world, chunkBox: writeBounds, random: &random)
        }
        addFoundationIfNeeded(graph: graph, in: world)

        let chestMarkers = graph.pieces.compactMap { $0 as? WoodlandMansionPiece }.flatMap(\.chestLootMarkers)
        return WoodlandMansionGenerationResult(
            graph: graph,
            blocks: volume,
            chestLootMarkers: chestMarkers,
            markers: world.markers
        )
    }

    private static func combinedBounds(for pieces: [StructurePiece]) -> BoundingBox {
        guard let first = pieces.first else {
            return BoundingBox(minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0)
        }
        return pieces.dropFirst().reduce(first.boundingBox) { partial, piece in
            partial.union(piece.boundingBox)
        }
    }

    private static func minimumSurfaceY(for bounds: BoundingBox, context: StructureGenerationContext) -> Int32 {
        min(
            surfaceY(atX: bounds.minX, z: bounds.minZ, context: context),
            surfaceY(atX: bounds.minX, z: bounds.maxZ, context: context),
            surfaceY(atX: bounds.maxX, z: bounds.minZ, context: context),
            surfaceY(atX: bounds.maxX, z: bounds.maxZ, context: context)
        )
    }

    private static func surfaceY(atX x: Int32, z: Int32, context: StructureGenerationContext) -> Int32 {
        let maxSearchY = max(Int32(319), context.seaLevel + 96)
        for y in stride(from: maxSearchY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if !state.isAir {
                return y + 1
            }
        }
        return context.minimumWorldY
    }

    private static func expandedWriteBounds(for boundingBox: BoundingBox, minimumWorldY: Int32) -> BoundingBox {
        BoundingBox(
            minX: boundingBox.minX,
            minY: minimumWorldY + 1,
            minZ: boundingBox.minZ,
            maxX: boundingBox.maxX,
            maxY: boundingBox.maxY,
            maxZ: boundingBox.maxZ
        )
    }

    private static func addFoundationIfNeeded(graph: WoodlandMansionPieceGraph, in world: StructureWorldView) {
        let overall = graph.boundingBox
        let baseY = overall.minY
        for x in overall.minX...overall.maxX {
            for z in overall.minZ...overall.maxZ {
                let basePos = PosInt3D(x: x, y: baseY, z: z)
                guard !world.block(at: basePos).isAir else { continue }
                guard graph.pieces.contains(where: { $0.boundingBox.contains(basePos) }) else { continue }

                var y = baseY - 1
                while y > world.minimumWorldY && world.isReplaceableForStructure(world.block(at: PosInt3D(x: x, y: y, z: z))) {
                    world.setBlock(Self.foundationState, at: PosInt3D(x: x, y: y, z: z))
                    y -= 1
                }
            }
        }
    }

    private static func generateLayout(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext,
        includeAuxiliaryPieces: Bool,
        adjustToTerrain: Bool
    ) throws -> WoodlandMansionLayout? {
        var random = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let rotation = MansionRotation.random(using: &random)
        let anchor = PosInt3D(x: startChunk.x &* 16 &+ 7, y: 0, z: startChunk.z &* 16 &+ 7)
        let mansionRandom = SharedCheckedRandom(base: random)
        let parameters = MansionParameters(random: mansionRandom)
        var generator = MansionLayoutGenerator(random: mansionRandom, context: context)
        let generated = try (
            includeAuxiliaryPieces
                ? generator.generatePieces(origin: anchor, rotation: rotation, parameters: parameters)
                : generator.generateRoomsOnly(origin: anchor, rotation: rotation, parameters: parameters)
        )
        guard !generated.rooms.isEmpty else {
            return nil
        }

        let pieces = generated.pieces
        var rooms = generated.rooms
        if adjustToTerrain {
            let terrainY = minimumSurfaceY(for: combinedBounds(for: pieces), context: context)
            guard terrainY >= 60 else {
                return nil
            }

            for piece in pieces {
                if let mansionPiece = piece as? WoodlandMansionPiece {
                    mansionPiece.movePlacement(byY: terrainY)
                } else {
                    piece.boundingBox.move(0, terrainY, 0)
                }
            }
            rooms = rooms.map { $0.moved(y: terrainY) }
        }

        return WoodlandMansionLayout(
            rotation: rotation,
            pieces: pieces,
            rooms: rooms
        )
    }
}

private enum MansionMirror {
    case none
    case leftRight
    case frontBack
}

private enum MansionRotation: CaseIterable {
    case none
    case clockwise90
    case clockwise180
    case counterclockwise90

    static func random<R: Random>(using random: inout R) -> MansionRotation {
        switch Int(random.next(bound: 4)) {
        case 0: return .none
        case 1: return .clockwise90
        case 2: return .clockwise180
        default: return .counterclockwise90
        }
    }

    var publicDirection: CardinalDirection {
        switch self {
        case .none: return .south
        case .clockwise90: return .west
        case .clockwise180: return .north
        case .counterclockwise90: return .east
        }
    }

    func combined(with other: MansionRotation) -> MansionRotation {
        switch (self.quarterTurns + other.quarterTurns) & 3 {
        case 0: return .none
        case 1: return .clockwise90
        case 2: return .clockwise180
        default: return .counterclockwise90
        }
    }

    func rotate(_ direction: HorizontalDirection) -> HorizontalDirection {
        switch (HorizontalDirection.allCases.firstIndex(of: direction)! + self.quarterTurns) & 3 {
        case 0: return .north
        case 1: return .east
        case 2: return .south
        default: return .west
        }
    }

    private var quarterTurns: Int {
        switch self {
        case .none: return 0
        case .clockwise90: return 1
        case .clockwise180: return 2
        case .counterclockwise90: return 3
        }
    }
}

private enum MansionDirection: CaseIterable {
    case north
    case east
    case south
    case west
    case up

    var stepX: Int32 {
        switch self {
        case .west: return -1
        case .east: return 1
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

    var horizontal: HorizontalDirection? {
        switch self {
        case .north: return .north
        case .east: return .east
        case .south: return .south
        case .west: return .west
        case .up: return nil
        }
    }

    func rotatedClockwise() -> MansionDirection {
        switch self {
        case .north: return .east
        case .east: return .south
        case .south: return .west
        case .west: return .north
        case .up: return .up
        }
    }

    func rotatedCounterclockwise() -> MansionDirection {
        switch self {
        case .north: return .west
        case .east: return .north
        case .south: return .east
        case .west: return .south
        case .up: return .up
        }
    }

    var opposite: MansionDirection {
        switch self {
        case .north: return .south
        case .east: return .west
        case .south: return .north
        case .west: return .east
        case .up: return .up
        }
    }

    /// `Direction.fromHorizontalQuarterTurns` indexes its directions in this order.
    static let horizontalQuarterTurnOrder: [MansionDirection] = [.south, .west, .north, .east]

    /// `Direction.Type.HORIZONTAL` iterates these four directions in vanilla order.
    static let horizontalIterationOrder: [MansionDirection] = [.north, .east, .south, .west]
}

private struct MansionPlacement {
    var position: PosInt3D
    var rotation: MansionRotation
    var templateName: String
}

private struct WoodlandMansionLayout {
    let rotation: MansionRotation
    let pieces: [StructurePiece]
    let rooms: [WoodlandMansionRoomPlacement]
}

private struct MansionGeneratedPieces {
    let pieces: [StructurePiece]
    let rooms: [WoodlandMansionRoomPlacement]
}

private final class WoodlandMansionPiece: StructurePiece {
    let templateName: String
    private let template: StructureTemplate
    /// Vanilla's placement origin, before a template's rotation moves its bounds.
    private var placementOrigin: PosInt3D
    private let rotation: MansionRotation
    private let mirror: MansionMirror
    private(set) var chestLootMarkers: [WoodlandMansionLootChestMarker] = []

    init(
        context: StructureGenerationContext,
        templateName: String,
        position: PosInt3D,
        rotation: MansionRotation,
        mirror: MansionMirror = .none
    ) throws {
        guard let template = context.structureTemplate(named: "minecraft:woodland_mansion/\(templateName)") else {
            throw StructureGenerationError.missingStructureTemplate("minecraft:woodland_mansion/\(templateName)")
        }
        self.templateName = templateName
        self.template = template
        self.placementOrigin = position
        self.rotation = rotation
        self.mirror = mirror
        let bounds = Self.transformedBounds(
            for: template.size,
            anchor: position,
            mirror: mirror,
            rotation: rotation
        )
        super.init(
            orientation: .south,
            boundingBox: bounds
        )
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        for block in self.template.blocks {
            guard block.state >= 0 && block.state < self.template.palette.count else {
                continue
            }
            let templateState = self.template.palette[block.state]
            let transformedPos = Self.transformedWorldPos(
                for: block.pos,
                templateSize: self.template.size,
                anchor: self.placementOrigin,
                mirror: self.mirror,
                rotation: self.rotation
            )
            let localX = transformedPos.x - self.boundingBox.minX
            let localY = transformedPos.y - self.boundingBox.minY
            let localZ = transformedPos.z - self.boundingBox.minZ

            if templateState.id == "minecraft:structure_block" {
                self.handleStructureMetadata(block.nbt, world: world, chunkBox: chunkBox, x: localX, y: localY, z: localZ, random: &random)
                continue
            }

            let transformedState = Self.transformBlockState(templateState, mirror: self.mirror, rotation: self.rotation)
            self.placeBlock(world, transformedState, localX, localY, localZ, chunkBox)
        }
    }

    func generateLoot<R: Random>(in chunkBox: BoundingBox, random: inout R) -> [StructureLootContainer] {
        var containers: [StructureLootContainer] = []

        // StructureTemplate places raw NBT chest blocks before its structure
        // metadata markers. Those decorative chests still consume a loot seed.
        for block in self.template.blocks {
            guard block.state >= 0 && block.state < self.template.palette.count,
                  block.nbt != nil,
                  self.template.palette[block.state].id == "minecraft:chest"
            else {
                continue
            }
            let pos = Self.transformedWorldPos(
                for: block.pos,
                templateSize: self.template.size,
                anchor: self.placementOrigin,
                mirror: self.mirror,
                rotation: self.rotation
            )
            if chunkBox.contains(pos) {
                _ = random.nextLong()
            }
        }

        for block in self.template.blocks {
            guard block.state >= 0 && block.state < self.template.palette.count else {
                continue
            }
            let templateState = self.template.palette[block.state]
            guard templateState.id == "minecraft:structure_block",
                  let metadata = Self.structureMetadata(from: block.nbt)
            else {
                continue
            }

            let pos = Self.transformedWorldPos(
                for: block.pos,
                templateSize: self.template.size,
                anchor: self.placementOrigin,
                mirror: self.mirror,
                rotation: self.rotation
            )
            guard chunkBox.contains(pos) else {
                continue
            }

            if Self.chestFacing(for: metadata) != nil {
                containers.append(
                    StructureLootContainer(
                        block: "minecraft:chest",
                        pos: pos,
                        lootTable: WoodlandMansion.chestLootTable,
                        lootSeed: Int64(bitPattern: random.nextLong())
                    )
                )
            }
        }
        return containers
    }

    /// Moves both the piece bounds and the template's vanilla placement origin.
    func movePlacement(byY y: Int32) {
        self.boundingBox.move(0, y, 0)
        self.placementOrigin = PosInt3D(
            x: self.placementOrigin.x,
            y: self.placementOrigin.y + y,
            z: self.placementOrigin.z
        )
    }

    private func handleStructureMetadata<R: Random>(
        _ nbt: NBTTag?,
        world: StructureWorldView,
        chunkBox: BoundingBox,
        x: Int32,
        y: Int32,
        z: Int32,
        random: inout R
    ) {
        guard let metadata = Self.structureMetadata(from: nbt) else {
            return
        }

        if let chestFacing = Self.chestFacing(for: metadata) {
            let transformedFacing = Self.transformDirection(chestFacing, mirror: self.mirror, rotation: self.rotation)
            let lootSeed = Int64(bitPattern: random.nextLong())
            let state = BlockState(
                id: "minecraft:chest",
                properties: ["facing": transformedFacing.rawValue]
            )
            self.placeBlock(world, state, x, y, z, chunkBox)
            self.chestLootMarkers.append(
                WoodlandMansionLootChestMarker(
                    pos: self.getWorldPos(x, y, z),
                    lootTable: WoodlandMansion.chestLootTable,
                    lootSeed: lootSeed
                )
            )
            return
        }

        switch metadata {
        case "Mage":
            self.placeMarker(world, chunkBox, x, y, z, represents: "minecraft:evoker")
        case "Warrior":
            self.placeMarker(world, chunkBox, x, y, z, represents: "minecraft:vindicator")
        case "Group of Allays":
            let count = Int(random.next(bound: 3)) + 1
            for _ in 0..<count {
                self.placeMarker(world, chunkBox, x, y, z, represents: "minecraft:allay")
            }
        default:
            return
        }
    }

    private static func structureMetadata(from nbt: NBTTag?) -> String? {
        guard case .compound(let values)? = nbt,
              case .string(let metadata)? = values["metadata"]
        else {
            return nil
        }
        return metadata
    }

    private static func chestFacing(for metadata: String) -> CardinalDirection? {
        switch metadata {
        case "ChestWest": return .west
        case "ChestEast": return .east
        case "ChestNorth": return .north
        case "ChestSouth": return .south
        default: return nil
        }
    }

    private static func transformedWorldPos(
        for pos: PosInt3D,
        templateSize: PosInt3D,
        anchor: PosInt3D,
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> PosInt3D {
        let transformed = transformTemplatePositionAroundOrigin(pos, mirror: mirror, rotation: rotation)
        return PosInt3D(
            x: anchor.x + transformed.x,
            y: anchor.y + transformed.y,
            z: anchor.z + transformed.z
        )
    }

    private static func transformedBounds(
        for size: PosInt3D,
        anchor: PosInt3D,
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> BoundingBox {
        let corners = [
            PosInt3D(x: 0, y: 0, z: 0),
            PosInt3D(x: size.x - 1, y: 0, z: 0),
            PosInt3D(x: 0, y: 0, z: size.z - 1),
            PosInt3D(x: size.x - 1, y: 0, z: size.z - 1)
        ].map { corner in
            transformTemplatePositionAroundOrigin(corner, mirror: mirror, rotation: rotation)
        }
        let xs = corners.map(\.x)
        let zs = corners.map(\.z)
        return BoundingBox(
            minX: anchor.x + (xs.min() ?? 0),
            minY: anchor.y,
            minZ: anchor.z + (zs.min() ?? 0),
            maxX: anchor.x + (xs.max() ?? 0),
            maxY: anchor.y + size.y - 1,
            maxZ: anchor.z + (zs.max() ?? 0)
        )
    }

    /// Matches `StructureTemplate.transform` with a zero pivot.  Placement
    /// offsets are rotated around the template origin rather than translated
    /// back into a positive local bounding box.
    fileprivate static func transformTemplatePositionAroundOrigin(
        _ pos: PosInt3D,
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> PosInt3D {
        var x = pos.x
        let y = pos.y
        var z = pos.z

        switch mirror {
        case .none:
            break
        case .leftRight:
            z = -z
        case .frontBack:
            x = -x
        }

        switch rotation {
        case .none:
            return PosInt3D(x: x, y: y, z: z)
        case .clockwise90:
            return PosInt3D(x: -z, y: y, z: x)
        case .clockwise180:
            return PosInt3D(x: -x, y: y, z: -z)
        case .counterclockwise90:
            return PosInt3D(x: z, y: y, z: -x)
        }
    }

    fileprivate static func applyTransformedOffset(
        _ pos: PosInt3D,
        size: PosInt3D,
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> PosInt3D {
        let offsetX = size.x - 1
        let offsetZ = size.z - 1
        let mirrorX = mirror == .frontBack ? offsetX : 0
        let mirrorZ = mirror == .leftRight ? offsetZ : 0

        switch rotation {
        case .none:
            return PosInt3D(x: pos.x + mirrorX, y: pos.y, z: pos.z + mirrorZ)
        case .clockwise90:
            return PosInt3D(x: pos.x + offsetZ - mirrorZ, y: pos.y, z: pos.z + mirrorX)
        case .clockwise180:
            return PosInt3D(x: pos.x + offsetX - mirrorX, y: pos.y, z: pos.z + offsetZ - mirrorZ)
        case .counterclockwise90:
            return PosInt3D(x: pos.x + mirrorZ, y: pos.y, z: pos.z + offsetX - mirrorX)
        }
    }

    private static func transformBlockState(_ state: BlockState, mirror: MansionMirror, rotation: MansionRotation) -> BlockState {
        guard var properties = state.properties else {
            return state
        }

        if let facing = properties["facing"], let transformedFacing = transformFacingValue(facing, mirror: mirror, rotation: rotation) {
            properties["facing"] = transformedFacing
        }
        if let axis = properties["axis"] {
            properties["axis"] = transformAxisValue(axis, rotation: rotation)
        }
        if let rotationValue = properties["rotation"], let intValue = Int(rotationValue) {
            properties["rotation"] = String(transformRotationValue(intValue, mirror: mirror, rotation: rotation))
        }
        if let shape = properties["shape"] {
            properties["shape"] = transformShapeValue(shape, blockID: state.id, mirror: mirror, rotation: rotation)
        }
        if let hinge = properties["hinge"], mirror != .none {
            properties["hinge"] = hinge == "left" ? "right" : hinge == "right" ? "left" : hinge
        }
        properties = transformDirectionalProperties(properties, mirror: mirror, rotation: rotation)

        return BlockState(id: state.id, properties: properties)
    }

    private static func transformFacingValue(_ value: String, mirror: MansionMirror, rotation: MansionRotation) -> String? {
        switch value {
        case "north", "south", "east", "west":
            return transformDirection(CardinalDirection(rawValue: value)!, mirror: mirror, rotation: rotation).rawValue
        case "up", "down":
            return value
        default:
            return nil
        }
    }

    private static func transformAxisValue(_ value: String, rotation: MansionRotation) -> String {
        switch (value, rotation) {
        case ("x", .clockwise90), ("x", .counterclockwise90):
            return "z"
        case ("z", .clockwise90), ("z", .counterclockwise90):
            return "x"
        default:
            return value
        }
    }

    private static func transformRotationValue(_ value: Int, mirror: MansionMirror, rotation: MansionRotation) -> Int {
        let normalized = ((value % 16) + 16) % 16
        let mirrored: Int
        switch mirror {
        case .none:
            mirrored = normalized
        case .leftRight:
            let halfTurn = 8
            let shifted = normalized > halfTurn ? normalized - 16 : normalized
            mirrored = (halfTurn - shifted + 16) % 16
        case .frontBack:
            mirrored = (16 - normalized) % 16
        }
        return (mirrored + rotationQuarterTurns(rotation) * 4) % 16
    }

    private static func transformShapeValue(
        _ value: String,
        blockID: String,
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> String {
        if blockID.hasSuffix("_stairs") {
            if mirror != .none {
                switch value {
                case "inner_left": return "inner_right"
                case "inner_right": return "inner_left"
                case "outer_left": return "outer_right"
                case "outer_right": return "outer_left"
                default: return value
                }
            }
            return value
        }

        if blockID == "minecraft:rail" {
            let mirrored: String
            switch mirror {
            case .none:
                mirrored = value
            case .leftRight:
                switch value {
                case "ascending_north": mirrored = "ascending_south"
                case "ascending_south": mirrored = "ascending_north"
                default: mirrored = value
                }
            case .frontBack:
                switch value {
                case "ascending_east": mirrored = "ascending_west"
                case "ascending_west": mirrored = "ascending_east"
                default: mirrored = value
                }
            }

            switch rotation {
            case .none:
                return mirrored
            case .clockwise90, .counterclockwise90:
                switch mirrored {
                case "north_south": return "east_west"
                case "east_west": return "north_south"
                case "ascending_north": return "ascending_east"
                case "ascending_east": return "ascending_south"
                case "ascending_south": return "ascending_west"
                case "ascending_west": return "ascending_north"
                default: return mirrored
                }
            case .clockwise180:
                switch mirrored {
                case "ascending_north": return "ascending_south"
                case "ascending_south": return "ascending_north"
                case "ascending_east": return "ascending_west"
                case "ascending_west": return "ascending_east"
                default: return mirrored
                }
            }
        }

        return value
    }

    private static func transformDirectionalProperties(
        _ properties: [String: String],
        mirror: MansionMirror,
        rotation: MansionRotation
    ) -> [String: String] {
        let directionKeys = ["north", "east", "south", "west"]
        guard directionKeys.contains(where: { properties[$0] != nil }) else {
            return properties
        }

        var transformed = properties
        var originals: [String: String] = [:]
        for key in directionKeys {
            if let value = properties[key] {
                originals[key] = value
            }
        }
        for key in directionKeys {
            transformed.removeValue(forKey: key)
        }
        for (key, value) in originals {
            let direction = CardinalDirection(rawValue: key)!
            let mappedDirection = transformDirection(direction, mirror: mirror, rotation: rotation)
            transformed[mappedDirection.rawValue] = value
        }
        return transformed
    }

    private static func transformDirection(_ direction: CardinalDirection, mirror: MansionMirror, rotation: MansionRotation) -> CardinalDirection {
        var horizontal = horizontalDirection(for: direction)
        switch mirror {
        case .none:
            break
        case .leftRight:
            switch horizontal {
            case .north: horizontal = .south
            case .south: horizontal = .north
            default: break
            }
        case .frontBack:
            switch horizontal {
            case .east: horizontal = .west
            case .west: horizontal = .east
            default: break
            }
        }
        return rotation.rotate(horizontal).publicValue
    }

    private static func horizontalDirection(for direction: CardinalDirection) -> HorizontalDirection {
        switch direction {
        case .north: return .north
        case .east: return .east
        case .south: return .south
        case .west: return .west
        }
    }

    private static func rotationQuarterTurns(_ rotation: MansionRotation) -> Int {
        switch rotation {
        case .none: return 0
        case .clockwise90: return 1
        case .clockwise180: return 2
        case .counterclockwise90: return 3
        }
    }
}

private struct FlagMatrix {
    let sizeI: Int
    let sizeJ: Int
    private let fallback: Int
    private var array: [[Int]]

    init(_ sizeI: Int, _ sizeJ: Int, _ fallback: Int) {
        self.sizeI = sizeI
        self.sizeJ = sizeJ
        self.fallback = fallback
        self.array = Array(repeating: Array(repeating: 0, count: sizeJ), count: sizeI)
    }

    mutating func set(_ i: Int, _ j: Int, _ value: Int) {
        guard i >= 0 && i < self.sizeI && j >= 0 && j < self.sizeJ else { return }
        self.array[i][j] = value
    }

    mutating func fill(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, _ value: Int) {
        for j in j0...j1 {
            for i in i0...i1 {
                self.set(i, j, value)
            }
        }
    }

    func get(_ i: Int, _ j: Int) -> Int {
        guard i >= 0 && i < self.sizeI && j >= 0 && j < self.sizeJ else {
            return self.fallback
        }
        return self.array[i][j]
    }

    mutating func update(_ i: Int, _ j: Int, expected: Int, newValue: Int) {
        if self.get(i, j) == expected {
            self.set(i, j, newValue)
        }
    }

    func anyMatchAround(_ i: Int, _ j: Int, value: Int) -> Bool {
        self.get(i - 1, j) == value
            || self.get(i + 1, j) == value
            || self.get(i, j + 1) == value
            || self.get(i, j - 1) == value
    }
}

private final class SharedCheckedRandom: Random {
    typealias Splitter = CheckedRandomSplitter

    private var base: CheckedRandom

    init(base: CheckedRandom) {
        self.base = base
    }

    func next(bound: UInt32) -> UInt32 {
        self.base.next(bound: bound)
    }

    func nextLong() -> UInt64 {
        self.base.nextLong()
    }

    func nextInt32() -> Int32 {
        self.base.nextInt32()
    }

    func nextFloat() -> Float {
        self.base.nextFloat()
    }

    func nextBoolean() -> Bool {
        self.base.nextBoolean()
    }

    func nextDouble() -> Double {
        self.base.nextDouble()
    }

    func nextSplitter() -> CheckedRandomSplitter {
        CheckedRandomSplitter(seed: self.base.nextLong())
    }

    func skip(calls: UInt) {
        self.base.skip(calls: calls)
    }
}

private struct MansionParameters {
    static let size = 11
    static let unset = 0
    static let corridor = 1
    static let room = 2
    static let staircase = 3
    static let unused = 4
    static let outside = 5

    static let smallRoomFlag = 0x10000
    static let mediumRoomFlag = 0x20000
    static let bigRoomFlag = 0x40000
    static let originCellFlag = 0x100000
    static let entranceCellFlag = 0x200000
    static let staircaseCellFlag = 0x400000
    static let carpetCellFlag = 0x800000
    static let roomSizeMask = 0xF0000
    static let roomIDMask = 0xFFFF

    var random: SharedCheckedRandom
    var baseLayout: FlagMatrix
    var thirdFloorLayout: FlagMatrix
    var roomFlagsByFloor: [FlagMatrix]
    let entranceI = 7
    let entranceJ = 4

    init(random: SharedCheckedRandom) {
        self.random = random
        self.baseLayout = FlagMatrix(Self.size, Self.size, Self.outside)
        self.thirdFloorLayout = FlagMatrix(Self.size, Self.size, Self.outside)
        self.roomFlagsByFloor = [
            FlagMatrix(Self.size, Self.size, Self.outside),
            FlagMatrix(Self.size, Self.size, Self.outside),
            FlagMatrix(Self.size, Self.size, Self.outside)
        ]

        self.baseLayout.fill(self.entranceI, self.entranceJ, self.entranceI + 1, self.entranceJ + 1, Self.staircase)
        self.baseLayout.fill(self.entranceI - 1, self.entranceJ, self.entranceI - 1, self.entranceJ + 1, Self.room)
        self.baseLayout.fill(self.entranceI + 2, self.entranceJ - 2, self.entranceI + 3, self.entranceJ + 3, Self.outside)
        self.baseLayout.fill(self.entranceI + 1, self.entranceJ - 2, self.entranceI + 1, self.entranceJ - 1, Self.corridor)
        self.baseLayout.fill(self.entranceI + 1, self.entranceJ + 2, self.entranceI + 1, self.entranceJ + 3, Self.corridor)
        self.baseLayout.set(self.entranceI - 1, self.entranceJ - 1, Self.corridor)
        self.baseLayout.set(self.entranceI - 1, self.entranceJ + 2, Self.corridor)
        self.baseLayout.fill(0, 0, 11, 1, Self.outside)
        self.baseLayout.fill(0, 9, 11, 11, Self.outside)
        var baseLayout = self.baseLayout
        self.layoutCorridor(layout: &baseLayout, i: self.entranceI, j: self.entranceJ - 2, direction: .west, length: 6)
        self.layoutCorridor(layout: &baseLayout, i: self.entranceI, j: self.entranceJ + 3, direction: .west, length: 6)
        self.layoutCorridor(layout: &baseLayout, i: self.entranceI - 2, j: self.entranceJ - 1, direction: .west, length: 3)
        self.layoutCorridor(layout: &baseLayout, i: self.entranceI - 2, j: self.entranceJ + 2, direction: .west, length: 3)

        while self.adjustLayoutWithRooms(layout: &baseLayout) {
        }
        self.baseLayout = baseLayout

        var floor0Flags = self.roomFlagsByFloor[0]
        self.updateRoomFlags(layout: self.baseLayout, roomFlags: &floor0Flags)
        floor0Flags.fill(self.entranceI + 1, self.entranceJ, self.entranceI + 1, self.entranceJ + 1, Self.carpetCellFlag)
        self.roomFlagsByFloor[0] = floor0Flags

        var floor1Flags = self.roomFlagsByFloor[1]
        self.updateRoomFlags(layout: self.baseLayout, roomFlags: &floor1Flags)
        floor1Flags.fill(self.entranceI + 1, self.entranceJ, self.entranceI + 1, self.entranceJ + 1, Self.carpetCellFlag)
        self.roomFlagsByFloor[1] = floor1Flags

        self.layoutThirdFloor()
        var floor2Flags = self.roomFlagsByFloor[2]
        self.updateRoomFlags(layout: self.thirdFloorLayout, roomFlags: &floor2Flags)
        self.roomFlagsByFloor[2] = floor2Flags
    }

    static func isInsideMansion(_ layout: FlagMatrix, _ i: Int, _ j: Int) -> Bool {
        let value = layout.get(i, j)
        return value == corridor || value == room || value == staircase || value == unused
    }

    func isRoomId(_ i: Int, _ j: Int, floor: Int, roomID: Int) -> Bool {
        (self.roomFlagsByFloor[floor].get(i, j) & Self.roomIDMask) == roomID
    }

    func findConnectedRoomDirection(_ i: Int, _ j: Int, floor: Int, roomID: Int) -> MansionDirection? {
        for direction in MansionDirection.horizontalIterationOrder {
            if self.isRoomId(i + Int(direction.stepX), j + Int(direction.stepZ), floor: floor, roomID: roomID) {
                return direction
            }
        }
        return nil
    }

    func roomCells(floor: Int, roomID: Int) -> [PosInt2D] {
        var result: [PosInt2D] = []
        for j in 0..<Self.size {
            for i in 0..<Self.size where self.isRoomId(i, j, floor: floor, roomID: roomID) {
                result.append(PosInt2D(x: Int32(i + 1), z: Int32(j - 1)))
            }
        }
        return result
    }

    private mutating func layoutCorridor(layout: inout FlagMatrix, i: Int, j: Int, direction: MansionDirection, length: Int) {
        guard length > 0 else { return }
        layout.set(i, j, Self.corridor)
        layout.update(i + Int(direction.stepX), j + Int(direction.stepZ), expected: Self.unset, newValue: Self.corridor)

        for _ in 0..<8 {
            let candidate = MansionDirection.horizontalQuarterTurnOrder[Int(self.random.next(bound: 4))]
            if candidate != direction.opposite && (candidate != .east || !self.random.nextBoolean()) {
                let nextI = i + Int(direction.stepX)
                let nextJ = j + Int(direction.stepZ)
                if layout.get(nextI + Int(candidate.stepX), nextJ + Int(candidate.stepZ)) == Self.unset
                    && layout.get(nextI + Int(candidate.stepX) * 2, nextJ + Int(candidate.stepZ) * 2) == Self.unset {
                    self.layoutCorridor(
                        layout: &layout,
                        i: i + Int(direction.stepX) + Int(candidate.stepX),
                        j: j + Int(direction.stepZ) + Int(candidate.stepZ),
                        direction: candidate,
                        length: length - 1
                    )
                    break
                }
            }
        }

        let right = direction.rotatedClockwise()
        let left = direction.rotatedCounterclockwise()
        layout.update(i + Int(right.stepX), j + Int(right.stepZ), expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(left.stepX), j + Int(left.stepZ), expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(direction.stepX) + Int(right.stepX), j + Int(direction.stepZ) + Int(right.stepZ), expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(direction.stepX) + Int(left.stepX), j + Int(direction.stepZ) + Int(left.stepZ), expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(direction.stepX) * 2, j + Int(direction.stepZ) * 2, expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(right.stepX) * 2, j + Int(right.stepZ) * 2, expected: Self.unset, newValue: Self.room)
        layout.update(i + Int(left.stepX) * 2, j + Int(left.stepZ) * 2, expected: Self.unset, newValue: Self.room)
    }

    private func adjustLayoutWithRooms(layout: inout FlagMatrix) -> Bool {
        var changed = false
        for j in 0..<layout.sizeJ {
            for i in 0..<layout.sizeI {
                if layout.get(i, j) == Self.unset {
                    var neighbors = 0
                    neighbors += Self.isInsideMansion(layout, i + 1, j) ? 1 : 0
                    neighbors += Self.isInsideMansion(layout, i - 1, j) ? 1 : 0
                    neighbors += Self.isInsideMansion(layout, i, j + 1) ? 1 : 0
                    neighbors += Self.isInsideMansion(layout, i, j - 1) ? 1 : 0
                    if neighbors >= 3 {
                        layout.set(i, j, Self.room)
                        changed = true
                    } else if neighbors == 2 {
                        var diagonals = 0
                        diagonals += Self.isInsideMansion(layout, i + 1, j + 1) ? 1 : 0
                        diagonals += Self.isInsideMansion(layout, i - 1, j + 1) ? 1 : 0
                        diagonals += Self.isInsideMansion(layout, i + 1, j - 1) ? 1 : 0
                        diagonals += Self.isInsideMansion(layout, i - 1, j - 1) ? 1 : 0
                        if diagonals <= 1 {
                            layout.set(i, j, Self.room)
                            changed = true
                        }
                    }
                }
            }
        }
        return changed
    }

    private mutating func layoutThirdFloor() {
        var candidates: [(Int, Int)] = []
        let secondFloor = self.roomFlagsByFloor[1]
        for j in 0..<self.thirdFloorLayout.sizeJ {
            for i in 0..<self.thirdFloorLayout.sizeI {
                let flags = secondFloor.get(i, j)
                let roomSize = flags & Self.roomSizeMask
                if roomSize == Self.mediumRoomFlag && (flags & Self.entranceCellFlag) == Self.entranceCellFlag {
                    candidates.append((i, j))
                }
            }
        }

        guard !candidates.isEmpty else {
            self.thirdFloorLayout.fill(0, 0, self.thirdFloorLayout.sizeI, self.thirdFloorLayout.sizeJ, Self.outside)
            return
        }

        let choice = candidates[Int(self.random.next(bound: UInt32(candidates.count)))]
        let chosenFlags = self.roomFlagsByFloor[1].get(choice.0, choice.1)
        self.roomFlagsByFloor[1].set(choice.0, choice.1, chosenFlags | Self.staircaseCellFlag)
        guard let connectedDirection = self.findConnectedRoomDirection(choice.0, choice.1, floor: 1, roomID: chosenFlags & Self.roomIDMask) else {
            self.thirdFloorLayout.fill(0, 0, self.thirdFloorLayout.sizeI, self.thirdFloorLayout.sizeJ, Self.outside)
            self.roomFlagsByFloor[1].set(choice.0, choice.1, chosenFlags)
            return
        }
        let nextI = choice.0 + Int(connectedDirection.stepX)
        let nextJ = choice.1 + Int(connectedDirection.stepZ)

        for j in 0..<self.thirdFloorLayout.sizeJ {
            for i in 0..<self.thirdFloorLayout.sizeI {
                if !Self.isInsideMansion(self.baseLayout, i, j) {
                    self.thirdFloorLayout.set(i, j, Self.outside)
                } else if i == choice.0 && j == choice.1 {
                    self.thirdFloorLayout.set(i, j, Self.staircase)
                } else if i == nextI && j == nextJ {
                    self.thirdFloorLayout.set(i, j, Self.staircase)
                    self.roomFlagsByFloor[2].set(i, j, Self.carpetCellFlag)
                }
            }
        }

        var corridorStarts: [MansionDirection] = []
        for direction in MansionDirection.horizontalIterationOrder {
            if self.thirdFloorLayout.get(nextI + Int(direction.stepX), nextJ + Int(direction.stepZ)) == Self.unset {
                corridorStarts.append(direction)
            }
        }

        guard !corridorStarts.isEmpty else {
            self.thirdFloorLayout.fill(0, 0, self.thirdFloorLayout.sizeI, self.thirdFloorLayout.sizeJ, Self.outside)
            self.roomFlagsByFloor[1].set(choice.0, choice.1, chosenFlags)
            return
        }

        let direction = corridorStarts[Int(self.random.next(bound: UInt32(corridorStarts.count)))]
        var thirdFloorLayout = self.thirdFloorLayout
        self.layoutCorridor(
            layout: &thirdFloorLayout,
            i: nextI + Int(direction.stepX),
            j: nextJ + Int(direction.stepZ),
            direction: direction,
            length: 4
        )
        while self.adjustLayoutWithRooms(layout: &thirdFloorLayout) {
        }
        self.thirdFloorLayout = thirdFloorLayout
    }

    private mutating func updateRoomFlags(layout: FlagMatrix, roomFlags: inout FlagMatrix) {
        var cells: [(Int, Int)] = []
        for j in 0..<layout.sizeJ {
            for i in 0..<layout.sizeI where layout.get(i, j) == Self.room {
                cells.append((i, j))
            }
        }
        mansionShuffle(&cells, random: &self.random)

        var nextRoomID = 10
        for (i, j) in cells where roomFlags.get(i, j) == Self.unset {
            var minI = i
            var maxI = i
            var minJ = j
            var maxJ = j
            var roomSize = Self.smallRoomFlag

            if roomFlags.get(i + 1, j) == Self.unset
                && roomFlags.get(i, j + 1) == Self.unset
                && roomFlags.get(i + 1, j + 1) == Self.unset
                && layout.get(i + 1, j) == Self.room
                && layout.get(i, j + 1) == Self.room
                && layout.get(i + 1, j + 1) == Self.room {
                maxI = i + 1
                maxJ = j + 1
                roomSize = Self.bigRoomFlag
            } else if roomFlags.get(i - 1, j) == Self.unset
                && roomFlags.get(i, j + 1) == Self.unset
                && roomFlags.get(i - 1, j + 1) == Self.unset
                && layout.get(i - 1, j) == Self.room
                && layout.get(i, j + 1) == Self.room
                && layout.get(i - 1, j + 1) == Self.room {
                minI = i - 1
                maxJ = j + 1
                roomSize = Self.bigRoomFlag
            } else if roomFlags.get(i - 1, j) == Self.unset
                && roomFlags.get(i, j - 1) == Self.unset
                && roomFlags.get(i - 1, j - 1) == Self.unset
                && layout.get(i - 1, j) == Self.room
                && layout.get(i, j - 1) == Self.room
                && layout.get(i - 1, j - 1) == Self.room {
                minI = i - 1
                minJ = j - 1
                roomSize = Self.bigRoomFlag
            } else if roomFlags.get(i + 1, j) == Self.unset && layout.get(i + 1, j) == Self.room {
                maxI = i + 1
                roomSize = Self.mediumRoomFlag
            } else if roomFlags.get(i, j + 1) == Self.unset && layout.get(i, j + 1) == Self.room {
                maxJ = j + 1
                roomSize = Self.mediumRoomFlag
            } else if roomFlags.get(i - 1, j) == Self.unset && layout.get(i - 1, j) == Self.room {
                minI = i - 1
                roomSize = Self.mediumRoomFlag
            } else if roomFlags.get(i, j - 1) == Self.unset && layout.get(i, j - 1) == Self.room {
                minJ = j - 1
                roomSize = Self.mediumRoomFlag
            }

            var entranceI = self.random.nextBoolean() ? minI : maxI
            var entranceJ = self.random.nextBoolean() ? minJ : maxJ
            var entranceFlags = Self.entranceCellFlag

            if !layout.anyMatchAround(entranceI, entranceJ, value: Self.corridor) {
                entranceI = entranceI == minI ? maxI : minI
                entranceJ = entranceJ == minJ ? maxJ : minJ
                if !layout.anyMatchAround(entranceI, entranceJ, value: Self.corridor) {
                    entranceJ = entranceJ == minJ ? maxJ : minJ
                    if !layout.anyMatchAround(entranceI, entranceJ, value: Self.corridor) {
                        entranceI = entranceI == minI ? maxI : minI
                        entranceJ = entranceJ == minJ ? maxJ : minJ
                        if !layout.anyMatchAround(entranceI, entranceJ, value: Self.corridor) {
                            entranceFlags = 0
                            entranceI = minI
                            entranceJ = minJ
                        }
                    }
                }
            }

            for row in minJ...maxJ {
                for column in minI...maxI {
                    if column == entranceI && row == entranceJ {
                        roomFlags.set(column, row, Self.originCellFlag | entranceFlags | roomSize | nextRoomID)
                    } else {
                        roomFlags.set(column, row, roomSize | nextRoomID)
                    }
                }
            }
            nextRoomID += 1
        }
    }
}

private struct MansionLayoutGenerator {
    private var random: SharedCheckedRandom
    private let context: StructureGenerationContext
    private var entranceI = 0
    private var entranceJ = 0

    init(random: SharedCheckedRandom, context: StructureGenerationContext) {
        self.random = random
        self.context = context
    }

    mutating func generatePieces(origin: PosInt3D, rotation: MansionRotation, parameters: MansionParameters) throws -> MansionGeneratedPieces {
        var pieces: [StructurePiece] = []
        var wall = MansionPlacement(position: origin, rotation: rotation, templateName: "wall_flat")
        self.addEntrance(&pieces, wallPiece: &wall)

        var secondWall = MansionPlacement(position: PosInt3D(x: wall.position.x, y: wall.position.y + 8, z: wall.position.z), rotation: rotation, templateName: "wall_window")
        let baseLayout = parameters.baseLayout
        let thirdFloor = parameters.thirdFloorLayout
        self.entranceI = parameters.entranceI + 1
        self.entranceJ = parameters.entranceJ + 1
        let endI = parameters.entranceI + 1
        let endJ = parameters.entranceJ
        self.addOuterWall(&pieces, wallPiece: &wall, layout: baseLayout, direction: .south, startI: self.entranceI, startJ: self.entranceJ, endI: endI, endJ: endJ)
        self.addOuterWall(&pieces, wallPiece: &secondWall, layout: baseLayout, direction: .south, startI: self.entranceI, startJ: self.entranceJ, endI: endI, endJ: endJ)

        var topWall = MansionPlacement(position: PosInt3D(x: wall.position.x, y: wall.position.y + 19, z: wall.position.z), rotation: rotation, templateName: "wall_window")
        var foundThirdFloorStart = false
        for j in 0..<thirdFloor.sizeJ where !foundThirdFloorStart {
            for i in stride(from: thirdFloor.sizeI - 1, through: 0, by: -1) where !foundThirdFloorStart {
                if MansionParameters.isInsideMansion(thirdFloor, i, j) {
                    topWall.position = offset(topWall.position, direction: .south, distance: Int32(8 + (j - self.entranceJ) * 8), rotation: rotation)
                    topWall.position = offset(topWall.position, direction: .east, distance: Int32((i - self.entranceI) * 8), rotation: rotation)
                    try self.addWallPiece(&pieces, wallPiece: &topWall)
                    self.addOuterWall(&pieces, wallPiece: &topWall, layout: thirdFloor, direction: .south, startI: i, startJ: j, endI: i, endJ: j)
                    foundThirdFloorStart = true
                }
            }
        }

        try self.addRoof(&pieces, pos: PosInt3D(x: origin.x, y: origin.y + 16, z: origin.z), rotation: rotation, layout: baseLayout, nextFloorLayout: thirdFloor)
        try self.addRoof(&pieces, pos: PosInt3D(x: origin.x, y: origin.y + 27, z: origin.z), rotation: rotation, layout: thirdFloor, nextFloorLayout: nil)

        let rooms = try self.generateRoomPlacements(
            appendingPiecesTo: &pieces,
            origin: origin,
            rotation: rotation,
            parameters: parameters
        )
        return MansionGeneratedPieces(pieces: pieces, rooms: rooms)
    }

    mutating func generateRoomsOnly(origin: PosInt3D, rotation: MansionRotation, parameters: MansionParameters) throws -> MansionGeneratedPieces {
        var pieces: [StructurePiece] = []
        let rooms = try self.generateRoomPlacements(
            appendingPiecesTo: &pieces,
            origin: origin,
            rotation: rotation,
            parameters: parameters,
            includeRoomPieces: false
        )
        return MansionGeneratedPieces(pieces: [], rooms: rooms)
    }

    private mutating func generateRoomPlacements(
        appendingPiecesTo pieces: inout [StructurePiece],
        origin: PosInt3D,
        rotation: MansionRotation,
        parameters: MansionParameters,
        includeRoomPieces: Bool = true
    ) throws -> [WoodlandMansionRoomPlacement] {
        var rooms: [WoodlandMansionRoomPlacement] = []
        let baseLayout = parameters.baseLayout
        let thirdFloor = parameters.thirdFloorLayout
        let roomPools: [RoomPool] = [FirstFloorRoomPool(), SecondFloorRoomPool(), ThirdFloorRoomPool()]
        self.entranceI = parameters.entranceI + 1
        self.entranceJ = parameters.entranceJ + 1
        for floor in 0..<3 {
            let levelOrigin = PosInt3D(x: origin.x, y: origin.y + Int32(8 * floor + (floor == 2 ? 3 : 0)), z: origin.z)
            let roomFlags = parameters.roomFlagsByFloor[floor]
            let layout = floor == 2 ? thirdFloor : baseLayout
            for j in 0..<layout.sizeJ {
                for i in 0..<layout.sizeI {
                    var isThirdFloorStair = floor == 2 && layout.get(i, j) == MansionParameters.staircase
                    if layout.get(i, j) == MansionParameters.room || isThirdFloorStair {
                        let flags = roomFlags.get(i, j)
                        let roomSize = flags & MansionParameters.roomSizeMask
                        let roomID = flags & MansionParameters.roomIDMask
                        isThirdFloorStair = isThirdFloorStair && (flags & MansionParameters.carpetCellFlag) == MansionParameters.carpetCellFlag

                        var corridorEntrances: [MansionDirection] = []
                        if (flags & MansionParameters.entranceCellFlag) == MansionParameters.entranceCellFlag {
                            for direction in MansionDirection.horizontalIterationOrder {
                                if layout.get(i + Int(direction.stepX), j + Int(direction.stepZ)) == MansionParameters.corridor {
                                    corridorEntrances.append(direction)
                                }
                            }
                        }

                        var entranceDirection: MansionDirection?
                        if !corridorEntrances.isEmpty {
                            entranceDirection = corridorEntrances[Int(self.random.next(bound: UInt32(corridorEntrances.count)))]
                        } else if (flags & MansionParameters.originCellFlag) == MansionParameters.originCellFlag {
                            entranceDirection = .up
                        }

                        var roomPos = offset(levelOrigin, direction: .south, distance: Int32(8 + (j - self.entranceJ) * 8), rotation: rotation)
                        roomPos = offset(roomPos, direction: .east, distance: Int32(-1 + (i - self.entranceI) * 8), rotation: rotation)

                        if roomSize == MansionParameters.smallRoomFlag {
                            let piece = try self.makeSmallRoom(pos: roomPos, rotation: rotation, direction: entranceDirection, pool: roomPools[floor])
                            if includeRoomPieces {
                                pieces.append(piece)
                            }
                            rooms.append(
                                WoodlandMansionRoomPlacement(
                                    floor: floor,
                                    templateName: piece.templateName,
                                    boundingBox: piece.boundingBox,
                                    cells: parameters.roomCells(floor: floor, roomID: roomID)
                                )
                            )
                        } else if roomSize == MansionParameters.mediumRoomFlag, let entranceDirection, let connectedDirection = parameters.findConnectedRoomDirection(i, j, floor: floor, roomID: roomID) {
                            let staircase = (flags & MansionParameters.staircaseCellFlag) == MansionParameters.staircaseCellFlag
                            let piece = try self.makeMediumRoom(pos: roomPos, rotation: rotation, connectedRoomDirection: connectedDirection, entranceDirection: entranceDirection, pool: roomPools[floor], staircase: staircase)
                            if includeRoomPieces {
                                pieces.append(piece)
                            }
                            rooms.append(
                                WoodlandMansionRoomPlacement(
                                    floor: floor,
                                    templateName: piece.templateName,
                                    boundingBox: piece.boundingBox,
                                    cells: parameters.roomCells(floor: floor, roomID: roomID)
                                )
                            )
                        } else if roomSize == MansionParameters.bigRoomFlag, let entranceDirection {
                            if entranceDirection != .up {
                                var connectedDirection = entranceDirection.rotatedClockwise()
                                if !parameters.isRoomId(i + Int(connectedDirection.stepX), j + Int(connectedDirection.stepZ), floor: floor, roomID: roomID) {
                                    connectedDirection = connectedDirection.opposite
                                }
                                let piece = try self.makeBigRoom(pos: roomPos, rotation: rotation, connectedRoomDirection: connectedDirection, entranceDirection: entranceDirection, pool: roomPools[floor])
                                if includeRoomPieces {
                                    pieces.append(piece)
                                }
                                rooms.append(
                                    WoodlandMansionRoomPlacement(
                                        floor: floor,
                                        templateName: piece.templateName,
                                        boundingBox: piece.boundingBox,
                                        cells: parameters.roomCells(floor: floor, roomID: roomID)
                                    )
                                )
                            } else if entranceDirection == .up {
                                let piece = try self.makeBigSecretRoom(pos: roomPos, rotation: rotation, pool: roomPools[floor])
                                if includeRoomPieces {
                                    pieces.append(piece)
                                }
                                rooms.append(
                                    WoodlandMansionRoomPlacement(
                                        floor: floor,
                                        templateName: piece.templateName,
                                        boundingBox: piece.boundingBox,
                                        cells: parameters.roomCells(floor: floor, roomID: roomID)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return rooms
    }

    private mutating func addOuterWall(
        _ pieces: inout [StructurePiece],
        wallPiece: inout MansionPlacement,
        layout: FlagMatrix,
        direction: MansionDirection,
        startI: Int,
        startJ: Int,
        endI: Int,
        endJ: Int
    ) {
        var i = startI
        var j = startJ
        var direction = direction
        let initialDirection = direction

        repeat {
            if !MansionParameters.isInsideMansion(layout, i + Int(direction.stepX), j + Int(direction.stepZ)) {
                self.turnLeft(&pieces, wallPiece: &wallPiece)
                direction = direction.rotatedClockwise()
                if i != endI || j != endJ || initialDirection != direction {
                    try? self.addWallPiece(&pieces, wallPiece: &wallPiece)
                }
            } else if MansionParameters.isInsideMansion(layout, i + Int(direction.stepX), j + Int(direction.stepZ))
                && MansionParameters.isInsideMansion(
                    layout,
                    i + Int(direction.stepX) + Int(direction.rotatedCounterclockwise().stepX),
                    j + Int(direction.stepZ) + Int(direction.rotatedCounterclockwise().stepZ)
                ) {
                self.turnRight(wallPiece: &wallPiece)
                i += Int(direction.stepX)
                j += Int(direction.stepZ)
                direction = direction.rotatedCounterclockwise()
            } else {
                i += Int(direction.stepX)
                j += Int(direction.stepZ)
                if i != endI || j != endJ || initialDirection != direction {
                    try? self.addWallPiece(&pieces, wallPiece: &wallPiece)
                }
            }
        } while i != endI || j != endJ || initialDirection != direction
    }

    private mutating func addRoof(
        _ pieces: inout [StructurePiece],
        pos: PosInt3D,
        rotation: MansionRotation,
        layout: FlagMatrix,
        nextFloorLayout: FlagMatrix?
    ) throws {
        for j in 0..<layout.sizeJ {
            for i in 0..<layout.sizeI {
                var roofPos = offset(pos, direction: .south, distance: Int32(8 + (j - self.entranceJ) * 8), rotation: rotation)
                roofPos = offset(roofPos, direction: .east, distance: Int32((i - self.entranceI) * 8), rotation: rotation)
                let hasUpperFloor = nextFloorLayout.map { MansionParameters.isInsideMansion($0, i, j) } ?? false
                if MansionParameters.isInsideMansion(layout, i, j) && !hasUpperFloor {
                    pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof", position: roofPos.offsetY(3), rotation: rotation))

                    if !MansionParameters.isInsideMansion(layout, i + 1, j) {
                        pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_front", position: offset(roofPos, direction: .east, distance: 6, rotation: rotation), rotation: rotation))
                    }
                    if !MansionParameters.isInsideMansion(layout, i - 1, j) {
                        let westPos = offset(offset(roofPos, direction: .east, distance: 0, rotation: rotation), direction: .south, distance: 7, rotation: rotation)
                        pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_front", position: westPos, rotation: rotation.combined(with: .clockwise180)))
                    }
                    if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                        pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_front", position: offset(roofPos, direction: .west, distance: 1, rotation: rotation), rotation: rotation.combined(with: .counterclockwise90)))
                    }
                    if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                        let southPos = offset(offset(roofPos, direction: .east, distance: 6, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
                        pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_front", position: southPos, rotation: rotation.combined(with: .clockwise90)))
                    }
                }
            }
        }

        if let nextFloorLayout {
            for j in 0..<layout.sizeJ {
                for i in 0..<layout.sizeI {
                    var wallPos = offset(pos, direction: .south, distance: Int32(8 + (j - self.entranceJ) * 8), rotation: rotation)
                    wallPos = offset(wallPos, direction: .east, distance: Int32((i - self.entranceI) * 8), rotation: rotation)
                    let hasUpperFloor = MansionParameters.isInsideMansion(nextFloorLayout, i, j)
                    if MansionParameters.isInsideMansion(layout, i, j) && hasUpperFloor {
                        if !MansionParameters.isInsideMansion(layout, i + 1, j) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall", position: offset(wallPos, direction: .east, distance: 7, rotation: rotation), rotation: rotation))
                        }
                        if !MansionParameters.isInsideMansion(layout, i - 1, j) {
                            let westPos = offset(offset(wallPos, direction: .west, distance: 1, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall", position: westPos, rotation: rotation.combined(with: .clockwise180)))
                        }
                        if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                            let northPos = offset(offset(wallPos, direction: .west, distance: 0, rotation: rotation), direction: .north, distance: 1, rotation: rotation)
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall", position: northPos, rotation: rotation.combined(with: .counterclockwise90)))
                        }
                        if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                            let southPos = offset(offset(wallPos, direction: .east, distance: 6, rotation: rotation), direction: .south, distance: 7, rotation: rotation)
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall", position: southPos, rotation: rotation.combined(with: .clockwise90)))
                        }

                        if !MansionParameters.isInsideMansion(layout, i + 1, j) {
                            if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                                let cornerPos = offset(offset(wallPos, direction: .east, distance: 7, rotation: rotation), direction: .north, distance: 2, rotation: rotation)
                                pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall_corner", position: cornerPos, rotation: rotation))
                            }
                            if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                                let cornerPos = offset(offset(wallPos, direction: .east, distance: 8, rotation: rotation), direction: .south, distance: 7, rotation: rotation)
                                pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall_corner", position: cornerPos, rotation: rotation.combined(with: .clockwise90)))
                            }
                        }

                        if !MansionParameters.isInsideMansion(layout, i - 1, j) {
                            if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                                let cornerPos = offset(offset(wallPos, direction: .west, distance: 2, rotation: rotation), direction: .north, distance: 1, rotation: rotation)
                                pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall_corner", position: cornerPos, rotation: rotation.combined(with: .counterclockwise90)))
                            }
                            if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                                let cornerPos = offset(offset(wallPos, direction: .west, distance: 1, rotation: rotation), direction: .south, distance: 8, rotation: rotation)
                                pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "small_wall_corner", position: cornerPos, rotation: rotation.combined(with: .clockwise180)))
                            }
                        }
                    }
                }
            }
        }

        for j in 0..<layout.sizeJ {
            for i in 0..<layout.sizeI {
                var roofPos = offset(pos, direction: .south, distance: Int32(8 + (j - self.entranceJ) * 8), rotation: rotation)
                roofPos = offset(roofPos, direction: .east, distance: Int32((i - self.entranceI) * 8), rotation: rotation)
                let hasUpperFloor = nextFloorLayout.map { MansionParameters.isInsideMansion($0, i, j) } ?? false
                if MansionParameters.isInsideMansion(layout, i, j) && !hasUpperFloor {
                    if !MansionParameters.isInsideMansion(layout, i + 1, j) {
                        let eastPos = offset(roofPos, direction: .east, distance: 6, rotation: rotation)
                        if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_corner", position: offset(eastPos, direction: .south, distance: 6, rotation: rotation), rotation: rotation))
                        } else if MansionParameters.isInsideMansion(layout, i + 1, j + 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_inner_corner", position: offset(eastPos, direction: .south, distance: 5, rotation: rotation), rotation: rotation))
                        }
                        if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_corner", position: eastPos, rotation: rotation.combined(with: .counterclockwise90)))
                        } else if MansionParameters.isInsideMansion(layout, i + 1, j - 1) {
                            let inner = offset(offset(roofPos, direction: .east, distance: 9, rotation: rotation), direction: .north, distance: 2, rotation: rotation)
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_inner_corner", position: inner, rotation: rotation.combined(with: .clockwise90)))
                        }
                    }

                    if !MansionParameters.isInsideMansion(layout, i - 1, j) {
                        let westPos = roofPos
                        if !MansionParameters.isInsideMansion(layout, i, j + 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_corner", position: offset(westPos, direction: .south, distance: 6, rotation: rotation), rotation: rotation.combined(with: .clockwise90)))
                        } else if MansionParameters.isInsideMansion(layout, i - 1, j + 1) {
                            let inner = offset(offset(westPos, direction: .south, distance: 8, rotation: rotation), direction: .west, distance: 3, rotation: rotation)
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_inner_corner", position: inner, rotation: rotation.combined(with: .counterclockwise90)))
                        }
                        if !MansionParameters.isInsideMansion(layout, i, j - 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_corner", position: westPos, rotation: rotation.combined(with: .clockwise180)))
                        } else if MansionParameters.isInsideMansion(layout, i - 1, j - 1) {
                            pieces.append(try WoodlandMansionPiece(context: self.context, templateName: "roof_inner_corner", position: offset(westPos, direction: .south, distance: 1, rotation: rotation), rotation: rotation.combined(with: .clockwise180)))
                        }
                    }
                }
            }
        }
    }

    private mutating func addEntrance(_ pieces: inout [StructurePiece], wallPiece: inout MansionPlacement) {
        let position = offset(wallPiece.position, direction: .west, distance: 9, rotation: wallPiece.rotation)
        if let piece = try? WoodlandMansionPiece(context: self.context, templateName: "entrance", position: position, rotation: wallPiece.rotation) {
            pieces.append(piece)
        }
        wallPiece.position = offset(wallPiece.position, direction: .south, distance: 16, rotation: wallPiece.rotation)
    }

    private mutating func addWallPiece(_ pieces: inout [StructurePiece], wallPiece: inout MansionPlacement) throws {
        let position = offset(wallPiece.position, direction: .east, distance: 7, rotation: wallPiece.rotation)
        pieces.append(try WoodlandMansionPiece(context: self.context, templateName: wallPiece.templateName, position: position, rotation: wallPiece.rotation))
        wallPiece.position = offset(wallPiece.position, direction: .south, distance: 8, rotation: wallPiece.rotation)
    }

    private mutating func turnLeft(_ pieces: inout [StructurePiece], wallPiece: inout MansionPlacement) {
        wallPiece.position = offset(wallPiece.position, direction: .south, distance: -1, rotation: wallPiece.rotation)
        if let piece = try? WoodlandMansionPiece(context: self.context, templateName: "wall_corner", position: wallPiece.position, rotation: wallPiece.rotation) {
            pieces.append(piece)
        }
        wallPiece.position = offset(wallPiece.position, direction: .south, distance: -7, rotation: wallPiece.rotation)
        wallPiece.position = offset(wallPiece.position, direction: .west, distance: -6, rotation: wallPiece.rotation)
        wallPiece.rotation = wallPiece.rotation.combined(with: .clockwise90)
    }

    private mutating func turnRight(wallPiece: inout MansionPlacement) {
        wallPiece.position = offset(wallPiece.position, direction: .south, distance: 6, rotation: wallPiece.rotation)
        wallPiece.position = offset(wallPiece.position, direction: .east, distance: 8, rotation: wallPiece.rotation)
        wallPiece.rotation = wallPiece.rotation.combined(with: .counterclockwise90)
    }

    private mutating func makeSmallRoom(
        pos: PosInt3D,
        rotation: MansionRotation,
        direction: MansionDirection?,
        pool: RoomPool
    ) throws -> WoodlandMansionPiece {
        var roomRotation = MansionRotation.none
        var templateName = pool.smallRoom(using: &self.random)

        switch direction {
        case .north:
            roomRotation = roomRotation.combined(with: .counterclockwise90)
        case .west:
            roomRotation = roomRotation.combined(with: .clockwise180)
        case .south:
            roomRotation = roomRotation.combined(with: .clockwise90)
        case .east:
            break
        default:
            templateName = pool.smallSecretRoom(using: &self.random)
        }

        var offsetPos = WoodlandMansionPiece.applyTransformedOffset(
            // Small-room placement starts at the transformed template origin; the
            // doorway direction only chooses the rotation.
            PosInt3D(x: 0, y: 0, z: 0),
            size: PosInt3D(x: 7, y: 8, z: 7),
            mirror: .none,
            rotation: roomRotation
        )
        let finalRotation = roomRotation.combined(with: rotation)
        offsetPos = WoodlandMansionPiece.transformTemplatePositionAroundOrigin(
            offsetPos,
            mirror: .none,
            rotation: rotation
        )
        let finalPos = PosInt3D(x: pos.x + offsetPos.x, y: pos.y, z: pos.z + offsetPos.z)
        return try WoodlandMansionPiece(context: self.context, templateName: templateName, position: finalPos, rotation: finalRotation)
    }

    private mutating func makeMediumRoom(
        pos: PosInt3D,
        rotation: MansionRotation,
        connectedRoomDirection: MansionDirection,
        entranceDirection: MansionDirection,
        pool: RoomPool,
        staircase: Bool
    ) throws -> WoodlandMansionPiece {
        let piece: WoodlandMansionPiece
        if entranceDirection == .east && connectedRoomDirection == .south {
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: offset(pos, direction: .east, distance: 1, rotation: rotation), rotation: rotation)
        } else if entranceDirection == .east && connectedRoomDirection == .north {
            let placed = offset(offset(pos, direction: .east, distance: 1, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation, mirror: .leftRight)
        } else if entranceDirection == .west && connectedRoomDirection == .north {
            let placed = offset(offset(pos, direction: .east, distance: 7, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise180))
        } else if entranceDirection == .west && connectedRoomDirection == .south {
            let placed = offset(pos, direction: .east, distance: 7, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation, mirror: .frontBack)
        } else if entranceDirection == .south && connectedRoomDirection == .east {
            let placed = offset(pos, direction: .east, distance: 1, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise90), mirror: .leftRight)
        } else if entranceDirection == .south && connectedRoomDirection == .west {
            let placed = offset(pos, direction: .east, distance: 7, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise90))
        } else if entranceDirection == .north && connectedRoomDirection == .west {
            let placed = offset(offset(pos, direction: .east, distance: 7, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise90), mirror: .frontBack)
        } else if entranceDirection == .north && connectedRoomDirection == .east {
            let placed = offset(offset(pos, direction: .east, distance: 1, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumFunctionalRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .counterclockwise90))
        } else if entranceDirection == .south && connectedRoomDirection == .north {
            let placed = offset(offset(pos, direction: .east, distance: 1, rotation: rotation), direction: .north, distance: 8, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumGenericRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation)
        } else if entranceDirection == .north && connectedRoomDirection == .south {
            let placed = offset(offset(pos, direction: .east, distance: 7, rotation: rotation), direction: .south, distance: 14, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumGenericRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise180))
        } else if entranceDirection == .west && connectedRoomDirection == .east {
            let placed = offset(pos, direction: .east, distance: 15, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumGenericRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .clockwise90))
        } else if entranceDirection == .east && connectedRoomDirection == .west {
            let placed = offset(offset(pos, direction: .west, distance: 7, rotation: rotation), direction: .south, distance: 6, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumGenericRoom(using: &self.random, staircase: staircase), position: placed, rotation: rotation.combined(with: .counterclockwise90))
        } else if entranceDirection == .up && connectedRoomDirection == .east {
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumSecretRoom(using: &self.random), position: offset(pos, direction: .east, distance: 15, rotation: rotation), rotation: rotation.combined(with: .clockwise90))
        } else if entranceDirection == .up && connectedRoomDirection == .south {
            let placed = offset(offset(pos, direction: .east, distance: 1, rotation: rotation), direction: .north, distance: 0, rotation: rotation)
            piece = try WoodlandMansionPiece(context: self.context, templateName: pool.mediumSecretRoom(using: &self.random), position: placed, rotation: rotation)
        } else {
            fatalError("Unhandled mansion medium room configuration")
        }

        return piece
    }

    private mutating func makeBigRoom(
        pos: PosInt3D,
        rotation: MansionRotation,
        connectedRoomDirection: MansionDirection,
        entranceDirection: MansionDirection,
        pool: RoomPool
    ) throws -> WoodlandMansionPiece {
        var offsetX = 0
        var offsetZ = 0
        var roomRotation = rotation
        var mirror = MansionMirror.none

        switch (entranceDirection, connectedRoomDirection) {
        case (.east, .south):
            offsetX = -7
        case (.east, .north):
            offsetX = -7
            offsetZ = 6
            mirror = .leftRight
        case (.north, .east):
            offsetX = 1
            offsetZ = 14
            roomRotation = rotation.combined(with: .counterclockwise90)
        case (.north, .west):
            offsetX = 7
            offsetZ = 14
            roomRotation = rotation.combined(with: .counterclockwise90)
            mirror = .leftRight
        case (.south, .west):
            offsetX = 7
            offsetZ = -8
            roomRotation = rotation.combined(with: .clockwise90)
        case (.south, .east):
            offsetX = 1
            offsetZ = -8
            roomRotation = rotation.combined(with: .clockwise90)
            mirror = .leftRight
        case (.west, .north):
            offsetX = 15
            offsetZ = 6
            roomRotation = rotation.combined(with: .clockwise180)
        case (.west, .south):
            offsetX = 15
            mirror = .frontBack
        default:
            break
        }

        let placed = offset(offset(pos, direction: .east, distance: Int32(offsetX), rotation: rotation), direction: .south, distance: Int32(offsetZ), rotation: rotation)
        return try WoodlandMansionPiece(context: self.context, templateName: pool.bigRoom(using: &self.random), position: placed, rotation: roomRotation, mirror: mirror)
    }

    private mutating func makeBigSecretRoom(
        pos: PosInt3D,
        rotation: MansionRotation,
        pool: RoomPool
    ) throws -> WoodlandMansionPiece {
        try WoodlandMansionPiece(
            context: self.context,
            templateName: pool.bigSecretRoom(using: &self.random),
            position: offset(pos, direction: .east, distance: 1, rotation: rotation),
            rotation: rotation
        )
    }
}

private protocol RoomPool {
    func smallRoom<R: Random>(using random: inout R) -> String
    func smallSecretRoom<R: Random>(using random: inout R) -> String
    func mediumFunctionalRoom<R: Random>(using random: inout R, staircase: Bool) -> String
    func mediumGenericRoom<R: Random>(using random: inout R, staircase: Bool) -> String
    func mediumSecretRoom<R: Random>(using random: inout R) -> String
    func bigRoom<R: Random>(using random: inout R) -> String
    func bigSecretRoom<R: Random>(using random: inout R) -> String
}

private struct FirstFloorRoomPool: RoomPool {
    func smallRoom<R: Random>(using random: inout R) -> String { "1x1_a\(Int(random.next(bound: 5)) + 1)" }
    func smallSecretRoom<R: Random>(using random: inout R) -> String { "1x1_as\(Int(random.next(bound: 4)) + 1)" }
    func mediumFunctionalRoom<R: Random>(using random: inout R, staircase: Bool) -> String { "1x2_a\(Int(random.next(bound: 9)) + 1)" }
    func mediumGenericRoom<R: Random>(using random: inout R, staircase: Bool) -> String { "1x2_b\(Int(random.next(bound: 5)) + 1)" }
    func mediumSecretRoom<R: Random>(using random: inout R) -> String { "1x2_s\(Int(random.next(bound: 2)) + 1)" }
    func bigRoom<R: Random>(using random: inout R) -> String { "2x2_a\(Int(random.next(bound: 4)) + 1)" }
    func bigSecretRoom<R: Random>(using random: inout R) -> String { "2x2_s1" }
}

private struct SecondFloorRoomPool: RoomPool {
    func smallRoom<R: Random>(using random: inout R) -> String { "1x1_b\(Int(random.next(bound: 5)) + 1)" }
    func smallSecretRoom<R: Random>(using random: inout R) -> String { "1x1_as\(Int(random.next(bound: 4)) + 1)" }
    func mediumFunctionalRoom<R: Random>(using random: inout R, staircase: Bool) -> String { staircase ? "1x2_c_stairs" : "1x2_c\(Int(random.next(bound: 4)) + 1)" }
    func mediumGenericRoom<R: Random>(using random: inout R, staircase: Bool) -> String { staircase ? "1x2_d_stairs" : "1x2_d\(Int(random.next(bound: 5)) + 1)" }
    func mediumSecretRoom<R: Random>(using random: inout R) -> String { "1x2_se\(Int(random.next(bound: 1)) + 1)" }
    func bigRoom<R: Random>(using random: inout R) -> String { "2x2_b\(Int(random.next(bound: 5)) + 1)" }
    func bigSecretRoom<R: Random>(using random: inout R) -> String { "2x2_s1" }
}
private typealias ThirdFloorRoomPool = SecondFloorRoomPool

private func mansionShuffle<T, R: Random>(_ values: inout [T], random: inout R) {
    guard values.count > 1 else { return }
    for index in stride(from: values.count - 1, through: 1, by: -1) {
        let swapIndex = Int(random.next(bound: UInt32(index + 1)))
        if swapIndex != index {
            values.swapAt(index, swapIndex)
        }
    }
}

private func offset(_ pos: PosInt3D, direction: MansionDirection, distance: Int32, rotation: MansionRotation) -> PosInt3D {
    if direction == .up {
        return PosInt3D(x: pos.x, y: pos.y + distance, z: pos.z)
    }
    let worldDirection = rotation.rotate(direction.horizontal!)
    return PosInt3D(
        x: pos.x + worldDirection.stepX * distance,
        y: pos.y,
        z: pos.z + worldDirection.stepZ * distance
    )
}

private extension PosInt3D {
    func offsetY(_ delta: Int32) -> PosInt3D {
        PosInt3D(x: self.x, y: self.y + delta, z: self.z)
    }
}

private extension HorizontalDirection {
    var stepX: Int32 {
        switch self {
        case .west: return -1
        case .east: return 1
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
