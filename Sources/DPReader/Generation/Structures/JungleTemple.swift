import Foundation

public struct JungleTempleGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

public enum JungleTemple {
    // The registry key is `jungle_pyramid`; `jungle_temple` is its serializer type.
    // In the vanilla 1.21.11 surface-structure registry it is index 4 (zero based).
    private static let fallbackDecoration = StructureDecorationParameters(step: 4, index: 4)

    public static func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> PieceGraph? {
        var constructorRandom = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let piece = JungleTemplePiece(worldSeed: worldSeed, startChunk: startChunk, random: &constructorRandom)
        var random = decorationRandom(worldSeed: worldSeed, startChunk: startChunk, context: context)
        guard piece.adjustToAverageHeight(context: context, random: &random) else { return nil }
        return PieceGraph(startChunk: startChunk, orientation: piece.orientation, boundingBox: piece.boundingBox, pieces: [piece])
    }

    public static func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> [StructureLootContainer]? {
        guard let result = generate(worldSeed: worldSeed, startChunk: startChunk, context: context) else { return nil }
        return result.lootContainers
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> JungleTempleGenerationResult? {
        var constructorRandom = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let piece = JungleTemplePiece(worldSeed: worldSeed, startChunk: startChunk, random: &constructorRandom)
        var random = decorationRandom(worldSeed: worldSeed, startChunk: startChunk, context: context)
        guard piece.adjustToAverageHeight(context: context, random: &random) else { return nil }
        let graph = PieceGraph(startChunk: startChunk, orientation: piece.orientation, boundingBox: piece.boundingBox, pieces: [piece])
        let writeBounds = BoundingBox(minX: piece.boundingBox.minX, minY: context.minimumWorldY + 1, minZ: piece.boundingBox.minZ, maxX: piece.boundingBox.maxX, maxY: piece.boundingBox.maxY, maxZ: piece.boundingBox.maxZ)
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let parameters = context.structureDecorationParameters(forStructureID: "minecraft:jungle_pyramid") ?? fallbackDecoration
        for chunkZ in (piece.boundingBox.minZ >> 4)...(piece.boundingBox.maxZ >> 4) {
            for chunkX in (piece.boundingBox.minX >> 4)...(piece.boundingBox.maxX >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY + 1, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: piece.boundingBox.maxY, maxZ: chunkZ &* 16 &+ 15
                )
                var chunkRandom = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: parameters.index, decoratorStep: parameters.step
                )
                piece.write(in: world, chunkBox: chunkBox, random: &chunkRandom)
            }
        }
        return JungleTempleGenerationResult(graph: graph, blocks: volume, lootContainers: piece.lootContainers)
    }

    private static func decorationRandom(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) -> XoroshiroChunkRandom {
        let parameters = context.structureDecorationParameters(forStructureID: "minecraft:jungle_pyramid") ?? fallbackDecoration
        return getStructureGenerationRandom(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z, decoratorIndex: parameters.index, decoratorStep: parameters.step)
    }

}

private final class JungleTemplePiece: StructurePiece {
    static let width: Int32 = 12
    static let height: Int32 = 10
    static let depth: Int32 = 15
    static let initialY: Int32 = 64

    private let worldSeed: WorldSeed
    private(set) var lootContainers: [StructureLootContainer] = []

    init<R: Random>(worldSeed: WorldSeed, startChunk: PosInt2D, random: inout R) {
        self.worldSeed = worldSeed
        // Direction.Type.HORIZONTAL is ordered north, south, west, east in vanilla.
        let orientation: HorizontalDirection
        switch random.next(bound: 4) {
        case 0: orientation = .north
        case 1: orientation = .south
        case 2: orientation = .west
        default: orientation = .east
        }
        // Scattered-feature starts are anchored at the north-west corner of their
        // allocated chunk.  Unlike the generic stronghold-piece helper, this anchor
        // is not rotated before the local-coordinate transform is applied.
        let boundingBox = BoundingBox(
            minX: startChunk.x * 16,
            minY: Self.initialY,
            minZ: startChunk.z * 16,
            maxX: startChunk.x * 16 + Self.width - 1,
            maxY: Self.initialY + Self.height - 1,
            maxZ: startChunk.z * 16 + Self.depth - 1
        )
        super.init(orientation: orientation.publicValue, boundingBox: boundingBox)
    }

    func adjustToAverageHeight<R: Random>(context: StructureGenerationContext, random: inout R) -> Bool {
        // Jungle temples still want their minimum Y to be above sea level.
        guard let minimumSurfaceY = minimumSurfaceY(in: self.boundingBox, context: context), minimumSurfaceY >= context.seaLevel else {
            return false
        }
        guard let averageSurfaceY = averageSurfaceY(in: self.boundingBox, context: context) else {
            return false
        }
        self.boundingBox.move(0, averageSurfaceY - Self.initialY, 0)
        return true
    }

    private func generateTemple<R: Random, W: Random>(
        in world: StructureWorldView,
        chunkBox: BoundingBox,
        random: inout R,
        worldRandom: inout W
    ) {
        // The temple uses the legacy scattered-feature layout.  Keep the randomized stone
        // writes in their vanilla order: those calls advance the decoration RNG before the
        // container loot seeds are assigned.
        self.fillRandomizedBox(world, chunkBox, 0, -4, 0, 11, 0, 14, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 1, 2, 9, 2, 2, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 1, 12, 9, 2, 12, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 1, 3, 2, 2, 11, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 9, 1, 3, 9, 2, 11, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 3, 1, 10, 6, 1, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 3, 13, 10, 6, 13, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 3, 2, 1, 6, 12, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 10, 3, 2, 10, 6, 12, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 3, 2, 9, 3, 12, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 6, 2, 9, 6, 12, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 3, 7, 3, 8, 7, 11, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 8, 4, 7, 8, 10, boundaryOnly: true, random: &random)

        // Carve the central hall and the lower puzzle room.  The detailed redstone states
        // are represented by their block IDs; state properties do not affect loot or terrain
        // generation and are not currently modeled by StructureBlockVolume consumers.
        self.fillBox(world, chunkBox, 3, 1, 3, 8, 2, 11, Blocks.airState)
        self.fillBox(world, chunkBox, 4, 3, 6, 7, 3, 9, Blocks.airState)
        self.fillBox(world, chunkBox, 2, 4, 2, 9, 5, 12, Blocks.airState)
        self.fillBox(world, chunkBox, 4, 6, 5, 7, 6, 9, Blocks.airState)
        self.fillBox(world, chunkBox, 1, -3, 12, 10, -1, 13, Blocks.airState)
        self.fillBox(world, chunkBox, 1, -3, 1, 3, -1, 13, Blocks.airState)
        self.fillBox(world, chunkBox, 1, -3, 1, 9, -1, 5, Blocks.airState)

        for i: Int32 in [0, 14] {
            self.randomPillars(world, chunkBox, x: 2, z: i, random: &random)
            self.randomPillars(world, chunkBox, x: 4, z: i, random: &random)
            self.randomPillars(world, chunkBox, x: 7, z: i, random: &random)
            self.randomPillars(world, chunkBox, x: 9, z: i, random: &random)
        }
        self.fillRandomizedBox(world, chunkBox, 5, 6, 0, 6, 6, 0, boundaryOnly: true, random: &random)
        for i: Int32 in [0, 11] {
            for j in stride(from: Int32(2), through: 12, by: 2) {
                self.fillRandomizedBox(world, chunkBox, i, 4, j, i, 5, j, boundaryOnly: true, random: &random)
            }
            self.fillRandomizedBox(world, chunkBox, i, 6, 5, i, 6, 5, boundaryOnly: true, random: &random)
            self.fillRandomizedBox(world, chunkBox, i, 6, 9, i, 6, 9, boundaryOnly: true, random: &random)
        }
        for (x, z) in [(Int32(2), Int32(2)), (9, 2), (2, 12), (9, 12)] {
            self.fillRandomizedBox(world, chunkBox, x, 7, z, x, 9, z, boundaryOnly: true, random: &random)
        }
        for (x, z) in [(Int32(4), Int32(4)), (7, 4), (4, 10), (7, 10)] {
            self.fillRandomizedBox(world, chunkBox, x, 9, z, x, 9, z, boundaryOnly: true, random: &random)
        }
        self.fillRandomizedBox(world, chunkBox, 5, 9, 7, 6, 9, 7, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 9, 4, 1, 9, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 7, 1, 9, 7, 1, 9, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 10, 7, 2, 10, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 5, 4, 5, 6, 4, 5, boundaryOnly: true, random: &random)
        for k in stride(from: Int32(1), through: 13, by: 2) {
            self.fillRandomizedBox(world, chunkBox, 1, -3, k, 1, -2, k, boundaryOnly: true, random: &random)
        }
        for k in stride(from: Int32(2), through: 12, by: 2) {
            self.fillRandomizedBox(world, chunkBox, 1, -1, k, 3, -1, k, boundaryOnly: true, random: &random)
        }
        self.fillRandomizedBox(world, chunkBox, 2, -2, 1, 5, -2, 1, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 7, -2, 1, 9, -2, 1, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 6, -3, 1, 6, -3, 1, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 6, -1, 1, 6, -1, 1, boundaryOnly: true, random: &random)
        self.placeContainer(world, chunkBox, 3, -2, 1, block: "minecraft:dispenser", table: "minecraft:chests/jungle_temple_dispenser", random: &random)
        self.placeContainer(world, chunkBox, 9, -2, 3, block: "minecraft:dispenser", table: "minecraft:chests/jungle_temple_dispenser", random: &random)
        self.placeContainer(world, chunkBox, 8, -3, 3, block: "minecraft:chest", table: "minecraft:chests/jungle_temple", random: &random)
        self.fillRandomizedBox(world, chunkBox, 9, -1, 1, 9, -1, 5, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 8, -3, 8, 8, -3, 10, boundaryOnly: true, random: &random)
        self.fillRandomizedBox(world, chunkBox, 10, -3, 8, 10, -3, 10, boundaryOnly: true, random: &random)
        self.placeContainer(world, chunkBox, 9, -3, 10, block: "minecraft:chest", table: "minecraft:chests/jungle_temple", random: &random)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        var worldRandom = Self.makeWorldgenRegionRandom(worldSeed: self.worldSeed, chunkX: Self.floorDiv(chunkBox.minX, by: 16), chunkZ: Self.floorDiv(chunkBox.minZ, by: 16))
        self.generateTemple(in: world, chunkBox: chunkBox, random: &random, worldRandom: &worldRandom)
    }

    private func fillBox(_ world: StructureWorldView, _ chunkBox: BoundingBox, _ x0: Int32, _ y0: Int32, _ z0: Int32, _ x1: Int32, _ y1: Int32, _ z1: Int32, _ state: BlockState) {
        for y in y0...y1 { for x in x0...x1 { for z in z0...z1 { self.placeBlock(world, state, x, y, z, chunkBox) } } }
    }

    private func randomPillars<R: Random>(_ world: StructureWorldView, _ chunkBox: BoundingBox, x: Int32, z: Int32, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, x, 4, z, x, 5, z, boundaryOnly: true, random: &random)
    }

    private func placeContainer<R: Random>(_ world: StructureWorldView, _ chunkBox: BoundingBox, _ x: Int32, _ y: Int32, _ z: Int32, block: String, table: String, random: inout R) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        let state = BlockState(type: Block(withID: block))
        self.placeBlock(world, state, x, y, z, chunkBox)
        self.lootContainers.append(StructureLootContainer(block: block, pos: pos, lootTable: table, lootSeed: Int64(bitPattern: random.nextLong())))
    }

    private static func makeWorldgenRegionRandom(worldSeed: WorldSeed, chunkX: Int32, chunkZ: Int32) -> XoroshiroRandom {
        var random = XoroshiroRandom(seed: worldSeed)
        let rootSplitter = XoroshiroRandomSplitter(seedLo: random.nextLong(), seedHi: random.nextLong())
        var regionRandom = rootSplitter.split(usingString: "minecraft:worldgen_region_random")
        let chunkSplitter = XoroshiroRandomSplitter(seedLo: regionRandom.nextLong(), seedHi: regionRandom.nextLong())
        return chunkSplitter.split(usingPos: PosInt3D(x: chunkX &* 16, y: 0, z: chunkZ &* 16))
    }

    private static func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
        let quotient = value / divisor
        return value % divisor >= 0 ? quotient : quotient - 1
    }

    func fillRandomizedBox<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        boundaryOnly _: Bool,
        random: inout R
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    // Vanilla's `fillWithOutline(..., false, randomizer)` invokes the
                    // randomizer for every cell and permits writes into air.
                    let state = JungleTempleCobblestoneRandomizer.state(using: &random, placeBlock: true)
                    self.placeBlock(world, state, x, y, z, chunkBox)
                }
            }
        }
    }
}

fileprivate enum JungleTempleCobblestoneRandomizer {
    static func state<R: Random>(using random: inout R, placeBlock: Bool) -> BlockState {
        if random.nextFloat() < 0.4 {
            return Blocks.cobblestoneState
        }
        return Blocks.mossyCobblestoneState
    }
}
