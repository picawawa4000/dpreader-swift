import Foundation

public struct IglooGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

private enum IglooTemplate: String, CaseIterable {
    case top, middle, bottom

    var name: String { "minecraft:igloo/\(self.rawValue)" }
    var pivot: PosInt3D {
        switch self {
        case .top: return PosInt3D(x: 3, y: 5, z: 5)
        case .middle: return PosInt3D(x: 1, y: 3, z: 1)
        case .bottom: return PosInt3D(x: 3, y: 6, z: 7)
        }
    }
    var offsetFromTop: PosInt3D {
        switch self {
        case .top: return PosInt3D(x: 0, y: 0, z: 0)
        case .middle: return PosInt3D(x: 2, y: -3, z: 4)
        case .bottom: return PosInt3D(x: 0, y: -3, z: -2)
        }
    }
}

public final class IglooPiece: StructurePiece {
    public let templateName: String
    public let placementOrigin: PosInt3D
    public let rotationQuarterTurns: Int

    private let templateKind: IglooTemplate
    private let template: StructureTemplate
    fileprivate var generatedLoot: [StructureLootContainer] = []

    fileprivate init(templateKind: IglooTemplate, template: StructureTemplate, origin: PosInt3D, rotation: IglooRotation) {
        self.templateName = templateKind.name
        self.templateKind = templateKind
        self.template = template
        self.placementOrigin = origin
        self.rotationQuarterTurns = rotation.rawValue
        super.init(orientation: rotation.publicDirection, boundingBox: rotation.bounds(size: template.size, origin: origin, pivot: templateKind.pivot))
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let rotation = IglooRotation(rawValue: self.rotationQuarterTurns)!
        let palette = self.template.palette(at: self.placementOrigin)
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count else { continue }
            let state = palette[block.state]
            guard state.id != "minecraft:structure_block" else { continue }
            let position = rotation.position(for: block.pos, pivot: self.templateKind.pivot).iglooAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            world.setBlock(rotation.state(state), at: position)
        }

        // Template placement assigns seeds to chest NBT before the data marker replaces
        // the table with `igloo_chest`, so retain the otherwise-observable RNG calls.
        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count, block.nbt != nil,
                  palette[block.state].id == "minecraft:chest"
            else { continue }
            let position = rotation.position(for: block.pos, pivot: self.templateKind.pivot).iglooAdding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            _ = random.nextLong()
        }
        for block in self.template.blocks.sorted(by: Self.templateOrder) {
            guard block.state >= 0, block.state < palette.count,
                  palette[block.state].id == "minecraft:structure_block",
                  Self.metadata(block.nbt) == "chest"
            else { continue }
            let marker = rotation.position(for: block.pos, pivot: self.templateKind.pivot).iglooAdding(self.placementOrigin)
            guard chunkBox.contains(marker) else { continue }
            world.setBlock(Blocks.airState, at: marker)
            let chestPosition = PosInt3D(x: marker.x, y: marker.y - 1, z: marker.z)
            let chest = world.block(at: chestPosition)
            self.generatedLoot.append(StructureLootContainer(
                block: chest.id, pos: chestPosition, lootTable: "minecraft:chests/igloo_chest",
                lootSeed: Int64(bitPattern: random.nextLong())
            ))
        }

        if self.templateKind == .top {
            let snowPosition = rotation.position(for: PosInt3D(x: 3, y: 0, z: 5), pivot: self.templateKind.pivot).iglooAdding(self.placementOrigin)
            guard chunkBox.contains(snowPosition) else { return }
            let beneath = world.block(at: PosInt3D(x: snowPosition.x, y: snowPosition.y - 1, z: snowPosition.z))
            if !beneath.isAir && beneath.id != "minecraft:ladder" {
                world.setBlock(BlockState(id: "minecraft:snow_block"), at: snowPosition)
            }
        }
    }

    private static func metadata(_ tag: NBTTag?) -> String? {
        guard case .compound(let values)? = tag, case .string(let value)? = values["metadata"] else { return nil }
        return value
    }

    private static func templateOrder(_ left: StructureTemplateBlock, _ right: StructureTemplateBlock) -> Bool {
        if left.pos.y != right.pos.y { return left.pos.y < right.pos.y }
        if left.pos.x != right.pos.x { return left.pos.x < right.pos.x }
        return left.pos.z < right.pos.z
    }
}

public enum Igloo {
    private static let fallbackDecoration = StructureDecorationParameters(step: 4, index: 3)

    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> PieceGraph {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let rotation = IglooRotation(rawValue: Int(random.next(bound: 4)))!
        let hasBasement = random.nextDouble() < 0.5
        let segmentCount = hasBasement ? Int(random.next(bound: 8)) + 4 : 0
        let start = PosInt3D(x: startChunk.x &* 16, y: 90, z: startChunk.z &* 16)
        let terrainOffset = self.terrainOffset(start: start, rotation: rotation, context: context)
        var pieces: [IglooPiece] = []
        func add(_ kind: IglooTemplate, yOffset: Int32) throws {
            guard let template = context.structureTemplate(named: kind.name) else {
                throw StructureGenerationError.missingStructureTemplate(kind.name)
            }
            let initial = start.iglooAdding(kind.offsetFromTop).iglooAdding(PosInt3D(x: 0, y: -yOffset, z: 0))
            let origin = initial.iglooAdding(PosInt3D(x: 0, y: terrainOffset, z: 0))
            pieces.append(IglooPiece(templateKind: kind, template: template, origin: origin, rotation: rotation))
        }
        if hasBasement {
            try add(.bottom, yOffset: Int32(segmentCount * 3))
            for index in 0..<(segmentCount - 1) { try add(.middle, yOffset: Int32(index * 3)) }
        }
        try add(.top, yOffset: 0)
        let bounds = pieces.map(\.boundingBox).reduce(pieces[0].boundingBox) { $0.union($1) }
        return PieceGraph(startChunk: startChunk, orientation: rotation.publicDirection, boundingBox: bounds, pieces: pieces)
    }

    public static func generate(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> IglooGenerationResult {
        let graph = try self.generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context)
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.structureDecorationParameters(forStructureID: "minecraft:igloo") ?? Self.fallbackDecoration
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ, decoratorIndex: decoration.index, decoratorStep: decoration.step)
                for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: world, chunkBox: chunkBox, random: &random)
                }
            }
        }
        let loot = graph.pieces.compactMap { $0 as? IglooPiece }.flatMap(\.generatedLoot)
        return IglooGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    public static func generateLoot(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) throws -> [StructureLootContainer] {
        try self.generate(worldSeed: worldSeed, startChunk: startChunk, context: context).lootContainers
    }

    private static func terrainOffset(start: PosInt3D, rotation: IglooRotation, context: StructureGenerationContext) -> Int32 {
        // IglooGenerator samples this rotated point while placing every piece.
        let sample = rotation.position(for: PosInt3D(x: 3, y: 0, z: 0), pivot: .init(x: 3, y: 5, z: 5)).iglooAdding(start)
        let top = surfaceY(atX: sample.x, z: sample.z, context: context) ?? context.minimumWorldY
        return top - 91
    }
}

private enum IglooRotation: Int {
    case none = 0, clockwise90, clockwise180, counterclockwise90
    var publicDirection: CardinalDirection { [ .south, .west, .north, .east ][self.rawValue] }

    func position(for value: PosInt3D, pivot: PosInt3D) -> PosInt3D {
        let x = value.x - pivot.x
        let z = value.z - pivot.z
        switch self {
        case .none: return value
        case .clockwise90: return PosInt3D(x: pivot.x - z, y: value.y, z: pivot.z + x)
        case .clockwise180: return PosInt3D(x: pivot.x - x, y: value.y, z: pivot.z - z)
        case .counterclockwise90: return PosInt3D(x: pivot.x + z, y: value.y, z: pivot.z - x)
        }
    }

    func bounds(size: PosInt3D, origin: PosInt3D, pivot: PosInt3D) -> BoundingBox {
        let corners = [
            PosInt3D(x: 0, y: 0, z: 0), PosInt3D(x: size.x - 1, y: 0, z: 0),
            PosInt3D(x: 0, y: 0, z: size.z - 1), PosInt3D(x: size.x - 1, y: 0, z: size.z - 1)
        ].map { self.position(for: $0, pivot: pivot) }
        return BoundingBox(
            minX: origin.x + (corners.map(\.x).min() ?? 0), minY: origin.y,
            minZ: origin.z + (corners.map(\.z).min() ?? 0),
            maxX: origin.x + (corners.map(\.x).max() ?? 0), maxY: origin.y + size.y - 1,
            maxZ: origin.z + (corners.map(\.z).max() ?? 0)
        )
    }

    func state(_ state: BlockState) -> BlockState {
        guard var properties = state.properties else { return state }
        if let axis = properties["axis"], self == .clockwise90 || self == .counterclockwise90 {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        if let value = properties["rotation"], let rotation = Int(value) { properties["rotation"] = String((rotation + self.rawValue * 4) & 15) }
        if let facing = properties["facing"] { properties["facing"] = self.direction(facing) }
        return BlockState(id: state.id, properties: properties)
    }

    private func direction(_ value: String) -> String {
        let directions = ["north", "east", "south", "west"]
        guard let index = directions.firstIndex(of: value) else { return value }
        return directions[(index + self.rawValue) & 3]
    }
}

private extension PosInt3D {
    func iglooAdding(_ other: PosInt3D) -> PosInt3D {
        PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z)
    }
}
