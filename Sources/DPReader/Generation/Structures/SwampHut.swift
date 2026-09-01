import Foundation

/// The generated block output of a swamp hut. Vanilla spawns its witch and cat while placing
/// the piece; those entities are represented by the structure's spawn overrides instead.
public struct SwampHutGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

public enum SwampHut {
    private static let fallbackDecoration = StructureDecorationParameters(step: 4, index: 19)

    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) -> PieceGraph? {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let piece = SwampHutPiece(startChunk: startChunk, random: &random)
        guard let averageY = averageSurfaceY(in: piece.boundingBox, context: context) else { return nil }
        piece.moveToAverageHeight(averageY)
        return PieceGraph(startChunk: startChunk, orientation: piece.orientation, boundingBox: piece.boundingBox, pieces: [piece])
    }

    public static func generate(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) -> SwampHutGenerationResult? {
        guard let graph = self.generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context),
              let piece = graph.pieces.first as? SwampHutPiece
        else {
            return nil
        }
        let writeBounds = BoundingBox(
            minX: graph.boundingBox.minX, minY: context.minimumWorldY, minZ: graph.boundingBox.minZ,
            maxX: graph.boundingBox.maxX, maxY: graph.boundingBox.maxY, maxZ: graph.boundingBox.maxZ
        )
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.structureDecorationParameters(forStructureID: "minecraft:swamp_hut") ?? Self.fallbackDecoration
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let box = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ, decoratorIndex: decoration.index, decoratorStep: decoration.step)
                piece.write(in: world, chunkBox: box, random: &random)
            }
        }
        return SwampHutGenerationResult(graph: graph, blocks: volume, lootContainers: [])
    }

    public static func generateLoot(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) -> [StructureLootContainer]? {
        self.generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk, context: context) == nil ? nil : []
    }
}

private final class SwampHutPiece: StructurePiece {
    private static let width: Int32 = 7
    private static let height: Int32 = 7
    private static let depth: Int32 = 9
    private static let initialY: Int32 = 64

    init<R: Random>(startChunk: PosInt2D, random: inout R) {
        let orientation: HorizontalDirection
        switch random.next(bound: 4) {
        case 0: orientation = .north
        case 1: orientation = .south
        case 2: orientation = .west
        default: orientation = .east
        }
        super.init(
            orientation: orientation.publicValue,
            boundingBox: makeBoundingBox(
                x: startChunk.x &* 16, y: Self.initialY, z: startChunk.z &* 16,
                orientation: orientation, width: Self.width, height: Self.height, depth: Self.depth
            )
        )
    }

    func moveToAverageHeight(_ averageY: Int32) {
        self.boundingBox.move(0, averageY - Self.initialY, 0)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random _: inout R) {
        let planks = BlockState(id: "minecraft:spruce_planks")
        let logs = BlockState(id: "minecraft:oak_log")
        let fence = BlockState(id: "minecraft:oak_fence")
        let air = Blocks.airState
        func fill(_ x0: Int32, _ y0: Int32, _ z0: Int32, _ x1: Int32, _ y1: Int32, _ z1: Int32, _ state: BlockState) {
            self.generateBox(world, chunkBox, x0, y0, z0, x1, y1, z1, state, state)
        }

        fill(1, 1, 1, 5, 1, 7, planks)
        fill(1, 4, 2, 5, 4, 7, planks)
        fill(2, 1, 0, 4, 1, 0, planks)
        fill(2, 2, 2, 3, 3, 2, planks)
        fill(1, 2, 3, 1, 3, 6, planks)
        fill(5, 2, 3, 5, 3, 6, planks)
        fill(2, 2, 7, 4, 3, 7, planks)
        fill(1, 0, 2, 1, 3, 2, logs)
        fill(5, 0, 2, 5, 3, 2, logs)
        fill(1, 0, 7, 1, 3, 7, logs)
        fill(5, 0, 7, 5, 3, 7, logs)
        self.placeBlock(world, fence, 2, 3, 2, chunkBox)
        self.placeBlock(world, fence, 3, 3, 7, chunkBox)
        self.placeBlock(world, air, 1, 3, 4, chunkBox)
        self.placeBlock(world, air, 5, 3, 4, chunkBox)
        self.placeBlock(world, air, 5, 3, 5, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:potted_red_mushroom"), 1, 3, 5, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:crafting_table"), 3, 2, 6, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:cauldron"), 4, 2, 6, chunkBox)
        self.placeBlock(world, fence, 1, 2, 1, chunkBox)
        self.placeBlock(world, fence, 5, 2, 1, chunkBox)

        let northStairs = BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "north"])
        let eastStairs = BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "east"])
        let westStairs = BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "west"])
        let southStairs = BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "south"])
        fill(0, 4, 1, 6, 4, 1, northStairs)
        fill(0, 4, 2, 0, 4, 7, eastStairs)
        fill(6, 4, 2, 6, 4, 7, westStairs)
        fill(0, 4, 8, 6, 4, 8, southStairs)
        self.placeBlock(world, BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "north", "shape": "outer_right"]), 0, 4, 1, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "north", "shape": "outer_left"]), 6, 4, 1, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "south", "shape": "outer_left"]), 0, 4, 8, chunkBox)
        self.placeBlock(world, BlockState(id: "minecraft:spruce_stairs", properties: ["facing": "south", "shape": "outer_right"]), 6, 4, 8, chunkBox)
        for z: Int32 in [2, 7] {
            for x: Int32 in [1, 5] { self.fillColumnDown(world, logs, x, -1, z, chunkBox) }
        }
    }
}
