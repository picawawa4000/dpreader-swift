import Foundation

/// The complete block and loot output of a shipwreck start.
public struct ShipwreckGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

/// A placed vanilla shipwreck template.
public final class ShipwreckPiece: StructurePiece {
    public let templateName: String
    public let placementOrigin: PosInt3D
    public let rotationQuarterTurns: Int
    public let isBeached: Bool

    private let template: StructureTemplate
    fileprivate var generatedLoot: [StructureLootContainer] = []

    fileprivate init(
        templateName: String,
        template: StructureTemplate,
        origin: PosInt3D,
        rotation: ShipwreckRotation,
        isBeached: Bool
    ) {
        self.templateName = templateName
        self.template = template
        self.placementOrigin = origin
        self.rotationQuarterTurns = rotation.rawValue
        self.isBeached = isBeached
        super.init(
            orientation: rotation.publicDirection,
            boundingBox: rotation.bounds(size: template.size, origin: origin)
        )
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let rotation = ShipwreckRotation(rawValue: self.rotationQuarterTurns)!
        let palette = self.template.palette(at: self.placementOrigin)

        // Shipwrecks use IGNORE_AIR_AND_STRUCTURE_BLOCKS.  Structure metadata is
        // processed immediately afterward, just as SimpleStructurePiece does.
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count else { continue }
            let templateState = palette[block.state]
            guard !templateState.isAir, templateState.id != "minecraft:structure_block" else { continue }
            let position = rotation.position(for: block.pos).shipwreckAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            let state = rotation.state(templateState, waterlogged: world.block(at: position).id == "minecraft:water")
            world.setBlock(state, at: position)
        }

        // StructureTemplate gives every existing lootable block entity a seed before
        // SimpleStructurePiece visits data markers. Shipwreck chest NBT is subsequently
        // overwritten by the marker's shipwreck loot table, but those RNG calls remain.
        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count,
                  block.nbt != nil,
                  palette[block.state].id == "minecraft:chest"
            else { continue }
            let position = rotation.position(for: block.pos).shipwreckAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            _ = random.nextLong()
        }

        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count,
                  palette[block.state].id == "minecraft:structure_block",
                  let lootTable = Self.lootTable(for: Self.metadata(block.nbt))
            else { continue }
            let marker = rotation.position(for: block.pos).shipwreckAdding(self.placementOrigin)
            guard chunkBox.contains(marker) else { continue }
            let chestPosition = PosInt3D(x: marker.x, y: marker.y - 1, z: marker.z)
            let chest = world.block(at: chestPosition)
            self.generatedLoot.append(StructureLootContainer(
                block: chest.id,
                pos: chestPosition,
                lootTable: lootTable,
                lootSeed: Int64(bitPattern: random.nextLong())
            ))
        }
    }

    private static func metadata(_ tag: NBTTag?) -> String? {
        guard case .compound(let values)? = tag, case .string(let value)? = values["metadata"] else { return nil }
        return value
    }

    private static func lootTable(for metadata: String?) -> String? {
        switch metadata {
        case "map_chest": return "minecraft:chests/shipwreck_map"
        case "treasure_chest": return "minecraft:chests/shipwreck_treasure"
        case "supply_chest": return "minecraft:chests/shipwreck_supply"
        default: return nil
        }
    }

    private static func templateOrder(_ left: StructureTemplateBlock, _ right: StructureTemplateBlock) -> Bool {
        if left.pos.y != right.pos.y { return left.pos.y < right.pos.y }
        if left.pos.x != right.pos.x { return left.pos.x < right.pos.x }
        return left.pos.z < right.pos.z
    }
}

public enum Shipwreck {
    private static let beachedTemplates = [
        "with_mast", "sideways_full", "sideways_fronthalf", "sideways_backhalf",
        "rightsideup_full", "rightsideup_fronthalf", "rightsideup_backhalf",
        "with_mast_degraded", "rightsideup_full_degraded", "rightsideup_fronthalf_degraded",
        "rightsideup_backhalf_degraded"
    ]
    private static let regularTemplates = [
        "with_mast", "upsidedown_full", "upsidedown_fronthalf", "upsidedown_backhalf",
        "sideways_full", "sideways_fronthalf", "sideways_backhalf", "rightsideup_full",
        "rightsideup_fronthalf", "rightsideup_backhalf", "with_mast_degraded",
        "upsidedown_full_degraded", "upsidedown_fronthalf_degraded", "upsidedown_backhalf_degraded",
        "sideways_full_degraded", "sideways_fronthalf_degraded", "sideways_backhalf_degraded",
        "rightsideup_full_degraded", "rightsideup_fronthalf_degraded", "rightsideup_backhalf_degraded"
    ]

    public static func generatePieceGraph(
        settings: ShipwreckStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> PieceGraph {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let rotation = ShipwreckRotation(rawValue: Int(random.next(bound: 4)))!
        let names = settings.isBeached ? Self.beachedTemplates : Self.regularTemplates
        let templateName = "minecraft:shipwreck/\(names[Int(random.next(bound: UInt32(names.count)))])"
        guard let template = context.structureTemplate(named: templateName) else {
            throw StructureGenerationError.missingStructureTemplate(templateName)
        }
        let origin = PosInt3D(
            x: startChunk.x &* 16,
            y: self.templateY(template: template, startChunk: startChunk, isBeached: settings.isBeached, context: context),
            z: startChunk.z &* 16
        )
        let piece = ShipwreckPiece(
            templateName: templateName, template: template, origin: origin,
            rotation: rotation, isBeached: settings.isBeached
        )
        return PieceGraph(startChunk: startChunk, orientation: rotation.publicDirection, boundingBox: piece.boundingBox, pieces: [piece])
    }

    public static func generate(
        settings: ShipwreckStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> ShipwreckGenerationResult {
        let graph = try self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context)
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let structureID = settings.isBeached ? "minecraft:shipwreck_beached" : "minecraft:shipwreck"
        let decoration = context.structureDecorationParameters(forStructureID: structureID)
            ?? StructureDecorationParameters(step: StructureGenerationStep.surfaceStructures.rawIndex, index: settings.isBeached ? 18 : 17)
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: decoration.index, decoratorStep: decoration.step
                )
                for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: world, chunkBox: chunkBox, random: &random)
                }
            }
        }
        let loot = graph.pieces.compactMap { $0 as? ShipwreckPiece }.flatMap(\.generatedLoot).sorted {
            if $0.pos.y != $1.pos.y { return $0.pos.y > $1.pos.y }
            if $0.pos.z != $1.pos.z { return $0.pos.z < $1.pos.z }
            return $0.pos.x < $1.pos.x
        }
        return ShipwreckGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    public static func generateLoot(
        settings: ShipwreckStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> [StructureLootContainer] {
        try self.generate(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context).lootContainers
    }

    private static func templateY(
        template: StructureTemplate,
        startChunk: PosInt2D,
        isBeached: Bool,
        context: StructureGenerationContext
    ) -> Int32 {
        let startX = startChunk.x &* 16
        let startZ = startChunk.z &* 16
        var total: Int64 = 0
        var lowest = context.maximumWorldY &+ 1
        for x in startX...(startX &+ template.size.x &- 1) {
            for z in startZ...(startZ &+ template.size.z &- 1) {
                let y = self.topY(atX: x, z: z, worldSurface: isBeached, context: context)
                total += Int64(y)
                lowest = min(lowest, y)
            }
        }
        let area = max(1, Int64(template.size.x) * Int64(template.size.z))
        if isBeached {
            // The final 0...2 offset is selected by the chunk-decoration RNG while the
            // piece is written.  Use the central value here so its graph remains stable.
            return lowest &- template.size.y / 2 &- 1
        }
        return Int32(total / area)
    }

    private static func topY(
        atX x: Int32,
        z: Int32,
        worldSurface: Bool,
        context: StructureGenerationContext
    ) -> Int32 {
        for y in stride(from: context.maximumWorldY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            guard !state.isAir else { continue }
            if !worldSurface && (state.id == "minecraft:water" || state.id == "minecraft:lava") { continue }
            return y &+ 1
        }
        return context.minimumWorldY
    }
}

private enum ShipwreckRotation: Int {
    case none = 0, clockwise90, clockwise180, counterclockwise90

    private static let pivot = PosInt3D(x: 4, y: 0, z: 15)

    var publicDirection: CardinalDirection {
        switch self {
        case .none: return .south
        case .clockwise90: return .west
        case .clockwise180: return .north
        case .counterclockwise90: return .east
        }
    }

    func position(for value: PosInt3D) -> PosInt3D {
        let x = value.x - Self.pivot.x
        let z = value.z - Self.pivot.z
        switch self {
        case .none: return value
        case .clockwise90: return PosInt3D(x: Self.pivot.x - z, y: value.y, z: Self.pivot.z + x)
        case .clockwise180: return PosInt3D(x: Self.pivot.x - x, y: value.y, z: Self.pivot.z - z)
        case .counterclockwise90: return PosInt3D(x: Self.pivot.x + z, y: value.y, z: Self.pivot.z - x)
        }
    }

    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox {
        let corners = [
            PosInt3D(x: 0, y: 0, z: 0),
            PosInt3D(x: size.x - 1, y: 0, z: 0),
            PosInt3D(x: 0, y: 0, z: size.z - 1),
            PosInt3D(x: size.x - 1, y: 0, z: size.z - 1)
        ].map { self.position(for: $0) }
        return BoundingBox(
            minX: origin.x + (corners.map(\.x).min() ?? 0), minY: origin.y,
            minZ: origin.z + (corners.map(\.z).min() ?? 0),
            maxX: origin.x + (corners.map(\.x).max() ?? 0), maxY: origin.y + size.y - 1,
            maxZ: origin.z + (corners.map(\.z).max() ?? 0)
        )
    }

    func state(_ state: BlockState, waterlogged: Bool) -> BlockState {
        guard var properties = state.properties else { return state }
        if let facing = properties["facing"] { properties["facing"] = self.direction(facing) }
        if let axis = properties["axis"], self == .clockwise90 || self == .counterclockwise90 {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        if let value = properties["rotation"], let rotation = Int(value) {
            properties["rotation"] = String((rotation + self.rawValue * 4) & 15)
        }
        if properties["waterlogged"] != nil { properties["waterlogged"] = waterlogged ? "true" : "false" }
        let horizontalConnections = ["north", "east", "south", "west"].reduce(into: [String: String]()) { result, direction in
            if let value = properties[direction] { result[direction] = value }
        }
        for direction in horizontalConnections.keys {
            properties[direction] = nil
        }
        for (direction, value) in horizontalConnections {
            let destination = self.direction(direction)
            properties[destination] = value
        }
        return BlockState(id: state.id, properties: properties)
    }

    private func direction(_ direction: String) -> String {
        switch (self, direction) {
        case (_, "up"), (_, "down"): return direction
        case (.none, _): return direction
        case (.clockwise90, "north"): return "east"
        case (.clockwise90, "east"): return "south"
        case (.clockwise90, "south"): return "west"
        case (.clockwise90, "west"): return "north"
        case (.clockwise180, "north"): return "south"
        case (.clockwise180, "east"): return "west"
        case (.clockwise180, "south"): return "north"
        case (.clockwise180, "west"): return "east"
        case (.counterclockwise90, "north"): return "west"
        case (.counterclockwise90, "east"): return "north"
        case (.counterclockwise90, "south"): return "east"
        case (.counterclockwise90, "west"): return "south"
        default: return direction
        }
    }
}

private extension PosInt3D {
    func shipwreckAdding(_ other: PosInt3D) -> PosInt3D {
        PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z)
    }
}
