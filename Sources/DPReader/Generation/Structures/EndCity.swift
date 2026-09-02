import Foundation

/// The complete block and loot output of an End City start.
public struct EndCityGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

/// One of the vanilla `end_city/*` template pieces.
public final class EndCityPiece: StructurePiece {
    public let templateName: String
    public let placementOrigin: PosInt3D
    public let rotationQuarterTurns: Int
    private let template: StructureTemplate
    private let includeAir: Bool
    fileprivate var generatedLoot: [StructureLootContainer] = []
    fileprivate var chainLength: Int32 = 0

    fileprivate init(templateName: String, template: StructureTemplate, origin: PosInt3D, rotation: EndCityRotation, includeAir: Bool) {
        self.templateName = templateName
        self.template = template
        self.placementOrigin = origin
        self.rotationQuarterTurns = rotation.rawValue
        self.includeAir = includeAir
        super.init(orientation: rotation.direction, boundingBox: rotation.bounds(size: template.size, origin: origin))
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let rotation = EndCityRotation(rawValue: self.rotationQuarterTurns)!
        let palette = self.template.palette(at: self.placementOrigin)
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count else { continue }
            let state = palette[block.state]
            guard state.id != "minecraft:structure_block", self.includeAir || !state.isAir else { continue }
            let position = rotation.position(for: block.pos).endCityAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            world.setBlock(rotation.state(state), at: position)
        }

        // StructureTemplate assigns a seed to regular block entities before its data
        // markers are handled. Preserve those calls: marker chests overwrite that seed.
        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count, block.nbt != nil,
                  palette[block.state].id == "minecraft:chest" else { continue }
            let position = rotation.position(for: block.pos).endCityAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            _ = random.nextLong()
        }
        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count,
                  palette[block.state].id == "minecraft:structure_block",
                  Self.metadata(block.nbt)?.hasPrefix("Chest") == true else { continue }
            let marker = rotation.position(for: block.pos).endCityAdding(self.placementOrigin)
            guard chunkBox.contains(marker) else { continue }
            let chestPosition = PosInt3D(x: marker.x, y: marker.y - 1, z: marker.z)
            let chest = world.block(at: chestPosition)
            self.generatedLoot.append(StructureLootContainer(
                block: chest.id, pos: chestPosition,
                lootTable: "minecraft:chests/end_city_treasure",
                lootSeed: Int64(bitPattern: random.nextLong())
            ))
        }
    }

    private static func metadata(_ tag: NBTTag?) -> String? {
        guard case .compound(let values)? = tag, case .string(let value)? = values["metadata"] else { return nil }
        return value
    }

    private static func templateOrder(_ lhs: StructureTemplateBlock, _ rhs: StructureTemplateBlock) -> Bool {
        if lhs.pos.y != rhs.pos.y { return lhs.pos.y < rhs.pos.y }
        if lhs.pos.x != rhs.pos.x { return lhs.pos.x < rhs.pos.x }
        return lhs.pos.z < rhs.pos.z
    }
}

/// Direct port of `EndCityGenerator` from the bundled vanilla server source.
public enum EndCity {
    private enum Part { case building, smallTower, bridge, fatTower }
    private static let smallTowerAttachments: [(EndCityRotation, PosInt3D)] = [
        (.none, PosInt3D(x: 1, y: -1, z: 0)), (.clockwise90, PosInt3D(x: 6, y: -1, z: 1)),
        (.counterclockwise90, PosInt3D(x: 0, y: -1, z: 5)), (.clockwise180, PosInt3D(x: 5, y: -1, z: 6))
    ]
    private static let fatTowerAttachments: [(EndCityRotation, PosInt3D)] = [
        (.none, PosInt3D(x: 4, y: -1, z: 0)), (.clockwise90, PosInt3D(x: 12, y: -1, z: 4)),
        (.counterclockwise90, PosInt3D(x: 0, y: -1, z: 8)), (.clockwise180, PosInt3D(x: 8, y: -1, z: 12))
    ]

    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> PieceGraph? {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let rotation = EndCityRotation(rawValue: Int(random.next(bound: 4)))!
        let anchorX = startChunk.x &* 16 &+ 7
        let anchorZ = startChunk.z &* 16 &+ 7
        let y = terrainY(anchorX: anchorX, anchorZ: anchorZ, rotation: rotation, context: context)
        guard y >= 60 else { return nil }
        // EndCityStructure anchors its first template at the terrain-validation
        // corner (chunk origin + 7), rather than the chunk centre used by most starts.
        let origin = PosInt3D(x: anchorX, y: y, z: anchorZ)
        var pieces: [EndCityPiece] = []
        func addRoot(_ name: String, _ origin: PosInt3D, _ rotation: EndCityRotation, _ includeAir: Bool) throws -> EndCityPiece {
            let id = "minecraft:end_city/\(name)"
            guard let template = context.structureTemplate(named: id) else { throw StructureGenerationError.missingStructureTemplate(id) }
            let piece = EndCityPiece(templateName: id, template: template, origin: origin, rotation: rotation, includeAir: includeAir)
            pieces.append(piece); return piece
        }
        func add(_ parent: EndCityPiece, _ offset: PosInt3D, _ name: String, _ rotation: EndCityRotation, _ includeAir: Bool, into target: inout [EndCityPiece]) throws -> EndCityPiece {
            let id = "minecraft:end_city/\(name)"
            guard let template = context.structureTemplate(named: id) else { throw StructureGenerationError.missingStructureTemplate(id) }
            let origin = parent.placementOrigin.endCityAdding(EndCityRotation(rawValue: parent.rotationQuarterTurns)!.position(for: offset))
            let piece = EndCityPiece(templateName: id, template: template, origin: origin, rotation: rotation, includeAir: includeAir)
            target.append(piece); return piece
        }
        var shipGenerated = false
        func intersects(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Bool { lhs.intersects(rhs) }
        func createPart(_ part: Part, _ depth: Int, _ parent: EndCityPiece, into destination: inout [EndCityPiece]) throws -> Bool {
            guard depth <= 8 else { return false }
            var local: [EndCityPiece] = []
            var generated = true
            let rotation = EndCityRotation(rawValue: parent.rotationQuarterTurns)!
            switch part {
            case .building:
                var current = try add(parent, PosInt3D(x: -3, y: 1, z: -11), "base_floor", rotation, true, into: &local)
                switch Int(random.next(bound: 3)) {
                case 0: _ = try add(current, PosInt3D(x: -1, y: 4, z: -1), "base_roof", rotation, true, into: &local)
                case 1:
                    current = try add(current, PosInt3D(x: -1, y: 0, z: -1), "second_floor_2", rotation, false, into: &local)
                    current = try add(current, PosInt3D(x: -1, y: 8, z: -1), "second_roof", rotation, false, into: &local)
                    _ = try createPart(.smallTower, depth + 1, current, into: &local)
                default:
                    current = try add(current, PosInt3D(x: -1, y: 0, z: -1), "second_floor_2", rotation, false, into: &local)
                    current = try add(current, PosInt3D(x: -1, y: 4, z: -1), "third_floor_2", rotation, false, into: &local)
                    current = try add(current, PosInt3D(x: -1, y: 8, z: -1), "third_roof", rotation, true, into: &local)
                    _ = try createPart(.smallTower, depth + 1, current, into: &local)
                }
            case .smallTower:
                var current = try add(parent, PosInt3D(x: 3 + Int32(random.next(bound: 2)), y: -3, z: 3 + Int32(random.next(bound: 2))), "tower_base", rotation, true, into: &local)
                current = try add(current, PosInt3D(x: 0, y: 7, z: 0), "tower_piece", rotation, true, into: &local)
                var bridgeLevel: EndCityPiece? = random.next(bound: 3) == 0 ? current : nil
                let floors = 1 + Int(random.next(bound: 3))
                for index in 0..<floors {
                    current = try add(current, PosInt3D(x: 0, y: 4, z: 0), "tower_piece", rotation, true, into: &local)
                    if index < floors - 1 && random.nextBoolean() { bridgeLevel = current }
                }
                if let bridgeLevel {
                    for (attachmentRotation, position) in smallTowerAttachments where random.nextBoolean() {
                        let bridge = try add(bridgeLevel, position, "bridge_end", rotation.rotated(by: attachmentRotation), true, into: &local)
                        _ = try createPart(.bridge, depth + 1, bridge, into: &local)
                    }
                    _ = try add(current, PosInt3D(x: -1, y: 4, z: -1), "tower_top", rotation, true, into: &local)
                } else if depth != 7 {
                    generated = try createPart(.fatTower, depth + 1, current, into: &local)
                } else { _ = try add(current, PosInt3D(x: -1, y: 4, z: -1), "tower_top", rotation, true, into: &local) }
            case .bridge:
                var current = try add(parent, PosInt3D(x: 0, y: 0, z: -4), "bridge_piece", rotation, true, into: &local)
                current.chainLength = -1
                var rise: Int32 = 0
                for _ in 0..<(1 + Int(random.next(bound: 4))) {
                    if random.nextBoolean() { current = try add(current, PosInt3D(x: 0, y: rise, z: -4), "bridge_piece", rotation, true, into: &local); rise = 0 }
                    else {
                        let steep = random.nextBoolean()
                        current = try add(current, PosInt3D(x: 0, y: rise, z: steep ? -4 : -8), steep ? "bridge_steep_stairs" : "bridge_gentle_stairs", rotation, true, into: &local)
                        rise = 4
                    }
                }
                if !shipGenerated && random.next(bound: UInt32(10 - depth)) == 0 {
                    _ = try add(current, PosInt3D(x: -8 + Int32(random.next(bound: 8)), y: rise, z: -70 + Int32(random.next(bound: 10))), "ship", rotation, true, into: &local); shipGenerated = true
                } else { generated = try createPart(.building, depth + 1, current, into: &local) }
                let end = try add(current, PosInt3D(x: 4, y: rise, z: 0), "bridge_end", rotation.rotated(by: .clockwise180), true, into: &local); end.chainLength = -1
            case .fatTower:
                var current = try add(parent, PosInt3D(x: -3, y: 4, z: -3), "fat_tower_base", rotation, true, into: &local)
                current = try add(current, PosInt3D(x: 0, y: 4, z: 0), "fat_tower_middle", rotation, true, into: &local)
                for _ in 0..<2 where random.next(bound: 3) != 0 {
                    current = try add(current, PosInt3D(x: 0, y: 8, z: 0), "fat_tower_middle", rotation, true, into: &local)
                    for (attachmentRotation, position) in fatTowerAttachments where random.nextBoolean() {
                        let bridge = try add(current, position, "bridge_end", rotation.rotated(by: attachmentRotation), true, into: &local)
                        _ = try createPart(.bridge, depth + 1, bridge, into: &local)
                    }
                }
                _ = try add(current, PosInt3D(x: -2, y: 8, z: -2), "fat_tower_top", rotation, true, into: &local)
            }
            guard generated else { return false }
            let chain = random.nextInt32()
            for piece in local { piece.chainLength = chain
                if let hit = destination.first(where: { intersects($0.boundingBox, piece.boundingBox) }), hit.chainLength != parent.chainLength { return false }
            }
            destination.append(contentsOf: local); return true
        }
        var root = try addRoot("base_floor", origin, rotation, true)
        root = try add(root, PosInt3D(x: -1, y: 0, z: -1), "second_floor_1", rotation, false, into: &pieces)
        root = try add(root, PosInt3D(x: -1, y: 4, z: -1), "third_floor_1", rotation, false, into: &pieces)
        root = try add(root, PosInt3D(x: -1, y: 8, z: -1), "third_roof", rotation, true, into: &pieces)
        _ = try createPart(.smallTower, 1, root, into: &pieces)
        let bounds = pieces.dropFirst().reduce(pieces[0].boundingBox) { $0.union($1.boundingBox) }
        return PieceGraph(startChunk: startChunk, orientation: rotation.direction, boundingBox: bounds, pieces: pieces)
    }

    public static func generate(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> EndCityGenerationResult? {
        guard let graph = try generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context) else { return nil }
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.structureDecorationParameters(forStructureID: "minecraft:end_city") ?? StructureDecorationParameters(step: 4, index: 2)
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) { for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
            let chunkBox = BoundingBox(minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16, maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15)
            var random = getStructureGenerationRandom(worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ, decoratorIndex: decoration.index, decoratorStep: decoration.step)
            for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) { piece.write(in: world, chunkBox: chunkBox, random: &random) }
        }}
        return EndCityGenerationResult(graph: graph, blocks: volume, lootContainers: graph.pieces.compactMap { ($0 as? EndCityPiece)?.generatedLoot }.flatMap { $0 })
    }

    public static func generateLoot(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> [StructureLootContainer]? {
        try generate(worldSeed: worldSeed, startChunk: startChunk, context: context)?.lootContainers
    }

    private static func terrainY(anchorX: Int32, anchorZ: Int32, rotation: EndCityRotation, context: StructureGenerationContext) -> Int32 {
        let offset: (Int32, Int32) = rotation == .none ? (5, 5) : rotation == .clockwise90 ? (-5, 5) : rotation == .clockwise180 ? (-5, -5) : (5, -5)
        return [PosInt2D(x: anchorX, z: anchorZ), PosInt2D(x: anchorX + offset.0, z: anchorZ), PosInt2D(x: anchorX, z: anchorZ + offset.1), PosInt2D(x: anchorX + offset.0, z: anchorZ + offset.1)].map { point in
            for y in stride(from: context.maximumWorldY, through: context.minimumWorldY, by: -1) where !context.blockSampler(PosInt3D(x: point.x, y: y, z: point.z)).isAir { return y + 1 }
            return context.minimumWorldY
        }.min() ?? context.minimumWorldY
    }
}

private enum EndCityRotation: Int, Equatable {
    case none = 0, clockwise90, clockwise180, counterclockwise90
    var direction: CardinalDirection { [.south, .west, .north, .east][self.rawValue] }
    func rotated(by other: EndCityRotation) -> EndCityRotation { EndCityRotation(rawValue: (self.rawValue + other.rawValue) & 3)! }
    func position(for value: PosInt3D) -> PosInt3D { switch self { case .none: return value; case .clockwise90: return PosInt3D(x: -value.z, y: value.y, z: value.x); case .clockwise180: return PosInt3D(x: -value.x, y: value.y, z: -value.z); case .counterclockwise90: return PosInt3D(x: value.z, y: value.y, z: -value.x) } }
    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox { BoundingBox.fromCorners(position(for: PosInt3D(x: 0, y: 0, z: 0)).endCityAdding(origin), position(for: PosInt3D(x: size.x - 1, y: size.y - 1, z: size.z - 1)).endCityAdding(origin)) }
    func state(_ state: BlockState) -> BlockState {
        guard var properties = state.properties else { return state }
        if let facing = properties["facing"] { properties["facing"] = direction(facing) }
        if let axis = properties["axis"], self == .clockwise90 || self == .counterclockwise90 {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        if let value = properties["rotation"], let rotation = Int(value) {
            properties["rotation"] = String((rotation + rawValue * 4) & 15)
        }
        let connections = ["north", "east", "south", "west"].compactMap { key in
            properties[key].map { (key, $0) }
        }
        for (key, _) in connections { properties[key] = nil }
        for (key, value) in connections { properties[direction(key)] = value }
        return BlockState(id: state.id, properties: properties)
    }
    private func direction(_ value: String) -> String { let directions = ["north", "east", "south", "west"]; guard let index = directions.firstIndex(of: value) else { return value }; return directions[(index + rawValue) & 3] }
}

private extension PosInt3D { func endCityAdding(_ other: PosInt3D) -> PosInt3D { PosInt3D(x: x &+ other.x, y: y &+ other.y, z: z &+ other.z) } }
