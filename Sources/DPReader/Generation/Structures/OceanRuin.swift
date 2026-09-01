import Foundation

/// The complete block and loot output of an ocean-ruin start.
public struct OceanRuinGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

/// A placed vanilla ocean-ruin template.
public final class OceanRuinPiece: StructurePiece {
    public let templateName: String
    public private(set) var placementOrigin: PosInt3D
    public let rotationQuarterTurns: Int
    public let integrity: Float
    public let isLarge: Bool

    private let template: StructureTemplate
    private let temperature: OceanRuinTemperature
    private let worldSeed: WorldSeed
    fileprivate var generatedLoot: [StructureLootContainer] = []

    fileprivate init(
        templateName: String,
        template: StructureTemplate,
        origin: PosInt3D,
        rotation: OceanRuinRotation,
        integrity: Float,
        temperature: OceanRuinTemperature,
        isLarge: Bool,
        worldSeed: WorldSeed
    ) {
        self.templateName = templateName
        self.template = template
        self.placementOrigin = origin
        self.rotationQuarterTurns = rotation.rawValue
        self.integrity = integrity
        self.temperature = temperature
        self.isLarge = isLarge
        self.worldSeed = worldSeed
        super.init(orientation: rotation.publicDirection, boundingBox: rotation.bounds(size: template.size, origin: origin))
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let rotation = OceanRuinRotation(rawValue: self.rotationQuarterTurns)!
        let palette = self.template.palette(at: self.placementOrigin)
        var processed = self.template.blocks.compactMap { block -> OceanRuinProcessedBlock? in
            guard block.state >= 0, block.state < palette.count else { return nil }
            let state = palette[block.state]
            let position = rotation.transformed(block.pos).adding(self.placementOrigin)
            var positional = Self.positionalRandom(at: position)
            guard positional.nextFloat() <= self.integrity else { return nil }
            guard !state.isAir, state.id != "minecraft:structure_block" else { return nil }
            return OceanRuinProcessedBlock(block: block, state: state)
        }

        // CappedStructureProcessor shuffles the complete filtered block list, then applies its
        // delegate until five base blocks have actually changed. This is the archaeology pass.
        var seedRandom = CheckedRandom(seed: self.worldSeed)
        var cappedRandom = seedRandom.nextSplitter().split(usingPos: self.placementOrigin)
        var indices = Array(processed.indices)
        if indices.count > 1 {
            for index in stride(from: indices.count - 1, through: 1, by: -1) {
                indices.swapAt(index, Int(cappedRandom.next(bound: UInt32(index + 1))))
            }
        }
        var replacements = 0
        let base = self.temperature == .warm ? "minecraft:sand" : "minecraft:gravel"
        let suspicious = self.temperature == .warm ? "minecraft:suspicious_sand" : "minecraft:suspicious_gravel"
        let archaeologyTable = self.temperature == .warm
            ? "minecraft:archaeology/ocean_ruin_warm"
            : "minecraft:archaeology/ocean_ruin_cold"
        for index in indices where replacements < 5 {
            guard processed[index].state.id == base else { continue }
            let position = rotation.transformed(processed[index].block.pos).adding(self.placementOrigin)
            var positional = Self.positionalRandom(at: position)
            processed[index].state = BlockState(id: suspicious)
            processed[index].lootTable = archaeologyTable
            processed[index].lootSeed = Int64(bitPattern: positional.nextLong())
            replacements += 1
        }

        for entry in processed {
            let position = rotation.transformed(entry.block.pos).adding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            world.setBlock(rotation.transformed(entry.state), at: position)
            if let table = entry.lootTable {
                self.generatedLoot.append(StructureLootContainer(
                    block: entry.state.id, pos: position, lootTable: table, lootSeed: entry.lootSeed ?? 0
                ))
            }
        }

        // Metadata blocks are collected separately by StructureTemplate before the placement
        // processor chain ignores structure blocks. They therefore remain chest markers even
        // though the template itself never writes a structure_block into the world.
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count,
                  palette[block.state].id == "minecraft:structure_block",
                  Self.metadata(block.nbt) == "chest"
            else { continue }
            let position = rotation.transformed(block.pos).adding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            let waterlogged = world.block(at: position).id == "minecraft:water"
            let chest = BlockState(id: "minecraft:chest", properties: ["waterlogged": waterlogged ? "true" : "false"])
            world.setBlock(chest, at: position)
            self.generatedLoot.append(StructureLootContainer(
                block: chest.id,
                pos: position,
                lootTable: self.isLarge ? "minecraft:chests/underwater_ruin_big" : "minecraft:chests/underwater_ruin_small",
                lootSeed: Int64(bitPattern: random.nextLong())
            ))
        }
    }

    fileprivate func adjustedToOceanFloor(context: StructureGenerationContext) {
        let rotation = OceanRuinRotation(rawValue: self.rotationQuarterTurns)!
        guard let startY = Self.oceanFloorY(atX: self.placementOrigin.x, z: self.placementOrigin.z, context: context) else { return }
        let end = rotation.transformed(PosInt3D(
            x: self.template.size.x - 1, y: 0, z: self.template.size.z - 1
        )).adding(PosInt3D(x: self.placementOrigin.x, y: startY, z: self.placementOrigin.z))
        let targetY = self.generationY(startY: startY, end: end, context: context)
        let offset = targetY - self.placementOrigin.y
        guard offset != 0 else { return }
        self.boundingBox.move(0, offset, 0)
        self.placementOrigin = PosInt3D(
            x: self.placementOrigin.x, y: targetY, z: self.placementOrigin.z
        )
    }

    private func generationY(startY: Int32, end: PosInt3D, context: StructureGenerationContext) -> Int32 {
        var minimumGround: Int32 = 512
        let threshold = startY - 1
        var lowColumns = 0
        for x in min(self.placementOrigin.x, end.x)...max(self.placementOrigin.x, end.x) {
            for z in min(self.placementOrigin.z, end.z)...max(self.placementOrigin.z, end.z) {
                var y = startY - 1
                while y > context.minimumWorldY + 1 {
                    let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
                    guard state.isAir || state.id == "minecraft:water" || Self.isIce(state) else { break }
                    y -= 1
                }
                minimumGround = min(minimumGround, y)
                if y < threshold - 2 { lowColumns += 1 }
            }
        }
        let horizontalDistance = abs(self.placementOrigin.x - end.x)
        return threshold - minimumGround > 2 && lowColumns > horizontalDistance - 2 ? minimumGround + 1 : startY
    }

    private static func oceanFloorY(atX x: Int32, z: Int32, context: StructureGenerationContext) -> Int32? {
        for y in stride(from: context.maximumWorldY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if !state.isAir && state.id != "minecraft:water" && state.id != "minecraft:lava" { return y + 1 }
        }
        return nil
    }

    private static func isIce(_ state: BlockState) -> Bool {
        state.id == "minecraft:ice" || state.id == "minecraft:packed_ice" || state.id == "minecraft:blue_ice"
    }

    private static func positionalRandom(at position: PosInt3D) -> CheckedRandom {
        let xProduct = position.x &* 3_129_871
        var seed = Int64(xProduct) ^ (Int64(position.z) &* 116_129_781) ^ Int64(position.y)
        seed = seed &* seed &* 42_317_861 &+ seed &* 11
        return CheckedRandom(seed: UInt64(bitPattern: seed >> 16))
    }

    private static func metadata(_ tag: NBTTag?) -> String? {
        guard case .compound(let values)? = tag, case .string(let value)? = values["metadata"] else { return nil }
        return value
    }
}

public enum OceanRuin {
    private static let warm = (1...8).map { "minecraft:underwater_ruin/warm_\($0)" }
    private static let brick = (1...8).map { "minecraft:underwater_ruin/brick_\($0)" }
    private static let cracked = (1...8).map { "minecraft:underwater_ruin/cracked_\($0)" }
    private static let mossy = (1...8).map { "minecraft:underwater_ruin/mossy_\($0)" }
    private static let bigBrick = [1, 2, 3, 8].map { "minecraft:underwater_ruin/big_brick_\($0)" }
    private static let bigCracked = [1, 2, 3, 8].map { "minecraft:underwater_ruin/big_cracked_\($0)" }
    private static let bigMossy = [1, 2, 3, 8].map { "minecraft:underwater_ruin/big_mossy_\($0)" }
    private static let bigWarm = [4, 5, 6, 7].map { "minecraft:underwater_ruin/big_warm_\($0)" }

    public static func generatePieceGraph(
        settings: OceanRuinStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> PieceGraph {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let origin = PosInt3D(x: startChunk.x &* 16, y: 0, z: startChunk.z &* 16)
        let rotation = OceanRuinRotation(rawValue: Int(random.next(bound: 4)))!
        let large = random.nextFloat() <= Float(settings.largeProbability)
        var pieces: [OceanRuinPiece] = []
        try self.addPieces(
            at: origin, rotation: rotation, large: large, integrity: large ? 0.9 : 0.8,
            settings: settings, worldSeed: worldSeed, random: &random, context: context, pieces: &pieces
        )
        if large && random.nextFloat() <= Float(settings.clusterProbability) {
            try self.addCluster(
                around: origin, rotation: rotation, settings: settings, worldSeed: worldSeed,
                random: &random, context: context, pieces: &pieces
            )
        }
        for piece in pieces { piece.adjustedToOceanFloor(context: context) }
        let bounds = pieces.map(\.boundingBox).reduce(pieces[0].boundingBox) { $0.union($1) }
        return PieceGraph(startChunk: startChunk, orientation: rotation.publicDirection, boundingBox: bounds, pieces: pieces)
    }

    public static func generate(
        settings: OceanRuinStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> OceanRuinGenerationResult {
        let graph = try self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context)
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let key = settings.biomeTemp == .warm ? "minecraft:ocean_ruin_warm" : "minecraft:ocean_ruin_cold"
        let decoration = context.structureDecorationParameters(forStructureID: key)
            ?? StructureDecorationParameters(step: StructureGenerationStep.surfaceStructures.rawIndex, index: settings.biomeTemp == .warm ? 8 : 7)
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
        // Cold ruins place three template variants at the same origin. Later variants can
        // overwrite an earlier suspicious block or chest, so only report containers whose
        // backing block survives the complete structure placement.
        let generatedLoot = graph.pieces.compactMap { $0 as? OceanRuinPiece }.flatMap { $0.generatedLoot }
        var finalLootByPosition: [String: StructureLootContainer] = [:]
        for container in generatedLoot where world.block(at: container.pos).id == container.block {
            // Later overlapping template pieces own the final block entity and its loot seed.
            finalLootByPosition["\(container.pos.x),\(container.pos.y),\(container.pos.z)"] = container
        }
        let loot = finalLootByPosition.values.sorted { left, right in
            if left.pos.y != right.pos.y { return left.pos.y > right.pos.y }
            if left.pos.z != right.pos.z { return left.pos.z < right.pos.z }
            return left.pos.x < right.pos.x
        }
        return OceanRuinGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    public static func generateLoot(
        settings: OceanRuinStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> [StructureLootContainer] {
        try self.generate(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context).lootContainers
    }

    private static func addCluster<R: Random>(
        around origin: PosInt3D, rotation: OceanRuinRotation, settings: OceanRuinStructureSettings,
        worldSeed: WorldSeed, random: inout R, context: StructureGenerationContext, pieces: inout [OceanRuinPiece]
    ) throws {
        let rotated = rotation.transformed(PosInt3D(x: 15, y: 0, z: 15)).adding(origin)
        let protected = BoundingBox.fromCorners(origin, rotated)
        let base = PosInt3D(x: min(origin.x, rotated.x), y: 90, z: min(origin.z, rotated.z))
        var rooms = self.roomPositions(base: base, random: &random)
        let count = Int(random.next(bound: 5)) + 4
        for _ in 0..<count where !rooms.isEmpty {
            let index = Int(random.next(bound: UInt32(rooms.count)))
            let position = rooms.remove(at: index)
            let roomRotation = OceanRuinRotation(rawValue: Int(random.next(bound: 4)))!
            let end = roomRotation.transformed(PosInt3D(x: 5, y: 0, z: 6)).adding(position)
            guard !BoundingBox.fromCorners(position, end).intersects(protected) else { continue }
            try self.addPieces(
                at: position, rotation: roomRotation, large: false, integrity: 0.8,
                settings: settings, worldSeed: worldSeed, random: &random, context: context, pieces: &pieces
            )
        }
    }


    private static func roomPositions<R: Random>(base: PosInt3D, random: inout R) -> [PosInt3D] {
        func next(_ lower: Int32, _ upper: Int32) -> Int32 { lower + Int32(random.next(bound: UInt32(upper - lower))) }
        return [
            PosInt3D(x: base.x - 16 + next(1, 8), y: base.y, z: base.z + 16 + next(1, 7)),
            PosInt3D(x: base.x - 16 + next(1, 8), y: base.y, z: base.z + next(1, 7)),
            PosInt3D(x: base.x - 16 + next(1, 8), y: base.y, z: base.z - 16 + next(4, 8)),
            PosInt3D(x: base.x + next(1, 7), y: base.y, z: base.z + 16 + next(1, 7)),
            PosInt3D(x: base.x + next(1, 7), y: base.y, z: base.z - 16 + next(4, 6)),
            PosInt3D(x: base.x + 16 + next(1, 7), y: base.y, z: base.z + 16 + next(3, 8)),
            PosInt3D(x: base.x + 16 + next(1, 7), y: base.y, z: base.z + next(1, 7)),
            PosInt3D(x: base.x + 16 + next(1, 7), y: base.y, z: base.z - 16 + next(4, 8))
        ]
    }

    private static func addPieces<R: Random>(
        at origin: PosInt3D, rotation: OceanRuinRotation, large: Bool, integrity: Float,
        settings: OceanRuinStructureSettings, worldSeed: WorldSeed, random: inout R,
        context: StructureGenerationContext, pieces: inout [OceanRuinPiece]
    ) throws {
        let names: [(String, Float)]
        switch settings.biomeTemp {
        case .warm:
            let choices = large ? Self.bigWarm : Self.warm
            names = [(choices[Int(random.next(bound: UInt32(choices.count)))], integrity)]
        case .cold:
            let first = large ? Self.bigBrick : Self.brick
            let index = Int(random.next(bound: UInt32(first.count)))
            names = [(first[index], integrity), ((large ? Self.bigCracked : Self.cracked)[index], 0.7), ((large ? Self.bigMossy : Self.mossy)[index], 0.5)]
        }
        for (name, pieceIntegrity) in names {
            guard let template = context.structureTemplate(named: name) else {
                throw StructureGenerationError.missingStructureTemplate(name)
            }
            pieces.append(OceanRuinPiece(
                templateName: name, template: template, origin: origin, rotation: rotation,
                integrity: pieceIntegrity, temperature: settings.biomeTemp, isLarge: large, worldSeed: worldSeed
            ))
        }
    }
}

private struct OceanRuinProcessedBlock {
    let block: StructureTemplateBlock
    var state: BlockState
    var lootTable: String?
    var lootSeed: Int64?
}

private enum OceanRuinRotation: Int {
    case none = 0, clockwise90, clockwise180, counterclockwise90

    var publicDirection: CardinalDirection {
        switch self { case .none: return .south; case .clockwise90: return .west; case .clockwise180: return .north; case .counterclockwise90: return .east }
    }

    func transformed(_ value: PosInt3D) -> PosInt3D {
        switch self {
        case .none: return value
        case .clockwise90: return PosInt3D(x: -value.z, y: value.y, z: value.x)
        case .clockwise180: return PosInt3D(x: -value.x, y: value.y, z: -value.z)
        case .counterclockwise90: return PosInt3D(x: value.z, y: value.y, z: -value.x)
        }
    }

    func transformed(_ state: BlockState) -> BlockState {
        guard var properties = state.properties else { return state }
        if let axis = properties["axis"], self == .clockwise90 || self == .counterclockwise90 {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        if let value = properties["rotation"], let rotation = Int(value) {
            properties["rotation"] = String((rotation + self.rawValue * 4) & 15)
        }
        return BlockState(id: state.id, properties: properties)
    }

    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox {
        .fromCorners(self.transformed(PosInt3D(x: 0, y: 0, z: 0)).adding(origin), self.transformed(PosInt3D(x: size.x - 1, y: size.y - 1, z: size.z - 1)).adding(origin))
    }
}

private extension PosInt3D {
    func adding(_ other: PosInt3D) -> PosInt3D {
        PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z)
    }
}
