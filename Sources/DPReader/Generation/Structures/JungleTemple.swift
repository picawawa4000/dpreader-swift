import Foundation

public struct JungleTempleGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

public enum JungleTemple {
    private static let fallbackDecoration = StructureDecorationParameters(step: 4, index: 7)

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
        piece.write(in: world, chunkBox: writeBounds, random: &random)
        return JungleTempleGenerationResult(graph: graph, blocks: volume, lootContainers: piece.lootContainers)
    }

    private static func decorationRandom(worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) -> XoroshiroChunkRandom {
        let parameters = context.structureDecorationParameters(forStructureID: "minecraft:jungle_temple") ?? fallbackDecoration
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
        let orientation = randomOrientation(using: &random)
        let boundingBox = makeBoundingBox(
            x: startChunk.x * 16,
            y: Self.initialY,
            z: startChunk.z * 16,
            orientation: orientation,
            width: Self.width,
            height: Self.height,
            depth: Self.depth
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

        self.placeContainer(world, chunkBox, 3, -2, 1, block: "minecraft:dispenser", table: "minecraft:chests/jungle_temple_dispenser", random: &random)
        self.placeContainer(world, chunkBox, 9, -2, 3, block: "minecraft:dispenser", table: "minecraft:chests/jungle_temple_dispenser", random: &random)
        self.placeContainer(world, chunkBox, 8, -3, 3, block: "minecraft:chest", table: "minecraft:chests/jungle_temple", random: &random)
        self.placeContainer(world, chunkBox, 9, -3, 10, block: "minecraft:chest", table: "minecraft:chests/jungle_temple", random: &random)
        /*
        this.fillWithOutline(world, chunkBox, 0, -4, 0, this.width - 1, 0, this.depth - 1, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 1, 2, 9, 2, 2, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 1, 12, 9, 2, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 1, 3, 2, 2, 11, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 9, 1, 3, 9, 2, 11, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 1, 3, 1, 10, 6, 1, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 1, 3, 13, 10, 6, 13, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 1, 3, 2, 1, 6, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 10, 3, 2, 10, 6, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 3, 2, 9, 3, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 6, 2, 9, 6, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 3, 7, 3, 8, 7, 11, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 4, 8, 4, 7, 8, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.fill(world, chunkBox, 3, 1, 3, 8, 2, 11);
         this.fill(world, chunkBox, 4, 3, 6, 7, 3, 9);
         this.fill(world, chunkBox, 2, 4, 2, 9, 5, 12);
         this.fill(world, chunkBox, 4, 6, 5, 7, 6, 9);
         this.fill(world, chunkBox, 5, 7, 6, 6, 7, 8);
         this.fill(world, chunkBox, 5, 1, 2, 6, 2, 2);
         this.fill(world, chunkBox, 5, 2, 12, 6, 2, 12);
         this.fill(world, chunkBox, 5, 5, 1, 6, 5, 1);
         this.fill(world, chunkBox, 5, 5, 13, 6, 5, 13);
         this.addBlock(world, Blocks.AIR.getDefaultState(), 1, 5, 5, chunkBox);
         this.addBlock(world, Blocks.AIR.getDefaultState(), 10, 5, 5, chunkBox);
         this.addBlock(world, Blocks.AIR.getDefaultState(), 1, 5, 9, chunkBox);
         this.addBlock(world, Blocks.AIR.getDefaultState(), 10, 5, 9, chunkBox);

         for (int i = 0; i <= 14; i += 14) {
            this.fillWithOutline(world, chunkBox, 2, 4, i, 2, 5, i, false, random, COBBLESTONE_RANDOMIZER);
            this.fillWithOutline(world, chunkBox, 4, 4, i, 4, 5, i, false, random, COBBLESTONE_RANDOMIZER);
            this.fillWithOutline(world, chunkBox, 7, 4, i, 7, 5, i, false, random, COBBLESTONE_RANDOMIZER);
            this.fillWithOutline(world, chunkBox, 9, 4, i, 9, 5, i, false, random, COBBLESTONE_RANDOMIZER);
         }

         this.fillWithOutline(world, chunkBox, 5, 6, 0, 6, 6, 0, false, random, COBBLESTONE_RANDOMIZER);

         for (int i = 0; i <= 11; i += 11) {
            for (int j = 2; j <= 12; j += 2) {
               this.fillWithOutline(world, chunkBox, i, 4, j, i, 5, j, false, random, COBBLESTONE_RANDOMIZER);
            }

            this.fillWithOutline(world, chunkBox, i, 6, 5, i, 6, 5, false, random, COBBLESTONE_RANDOMIZER);
            this.fillWithOutline(world, chunkBox, i, 6, 9, i, 6, 9, false, random, COBBLESTONE_RANDOMIZER);
         }

         this.fillWithOutline(world, chunkBox, 2, 7, 2, 2, 9, 2, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 9, 7, 2, 9, 9, 2, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 2, 7, 12, 2, 9, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 9, 7, 12, 9, 9, 12, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 4, 9, 4, 4, 9, 4, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 7, 9, 4, 7, 9, 4, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 4, 9, 10, 4, 9, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 7, 9, 10, 7, 9, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 5, 9, 7, 6, 9, 7, false, random, COBBLESTONE_RANDOMIZER);
         BlockState lv = Blocks.COBBLESTONE_STAIRS.getDefaultState().with(StairsBlock.FACING, Direction.EAST);
         BlockState lv2 = Blocks.COBBLESTONE_STAIRS.getDefaultState().with(StairsBlock.FACING, Direction.WEST);
         BlockState lv3 = Blocks.COBBLESTONE_STAIRS.getDefaultState().with(StairsBlock.FACING, Direction.SOUTH);
         BlockState lv4 = Blocks.COBBLESTONE_STAIRS.getDefaultState().with(StairsBlock.FACING, Direction.NORTH);
         this.addBlock(world, lv4, 5, 9, 6, chunkBox);
         this.addBlock(world, lv4, 6, 9, 6, chunkBox);
         this.addBlock(world, lv3, 5, 9, 8, chunkBox);
         this.addBlock(world, lv3, 6, 9, 8, chunkBox);
         this.addBlock(world, lv4, 4, 0, 0, chunkBox);
         this.addBlock(world, lv4, 5, 0, 0, chunkBox);
         this.addBlock(world, lv4, 6, 0, 0, chunkBox);
         this.addBlock(world, lv4, 7, 0, 0, chunkBox);
         this.addBlock(world, lv4, 4, 1, 8, chunkBox);
         this.addBlock(world, lv4, 4, 2, 9, chunkBox);
         this.addBlock(world, lv4, 4, 3, 10, chunkBox);
         this.addBlock(world, lv4, 7, 1, 8, chunkBox);
         this.addBlock(world, lv4, 7, 2, 9, chunkBox);
         this.addBlock(world, lv4, 7, 3, 10, chunkBox);
         this.fillWithOutline(world, chunkBox, 4, 1, 9, 4, 1, 9, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 7, 1, 9, 7, 1, 9, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 4, 1, 10, 7, 2, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 5, 4, 5, 6, 4, 5, false, random, COBBLESTONE_RANDOMIZER);
         this.addBlock(world, lv, 4, 4, 5, chunkBox);
         this.addBlock(world, lv2, 7, 4, 5, chunkBox);

         for (int k = 0; k < 4; k++) {
            this.addBlock(world, lv3, 5, 0 - k, 6 + k, chunkBox);
            this.addBlock(world, lv3, 6, 0 - k, 6 + k, chunkBox);
            this.fill(world, chunkBox, 5, 0 - k, 7 + k, 6, 0 - k, 9 + k);
         }

         this.fill(world, chunkBox, 1, -3, 12, 10, -1, 13);
         this.fill(world, chunkBox, 1, -3, 1, 3, -1, 13);
         this.fill(world, chunkBox, 1, -3, 1, 9, -1, 5);

         for (int k = 1; k <= 13; k += 2) {
            this.fillWithOutline(world, chunkBox, 1, -3, k, 1, -2, k, false, random, COBBLESTONE_RANDOMIZER);
         }

         for (int k = 2; k <= 12; k += 2) {
            this.fillWithOutline(world, chunkBox, 1, -1, k, 3, -1, k, false, random, COBBLESTONE_RANDOMIZER);
         }

         this.fillWithOutline(world, chunkBox, 2, -2, 1, 5, -2, 1, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 7, -2, 1, 9, -2, 1, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 6, -3, 1, 6, -3, 1, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 6, -1, 1, 6, -1, 1, false, random, COBBLESTONE_RANDOMIZER);
         this.addBlock(
            world,
            Blocks.TRIPWIRE_HOOK.getDefaultState().with(TripwireHookBlock.FACING, Direction.EAST).with(TripwireHookBlock.ATTACHED, true),
            1,
            -3,
            8,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE_HOOK.getDefaultState().with(TripwireHookBlock.FACING, Direction.WEST).with(TripwireHookBlock.ATTACHED, true),
            4,
            -3,
            8,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE.getDefaultState().with(TripwireBlock.EAST, true).with(TripwireBlock.WEST, true).with(TripwireBlock.ATTACHED, true),
            2,
            -3,
            8,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE.getDefaultState().with(TripwireBlock.EAST, true).with(TripwireBlock.WEST, true).with(TripwireBlock.ATTACHED, true),
            3,
            -3,
            8,
            chunkBox
         );
         BlockState lv5 = Blocks.REDSTONE_WIRE
            .getDefaultState()
            .with(RedstoneWireBlock.WIRE_CONNECTION_NORTH, WireConnection.SIDE)
            .with(RedstoneWireBlock.WIRE_CONNECTION_SOUTH, WireConnection.SIDE);
         this.addBlock(world, lv5, 5, -3, 7, chunkBox);
         this.addBlock(world, lv5, 5, -3, 6, chunkBox);
         this.addBlock(world, lv5, 5, -3, 5, chunkBox);
         this.addBlock(world, lv5, 5, -3, 4, chunkBox);
         this.addBlock(world, lv5, 5, -3, 3, chunkBox);
         this.addBlock(world, lv5, 5, -3, 2, chunkBox);
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_NORTH, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_WEST, WireConnection.SIDE),
            5,
            -3,
            1,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_EAST, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_WEST, WireConnection.SIDE),
            4,
            -3,
            1,
            chunkBox
         );
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 3, -3, 1, chunkBox);
         if (!this.placedTrap1) {
            this.placedTrap1 = this.addDispenser(world, chunkBox, random, 3, -2, 1, Direction.NORTH, LootTables.JUNGLE_TEMPLE_DISPENSER_CHEST);
         }

         this.addBlock(world, Blocks.VINE.getDefaultState().with(VineBlock.SOUTH, true), 3, -2, 2, chunkBox);
         this.addBlock(
            world,
            Blocks.TRIPWIRE_HOOK.getDefaultState().with(TripwireHookBlock.FACING, Direction.NORTH).with(TripwireHookBlock.ATTACHED, true),
            7,
            -3,
            1,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE_HOOK.getDefaultState().with(TripwireHookBlock.FACING, Direction.SOUTH).with(TripwireHookBlock.ATTACHED, true),
            7,
            -3,
            5,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE.getDefaultState().with(TripwireBlock.NORTH, true).with(TripwireBlock.SOUTH, true).with(TripwireBlock.ATTACHED, true),
            7,
            -3,
            2,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE.getDefaultState().with(TripwireBlock.NORTH, true).with(TripwireBlock.SOUTH, true).with(TripwireBlock.ATTACHED, true),
            7,
            -3,
            3,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.TRIPWIRE.getDefaultState().with(TripwireBlock.NORTH, true).with(TripwireBlock.SOUTH, true).with(TripwireBlock.ATTACHED, true),
            7,
            -3,
            4,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_EAST, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_WEST, WireConnection.SIDE),
            8,
            -3,
            6,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_WEST, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_SOUTH, WireConnection.SIDE),
            9,
            -3,
            6,
            chunkBox
         );
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_NORTH, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_SOUTH, WireConnection.UP),
            9,
            -3,
            5,
            chunkBox
         );
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 9, -3, 4, chunkBox);
         this.addBlock(world, lv5, 9, -2, 4, chunkBox);
         if (!this.placedTrap2) {
            this.placedTrap2 = this.addDispenser(world, chunkBox, random, 9, -2, 3, Direction.WEST, LootTables.JUNGLE_TEMPLE_DISPENSER_CHEST);
         }

         this.addBlock(world, Blocks.VINE.getDefaultState().with(VineBlock.EAST, true), 8, -1, 3, chunkBox);
         this.addBlock(world, Blocks.VINE.getDefaultState().with(VineBlock.EAST, true), 8, -2, 3, chunkBox);
         if (!this.placedMainChest) {
            this.placedMainChest = this.addChest(world, chunkBox, random, 8, -3, 3, LootTables.JUNGLE_TEMPLE_CHEST);
         }

         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 9, -3, 2, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 8, -3, 1, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 4, -3, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 5, -2, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 5, -1, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 6, -3, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 7, -2, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 7, -1, 5, chunkBox);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 8, -3, 5, chunkBox);
         this.fillWithOutline(world, chunkBox, 9, -1, 1, 9, -1, 5, false, random, COBBLESTONE_RANDOMIZER);
         this.fill(world, chunkBox, 8, -3, 8, 10, -1, 10);
         this.addBlock(world, Blocks.CHISELED_STONE_BRICKS.getDefaultState(), 8, -2, 11, chunkBox);
         this.addBlock(world, Blocks.CHISELED_STONE_BRICKS.getDefaultState(), 9, -2, 11, chunkBox);
         this.addBlock(world, Blocks.CHISELED_STONE_BRICKS.getDefaultState(), 10, -2, 11, chunkBox);
         BlockState lv6 = Blocks.LEVER.getDefaultState().with(LeverBlock.FACING, Direction.NORTH).with(LeverBlock.FACE, BlockFace.WALL);
         this.addBlock(world, lv6, 8, -2, 12, chunkBox);
         this.addBlock(world, lv6, 9, -2, 12, chunkBox);
         this.addBlock(world, lv6, 10, -2, 12, chunkBox);
         this.fillWithOutline(world, chunkBox, 8, -3, 8, 8, -3, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.fillWithOutline(world, chunkBox, 10, -3, 8, 10, -3, 10, false, random, COBBLESTONE_RANDOMIZER);
         this.addBlock(world, Blocks.MOSSY_COBBLESTONE.getDefaultState(), 10, -2, 9, chunkBox);
         this.addBlock(world, lv5, 8, -2, 9, chunkBox);
         this.addBlock(world, lv5, 8, -2, 10, chunkBox);
         this.addBlock(
            world,
            Blocks.REDSTONE_WIRE
               .getDefaultState()
               .with(RedstoneWireBlock.WIRE_CONNECTION_NORTH, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_SOUTH, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_EAST, WireConnection.SIDE)
               .with(RedstoneWireBlock.WIRE_CONNECTION_WEST, WireConnection.SIDE),
            10,
            -1,
            9,
            chunkBox
         );
         this.addBlock(world, Blocks.STICKY_PISTON.getDefaultState().with(PistonBlock.FACING, Direction.UP), 9, -2, 8, chunkBox);
         this.addBlock(world, Blocks.STICKY_PISTON.getDefaultState().with(PistonBlock.FACING, Direction.WEST), 10, -2, 8, chunkBox);
         this.addBlock(world, Blocks.STICKY_PISTON.getDefaultState().with(PistonBlock.FACING, Direction.WEST), 10, -1, 8, chunkBox);
         this.addBlock(world, Blocks.REPEATER.getDefaultState().with(RepeaterBlock.FACING, Direction.NORTH), 10, -2, 10, chunkBox);
         if (!this.placedHiddenChest) {
            this.placedHiddenChest = this.addChest(world, chunkBox, random, 9, -3, 10, LootTables.JUNGLE_TEMPLE_CHEST);
         }
         */
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        var worldRandom = Self.makeWorldgenRegionRandom(worldSeed: self.worldSeed, chunkX: Self.floorDiv(chunkBox.minX, by: 16), chunkZ: Self.floorDiv(chunkBox.minZ, by: 16))
        self.generateTemple(in: world, chunkBox: chunkBox, random: &random, worldRandom: &worldRandom)
    }

    private func fillBox(_ world: StructureWorldView, _ chunkBox: BoundingBox, _ x0: Int32, _ y0: Int32, _ z0: Int32, _ x1: Int32, _ y1: Int32, _ z1: Int32, _ state: BlockState) {
        for y in y0...y1 { for x in x0...x1 { for z in z0...z1 { self.placeBlock(world, state, x, y, z, chunkBox) } } }
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
