import Foundation

/// The complete block and loot output of buried-treasure generation.
public struct BuriedTreasureGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

/// Entry points for deterministic vanilla buried-treasure generation.
public enum BuriedTreasure {
    // Buried treasure is the first underground-structures entry in vanilla's registry.
    private static let fallbackDecoration = StructureDecorationParameters(step: 3, index: 0)
    private static let chest = BlockState(id: "minecraft:chest")
    private static let sand = BlockState(id: "minecraft:sand")
    private static let lootTable = "minecraft:chests/buried_treasure"

    public static func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> PieceGraph? {
        guard let result = generate(worldSeed: worldSeed, startChunk: startChunk, context: context) else {
            return nil
        }
        return result.graph
    }

    public static func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> [StructureLootContainer]? {
        generate(worldSeed: worldSeed, startChunk: startChunk, context: context)?.lootContainers
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> BuriedTreasureGenerationResult? {
        // The buried-treasure start and structure-set locate offset are both nine blocks
        // from the north-west corner of the start chunk.
        let anchor = PosInt3D(x: startChunk.x &* 16 &+ 9, y: 0, z: startChunk.z &* 16 &+ 9)
        guard let oceanFloorY = oceanFloorY(atX: anchor.x, z: anchor.z, context: context) else {
            return nil
        }

        let bounds = BoundingBox(
            minX: anchor.x - 1, minY: context.minimumWorldY, minZ: anchor.z - 1,
            maxX: anchor.x + 1, maxY: context.maximumWorldY, maxZ: anchor.z + 1
        )
        let volume = StructureBlockVolume(bounds: bounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let parameters = context.structureDecorationParameters(forStructureID: "minecraft:buried_treasure")
            ?? fallbackDecoration
        var random = getStructureGenerationRandom(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z,
            decoratorIndex: parameters.index,
            decoratorStep: parameters.step
        )

        guard let chestPosition = placeTreasure(
            atX: anchor.x,
            startY: oceanFloorY,
            z: anchor.z,
            in: world,
            context: context
        ) else {
            return nil
        }
        world.setBlock(chest, at: chestPosition)
        let loot = StructureLootContainer(
            block: chest.id,
            pos: chestPosition,
            lootTable: lootTable,
            lootSeed: Int64(bitPattern: random.nextLong())
        )
        let piece = BuriedTreasurePiece(position: chestPosition)
        let graph = PieceGraph(
            startChunk: startChunk,
            orientation: .north,
            boundingBox: piece.boundingBox,
            pieces: [piece]
        )
        return BuriedTreasureGenerationResult(graph: graph, blocks: volume, lootContainers: [loot])
    }

    /// `OCEAN_FLOOR_WG` returns the first free Y above non-fluid terrain.
    private static func oceanFloorY(atX x: Int32, z: Int32, context: StructureGenerationContext) -> Int32? {
        for y in stride(from: context.maximumWorldY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if !state.isAir && !isLiquid(state) {
                return y + 1
            }
        }
        return nil
    }

    private static func placeTreasure(
        atX x: Int32,
        startY: Int32,
        z: Int32,
        in world: StructureWorldView,
        context: StructureGenerationContext
    ) -> PosInt3D? {
        for y in stride(from: startY, through: context.minimumWorldY + 1, by: -1) {
            let position = PosInt3D(x: x, y: y, z: z)
            let state = world.block(at: position)
            let belowPosition = PosInt3D(x: x, y: y - 1, z: z)
            let below = world.block(at: belowPosition)
            guard isTreasureSupport(below) else { continue }

            // This follows Direction.values(): down, up, north, south, west, east.
            for (dx, dy, dz) in [(Int32(0), Int32(-1), Int32(0)), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)] {
                let neighborPosition = PosInt3D(x: x + dx, y: y + dy, z: z + dz)
                let neighbor = world.block(at: neighborPosition)
                guard neighbor.isAir || isLiquid(neighbor) else { continue }
                let neighborBelow = world.block(at: PosInt3D(x: neighborPosition.x, y: neighborPosition.y - 1, z: neighborPosition.z))
                let replacement: BlockState
                if (neighborBelow.isAir || isLiquid(neighborBelow)) && dy != 1 {
                    replacement = below
                } else {
                    replacement = (!state.isAir && !isLiquid(state)) ? state : sand
                }
                world.setBlock(replacement, at: neighborPosition)
            }
            return position
        }
        return nil
    }

    private static func isTreasureSupport(_ state: BlockState) -> Bool {
        switch state.id {
        case "minecraft:sandstone", "minecraft:stone", "minecraft:andesite", "minecraft:granite", "minecraft:diorite":
            true
        default:
            false
        }
    }

    private static func isLiquid(_ state: BlockState) -> Bool {
        state.id == "minecraft:water" || state.id == "minecraft:lava"
    }
}

private final class BuriedTreasurePiece: StructurePiece {
    init(position: PosInt3D) {
        super.init(
            orientation: .north,
            boundingBox: BoundingBox(
                minX: position.x, minY: position.y, minZ: position.z,
                maxX: position.x, maxY: position.y, maxZ: position.z
            )
        )
    }
}
