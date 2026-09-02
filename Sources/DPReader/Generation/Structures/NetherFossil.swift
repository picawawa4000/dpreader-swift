import Foundation

/// The complete block output of a Nether fossil start.
public struct NetherFossilGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
}

/// A rotated `nether_fossils/fossil_*` structure template.
private final class NetherFossilPiece: StructurePiece {
    let placementOrigin: PosInt3D
    let rotation: NetherFossilRotation
    private let template: StructureTemplate
    private let worldSeed: WorldSeed

    init(template: StructureTemplate, origin: PosInt3D, rotation: NetherFossilRotation, worldSeed: WorldSeed) {
        self.template = template
        self.placementOrigin = origin
        self.rotation = rotation
        self.worldSeed = worldSeed
        super.init(orientation: rotation.direction, boundingBox: rotation.bounds(size: template.size, origin: origin))
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random _: inout R) {
        let palette = self.template.palette(at: self.placementOrigin)
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count else { continue }
            let state = palette[block.state]
            // Nether fossils use IGNORE_AIR_AND_STRUCTURE_BLOCKS.
            guard !state.isAir, state.id != "minecraft:structure_block" else { continue }
            let position = self.rotation.position(for: block.pos).adding(self.placementOrigin)
            guard chunkBox.contains(position) else { continue }
            world.setBlock(self.rotation.state(state), at: position)
        }

        // This uses a positional splitter, so every chunk invocation reaches the
        // same candidate and only the owning chunk can place it.
        var seedRandom = CheckedRandom(seed: self.worldSeed)
        let center = PosInt3D(
            x: (self.boundingBox.minX + self.boundingBox.maxX) / 2,
            y: (self.boundingBox.minY + self.boundingBox.maxY) / 2,
            z: (self.boundingBox.minZ + self.boundingBox.maxZ) / 2
        )
        var ghastRandom = seedRandom.nextSplitter().split(usingPos: center)
        guard ghastRandom.nextFloat() < 0.5 else { return }
        let position = PosInt3D(
            x: self.boundingBox.minX &+ Int32(ghastRandom.next(bound: UInt32(self.boundingBox.maxX - self.boundingBox.minX + 1))),
            y: self.boundingBox.minY,
            z: self.boundingBox.minZ &+ Int32(ghastRandom.next(bound: UInt32(self.boundingBox.maxZ - self.boundingBox.minZ + 1)))
        )
        // `BlockRotation.random` is evaluated even if the position is occupied.
        let ghastRotation = NetherFossilRotation(rawValue: Int(ghastRandom.next(bound: 4)))!
        guard world.block(at: position).isAir, chunkBox.contains(position) else { return }
        world.setBlock(ghastRotation.state(BlockState(id: "minecraft:dried_ghast")), at: position)
    }
}

/// Deterministic Nether-fossil template selection and placement.
public enum NetherFossil {
    private static let templates = (1...14).map { "minecraft:nether_fossils/fossil_\($0)" }

    public static func generatePieceGraph(
        settings: NetherFossilStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> PieceGraph {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        // NetherFossilStructure selects an in-chunk location before sampling its
        // configured height provider.
        let x = startChunk.x &* 16 &+ Int32(random.next(bound: 16))
        let z = startChunk.z &* 16 &+ Int32(random.next(bound: 16))
        var y = settings.height.sample(random: &random, minimumWorldY: context.minimumWorldY, maximumWorldY: context.maximumWorldY)
        // Match NetherFossilStructure's descent through the generated base column:
        // find the first air block immediately above sturdy terrain, but never
        // descend below the generator's sea level.
        while y > context.seaLevel {
            let above = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            y &-= 1
            let below = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if above.isAir && !below.isAir { break }
        }
        let rotation = NetherFossilRotation(rawValue: Int(random.next(bound: 4)))!
        let templateName = Self.templates[Int(random.next(bound: UInt32(Self.templates.count)))]
        guard let template = context.structureTemplate(named: templateName) else {
            throw StructureGenerationError.missingStructureTemplate(templateName)
        }
        let origin = PosInt3D(x: x, y: y, z: z)
        let piece = NetherFossilPiece(template: template, origin: origin, rotation: rotation, worldSeed: worldSeed)
        return PieceGraph(startChunk: startChunk, orientation: rotation.direction, boundingBox: piece.boundingBox, pieces: [piece])
    }

    public static func generate(
        settings: NetherFossilStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> NetherFossilGenerationResult {
        let graph = try self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context)
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
            for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ, decoratorIndex: 0, decoratorStep: 3)
                for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: world, chunkBox: chunkBox, random: &random)
                }
            }
        }
        return NetherFossilGenerationResult(graph: graph, blocks: volume)
    }

    public static func generateLoot(
        settings _: NetherFossilStructureSettings,
        worldSeed _: WorldSeed,
        startChunk _: PosInt2D,
        context _: StructureGenerationContext
    ) -> [StructureLootContainer] { [] }
}

private enum NetherFossilRotation: Int {
    case none = 0, clockwise90, clockwise180, counterclockwise90

    var direction: CardinalDirection {
        switch self {
        case .none: return .south
        case .clockwise90: return .west
        case .clockwise180: return .north
        case .counterclockwise90: return .east
        }
    }

    func position(for value: PosInt3D) -> PosInt3D {
        switch self {
        case .none: return value
        case .clockwise90: return PosInt3D(x: -value.z, y: value.y, z: value.x)
        case .clockwise180: return PosInt3D(x: -value.x, y: value.y, z: -value.z)
        case .counterclockwise90: return PosInt3D(x: value.z, y: value.y, z: -value.x)
        }
    }

    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox {
        BoundingBox.fromCorners(
            self.position(for: PosInt3D(x: 0, y: 0, z: 0)).adding(origin),
            self.position(for: PosInt3D(x: size.x - 1, y: size.y - 1, z: size.z - 1)).adding(origin)
        )
    }

    func state(_ state: BlockState) -> BlockState {
        guard var properties = state.properties else { return state }
        if let axis = properties["axis"], self == .clockwise90 || self == .counterclockwise90 {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        if let value = properties["rotation"], let rotation = Int(value) {
            properties["rotation"] = String((rotation + self.rawValue * 4) & 15)
        }
        return BlockState(id: state.id, properties: properties)
    }
}

private extension PosInt3D {
    func adding(_ other: PosInt3D) -> PosInt3D {
        PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z)
    }
}
