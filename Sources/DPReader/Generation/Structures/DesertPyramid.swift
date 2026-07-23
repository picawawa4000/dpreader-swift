import Foundation

public typealias DesertPyramidPieceGraph = PieceGraph<DesertPyramidPieceKind>

public enum DesertPyramidPieceKind: String {
    case desertPyramid
}

public struct DesertPyramidLootMarker {
    public let pos: PosInt3D
    public let lootTable: String
    public let lootSeed: Int64
}

public struct DesertPyramidGenerationResult {
    public let graph: DesertPyramidPieceGraph
    public let blocks: StructureBlockVolume
    public let chestLootMarkers: [DesertPyramidLootMarker]
    public let archaeologyLootMarkers: [DesertPyramidLootMarker]
    public let potentialSuspiciousSandPositions: [PosInt3D]
    public let basementMarkerPos: PosInt3D?
}

public enum DesertPyramid {
    public static func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> DesertPyramidPieceGraph? {
        guard minimumCornerHeight(startChunk: startChunk, context: context) >= context.seaLevel else {
            return nil
        }
        var constructorRandom = getRandomWithCarverSeed(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z
        )
        let piece = DesertPyramidPiece(worldSeed: worldSeed, startChunk: startChunk, random: &constructorRandom)
        var random = getStructureGenerationRandom(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z,
            decoratorIndex: DesertPyramidPiece.decoratorIndex,
            decoratorStep: DesertPyramidPiece.decoratorStep
        )
        guard piece.adjustToMinHeight(context: context, random: &random) else {
            return nil
        }
        return DesertPyramidPieceGraph(
            startChunk: startChunk,
            orientation: piece.orientation,
            boundingBox: piece.boundingBox,
            pieces: [piece]
        )
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> DesertPyramidGenerationResult? {
        guard minimumCornerHeight(startChunk: startChunk, context: context) >= context.seaLevel else {
            return nil
        }
        var constructorRandom = getRandomWithCarverSeed(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z
        )
        let piece = DesertPyramidPiece(worldSeed: worldSeed, startChunk: startChunk, random: &constructorRandom)
        var random = getStructureGenerationRandom(
            worldSeed: worldSeed,
            chunkX: startChunk.x,
            chunkZ: startChunk.z,
            decoratorIndex: DesertPyramidPiece.decoratorIndex,
            decoratorStep: DesertPyramidPiece.decoratorStep
        )
        guard piece.adjustToMinHeight(context: context, random: &random) else {
            return nil
        }

        let graph = DesertPyramidPieceGraph(
            startChunk: startChunk,
            orientation: piece.orientation,
            boundingBox: piece.boundingBox,
            pieces: [piece]
        )
        let writeBounds = expandedWriteBounds(for: piece, minimumWorldY: context.minimumWorldY)
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY,
            volume: volume
        )
        piece.write(in: world, chunkBox: writeBounds, random: &random)
        return DesertPyramidGenerationResult(
            graph: graph,
            blocks: volume,
            chestLootMarkers: piece.chestLootMarkers,
            archaeologyLootMarkers: piece.archaeologyLootMarkers,
            potentialSuspiciousSandPositions: piece.potentialSuspiciousSandPositions,
            basementMarkerPos: piece.basementMarkerPos
        )
    }

    private static func expandedWriteBounds(for piece: DesertPyramidPiece, minimumWorldY: Int32) -> BoundingBox {
        BoundingBox(
            minX: piece.boundingBox.minX,
            minY: minimumWorldY + 1,
            minZ: piece.boundingBox.minZ,
            maxX: piece.boundingBox.maxX,
            maxY: piece.boundingBox.maxY,
            maxZ: piece.boundingBox.maxZ
        )
    }

    private static func minimumCornerHeight(startChunk: PosInt2D, context: StructureGenerationContext) -> Int32 {
        let startX = startChunk.x * 16
        let startZ = startChunk.z * 16
        let width = DesertPyramidPiece.width
        let depth = DesertPyramidPiece.depth
        return min(
            surfaceY(atX: startX, z: startZ, context: context),
            surfaceY(atX: startX, z: startZ + depth, context: context),
            surfaceY(atX: startX + width, z: startZ, context: context),
            surfaceY(atX: startX + width, z: startZ + depth, context: context)
        )
    }

    private static func surfaceY(atX x: Int32, z: Int32, context: StructureGenerationContext) -> Int32 {
        let maxSearchY = max(Int32(319), context.seaLevel + 64)
        for y in stride(from: maxSearchY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if !state.type.isAir {
                return y
            }
        }
        return context.minimumWorldY - 1
    }
}

private final class DesertPyramidPiece: StructurePiece<DesertPyramidPieceKind> {
    static let width: Int32 = 21
    static let height: Int32 = 15
    static let depth: Int32 = 21
    static let initialY: Int32 = 64
    static let decoratorStep: Int32 = 4
    static let decoratorIndex: Int32 = 1
    static let chestLootTable = "minecraft:chests/desert_pyramid"
    static let archaeologyLootTable = "minecraft:archaeology/desert_pyramid"

    static let air = Blocks.airState
    static let sandstone = BlockState(type: Block(withID: "minecraft:sandstone"))
    static let cutSandstone = BlockState(type: Block(withID: "minecraft:cut_sandstone"))
    static let chiseledSandstone = BlockState(type: Block(withID: "minecraft:chiseled_sandstone"))
    static let sandstoneSlab = BlockState(type: Block(withID: "minecraft:sandstone_slab"))
    static let orangeTerracotta = BlockState(type: Block(withID: "minecraft:orange_terracotta"))
    static let blueTerracotta = BlockState(type: Block(withID: "minecraft:blue_terracotta"))
    static let tnt = BlockState(type: Block(withID: "minecraft:tnt"))
    static let sand = BlockState(type: Block(withID: "minecraft:sand"))
    static let suspiciousSand = BlockState(type: Block(withID: "minecraft:suspicious_sand"))
    static let chest = BlockState(type: Block(withID: "minecraft:chest"))
    static let stonePressurePlate = BlockState(type: Block(withID: "minecraft:stone_pressure_plate"))

    private let worldSeed: WorldSeed
    private(set) var chestLootMarkers: [DesertPyramidLootMarker] = []
    private(set) var archaeologyLootMarkers: [DesertPyramidLootMarker] = []
    private(set) var potentialSuspiciousSandPositions: [PosInt3D] = []
    private(set) var basementMarkerPos: PosInt3D?

    init<R: Random>(worldSeed: WorldSeed, startChunk: PosInt2D, random: inout R) {
        self.worldSeed = worldSeed
        let orientation = Self.randomOrientation(using: &random)
        let boundingBox = makeBoundingBox(
            x: startChunk.x * 16,
            y: Self.initialY,
            z: startChunk.z * 16,
            orientation: orientation,
            width: Self.width,
            height: Self.height,
            depth: Self.depth
        )
        super.init(kind: .desertPyramid, orientation: orientation.publicValue, boundingBox: boundingBox)
    }

    func adjustToMinHeight<R: Random>(context: StructureGenerationContext, random: inout R) -> Bool {
        guard let minimumSurfaceY = self.minimumSurfaceY(context: context), minimumSurfaceY >= context.seaLevel else {
            return false
        }
        let downwardOffset = Int32(random.next(bound: 3))
        self.boundingBox.move(0, minimumSurfaceY - Self.initialY - downwardOffset, 0)
        return true
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        var worldRandom = Self.makeWorldgenRegionRandom(
            worldSeed: self.worldSeed,
            chunkX: Self.floorDiv(chunkBox.minX, by: 16),
            chunkZ: Self.floorDiv(chunkBox.minZ, by: 16)
        )
        self.generateTemple(in: world, chunkBox: chunkBox, random: &random, worldRandom: &worldRandom)
        self.applyArchaeologyPostProcessing(in: world, chunkBox: chunkBox)
    }

    private func generateTemple<R: Random, W: Random>(
        in world: StructureWorldView,
        chunkBox: BoundingBox,
        random: inout R,
        worldRandom: inout W
    ) {
        self.generateBox(world, chunkBox, 0, -4, 0, Self.width - 1, 0, Self.depth - 1, Self.sandstone, Self.sandstone)

        for level in 1...9 {
            let i = Int32(level)
            self.generateBox(world, chunkBox, i, i, i, Self.width - 1 - i, i, Self.depth - 1 - i, Self.sandstone, Self.sandstone)
            self.generateBox(world, chunkBox, i + 1, i, i + 1, Self.width - 2 - i, i, Self.depth - 2 - i, Self.air, Self.air)
        }

        for x in 0..<Self.width {
            for z in 0..<Self.depth {
                self.fillColumnDown(world, Self.sandstone, x, -5, z, chunkBox)
            }
        }

        let northStairs = self.sandstoneStairs(localFacing: .north)
        let southStairs = self.sandstoneStairs(localFacing: .south)
        let eastStairs = self.sandstoneStairs(localFacing: .east)
        let westStairs = self.sandstoneStairs(localFacing: .west)

        self.generateBox(world, chunkBox, 0, 0, 0, 4, 9, 4, Self.sandstone, Self.air)
        self.generateBox(world, chunkBox, 1, 10, 1, 3, 10, 3, Self.sandstone, Self.sandstone)
        self.placeBlock(world, northStairs, 2, 10, 0, chunkBox)
        self.placeBlock(world, southStairs, 2, 10, 4, chunkBox)
        self.placeBlock(world, eastStairs, 0, 10, 2, chunkBox)
        self.placeBlock(world, westStairs, 4, 10, 2, chunkBox)
        self.generateBox(world, chunkBox, Self.width - 5, 0, 0, Self.width - 1, 9, 4, Self.sandstone, Self.air)
        self.generateBox(world, chunkBox, Self.width - 4, 10, 1, Self.width - 2, 10, 3, Self.sandstone, Self.sandstone)
        self.placeBlock(world, northStairs, Self.width - 3, 10, 0, chunkBox)
        self.placeBlock(world, southStairs, Self.width - 3, 10, 4, chunkBox)
        self.placeBlock(world, eastStairs, Self.width - 5, 10, 2, chunkBox)
        self.placeBlock(world, westStairs, Self.width - 1, 10, 2, chunkBox)
        self.generateBox(world, chunkBox, 8, 0, 0, 12, 4, 4, Self.sandstone, Self.air)
        self.generateBox(world, chunkBox, 9, 1, 0, 11, 3, 4, Self.air, Self.air)
        self.placeBlock(world, Self.cutSandstone, 9, 1, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 9, 2, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 9, 3, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 10, 3, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 11, 3, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 11, 2, 1, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 11, 1, 1, chunkBox)
        self.generateBox(world, chunkBox, 4, 1, 1, 8, 3, 3, Self.sandstone, Self.air)
        self.generateBox(world, chunkBox, 4, 1, 2, 8, 2, 2, Self.air, Self.air)
        self.generateBox(world, chunkBox, 12, 1, 1, 16, 3, 3, Self.sandstone, Self.air)
        self.generateBox(world, chunkBox, 12, 1, 2, 16, 2, 2, Self.air, Self.air)
        self.generateBox(world, chunkBox, 5, 4, 5, Self.width - 6, 4, Self.depth - 6, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, 9, 4, 9, 11, 4, 11, Self.air, Self.air)
        self.generateBox(world, chunkBox, 8, 1, 8, 8, 3, 8, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 12, 1, 8, 12, 3, 8, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 8, 1, 12, 8, 3, 12, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 12, 1, 12, 12, 3, 12, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 1, 1, 5, 4, 4, 11, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, Self.width - 5, 1, 5, Self.width - 2, 4, 11, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, 6, 7, 9, 6, 7, 11, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, Self.width - 7, 7, 9, Self.width - 7, 7, 11, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, 5, 5, 9, 5, 7, 11, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, Self.width - 6, 5, 9, Self.width - 6, 7, 11, Self.cutSandstone, Self.cutSandstone)
        self.placeBlock(world, Self.air, 5, 5, 10, chunkBox)
        self.placeBlock(world, Self.air, 5, 6, 10, chunkBox)
        self.placeBlock(world, Self.air, 6, 6, 10, chunkBox)
        self.placeBlock(world, Self.air, Self.width - 6, 5, 10, chunkBox)
        self.placeBlock(world, Self.air, Self.width - 6, 6, 10, chunkBox)
        self.placeBlock(world, Self.air, Self.width - 7, 6, 10, chunkBox)
        self.generateBox(world, chunkBox, 2, 4, 4, 2, 6, 4, Self.air, Self.air)
        self.generateBox(world, chunkBox, Self.width - 3, 4, 4, Self.width - 3, 6, 4, Self.air, Self.air)
        self.placeBlock(world, northStairs, 2, 4, 5, chunkBox)
        self.placeBlock(world, northStairs, 2, 3, 4, chunkBox)
        self.placeBlock(world, northStairs, Self.width - 3, 4, 5, chunkBox)
        self.placeBlock(world, northStairs, Self.width - 3, 3, 4, chunkBox)
        self.generateBox(world, chunkBox, 1, 1, 3, 2, 2, 3, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, Self.width - 3, 1, 3, Self.width - 2, 2, 3, Self.sandstone, Self.sandstone)
        self.placeBlock(world, Self.sandstone, 1, 1, 2, chunkBox)
        self.placeBlock(world, Self.sandstone, Self.width - 2, 1, 2, chunkBox)
        self.placeBlock(world, Self.sandstoneSlab, 1, 2, 2, chunkBox)
        self.placeBlock(world, Self.sandstoneSlab, Self.width - 2, 2, 2, chunkBox)
        self.placeBlock(world, westStairs, 2, 1, 2, chunkBox)
        self.placeBlock(world, eastStairs, Self.width - 3, 1, 2, chunkBox)
        self.generateBox(world, chunkBox, 4, 3, 5, 4, 3, 17, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, Self.width - 5, 3, 5, Self.width - 5, 3, 17, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, 3, 1, 5, 4, 2, 16, Self.air, Self.air)
        self.generateBox(world, chunkBox, Self.width - 6, 1, 5, Self.width - 5, 2, 16, Self.air, Self.air)

        for z in stride(from: Int32(5), through: Int32(17), by: 2) {
            self.placeBlock(world, Self.cutSandstone, 4, 1, z, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, 4, 2, z, chunkBox)
            self.placeBlock(world, Self.cutSandstone, Self.width - 5, 1, z, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, Self.width - 5, 2, z, chunkBox)
        }

        self.placeBlock(world, Self.orangeTerracotta, 10, 0, 7, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 10, 0, 8, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 9, 0, 9, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 11, 0, 9, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 8, 0, 10, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 12, 0, 10, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 7, 0, 10, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 13, 0, 10, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 9, 0, 11, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 11, 0, 11, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 10, 0, 12, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 10, 0, 13, chunkBox)
        self.placeBlock(world, Self.blueTerracotta, 10, 0, 10, chunkBox)

        var x: Int32 = 0
        while x <= Self.width - 1 {
            self.placeBlock(world, Self.cutSandstone, x, 2, 1, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 2, 2, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 2, 3, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 3, 1, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 3, 2, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 3, 3, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 4, 1, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, x, 4, 2, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 4, 3, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 5, 1, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 5, 2, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 5, 3, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 6, 1, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, x, 6, 2, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 6, 3, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 7, 1, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 7, 2, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 7, 3, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 8, 1, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 8, 2, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 8, 3, chunkBox)
            x += Self.width - 1
        }

        x = 2
        while x <= Self.width - 3 {
            self.placeBlock(world, Self.cutSandstone, x - 1, 2, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 2, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x + 1, 2, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x - 1, 3, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 3, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x + 1, 3, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x - 1, 4, 0, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, x, 4, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x + 1, 4, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x - 1, 5, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 5, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x + 1, 5, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x - 1, 6, 0, chunkBox)
            self.placeBlock(world, Self.chiseledSandstone, x, 6, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x + 1, 6, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x - 1, 7, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x, 7, 0, chunkBox)
            self.placeBlock(world, Self.orangeTerracotta, x + 1, 7, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x - 1, 8, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x, 8, 0, chunkBox)
            self.placeBlock(world, Self.cutSandstone, x + 1, 8, 0, chunkBox)
            x += Self.width - 5
        }

        self.generateBox(world, chunkBox, 8, 4, 0, 12, 6, 0, Self.cutSandstone, Self.cutSandstone)
        self.placeBlock(world, Self.air, 8, 6, 0, chunkBox)
        self.placeBlock(world, Self.air, 12, 6, 0, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 9, 5, 0, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, 10, 5, 0, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, 11, 5, 0, chunkBox)
        self.generateBox(world, chunkBox, 8, -14, 8, 12, -11, 12, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 8, -10, 8, 12, -10, 12, Self.chiseledSandstone, Self.chiseledSandstone)
        self.generateBox(world, chunkBox, 8, -9, 8, 12, -9, 12, Self.cutSandstone, Self.cutSandstone)
        self.generateBox(world, chunkBox, 8, -8, 8, 12, -1, 12, Self.sandstone, Self.sandstone)
        self.generateBox(world, chunkBox, 9, -11, 9, 11, -1, 11, Self.air, Self.air)
        self.placeBlock(world, Self.stonePressurePlate, 10, -11, 10, chunkBox)
        self.generateBox(world, chunkBox, 9, -13, 9, 11, -13, 11, Self.tnt, Self.air)
        self.placeBlock(world, Self.air, 8, -11, 10, chunkBox)
        self.placeBlock(world, Self.air, 8, -10, 10, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, 7, -10, 10, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 7, -11, 10, chunkBox)
        self.placeBlock(world, Self.air, 12, -11, 10, chunkBox)
        self.placeBlock(world, Self.air, 12, -10, 10, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, 13, -10, 10, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 13, -11, 10, chunkBox)
        self.placeBlock(world, Self.air, 10, -11, 8, chunkBox)
        self.placeBlock(world, Self.air, 10, -10, 8, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, 10, -10, 7, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 10, -11, 7, chunkBox)
        self.placeBlock(world, Self.air, 10, -11, 12, chunkBox)
        self.placeBlock(world, Self.air, 10, -10, 12, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, 10, -10, 13, chunkBox)
        self.placeBlock(world, Self.cutSandstone, 10, -11, 13, chunkBox)

        self.placeChest(world, chunkBox, 10, -11, 8, random: &random)
        self.placeChest(world, chunkBox, 12, -11, 10, random: &random)
        self.placeChest(world, chunkBox, 10, -11, 12, random: &random)
        self.placeChest(world, chunkBox, 8, -11, 10, random: &random)

        self.generateBasement(in: world, chunkBox: chunkBox, worldRandom: &worldRandom)
    }

    private func generateBasement<W: Random>(in world: StructureWorldView, chunkBox: BoundingBox, worldRandom: inout W) {
        self.generateBasementStairs(originX: 16, originY: -4, originZ: 13, in: world, chunkBox: chunkBox, random: &worldRandom)
        self.generateSuspiciousSandRoom(originX: 16, originY: -4, originZ: 13, in: world, chunkBox: chunkBox, random: &worldRandom)
    }

    private func generateBasementStairs<R: Random>(
        originX: Int32,
        originY: Int32,
        originZ: Int32,
        in world: StructureWorldView,
        chunkBox: BoundingBox,
        random: inout R
    ) {
        let westStairs = self.sandstoneStairs(localFacing: .west)
        self.placeBlock(world, westStairs, 13, -1, 17, chunkBox)
        self.placeBlock(world, westStairs, 14, -2, 17, chunkBox)
        self.placeBlock(world, westStairs, 15, -3, 17, chunkBox)

        let useSandLeft = random.next(bound: 2) == 0
        self.placeBlock(world, Self.sand, originX - 4, originY + 4, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX - 3, originY + 4, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX - 2, originY + 4, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX - 1, originY + 4, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX, originY + 4, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX - 2, originY + 3, originZ + 4, chunkBox)
        self.placeBlock(world, useSandLeft ? Self.sand : Self.sandstone, originX - 1, originY + 3, originZ + 4, chunkBox)
        self.placeBlock(world, useSandLeft ? Self.sandstone : Self.sand, originX, originY + 3, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX - 1, originY + 2, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sandstone, originX, originY + 2, originZ + 4, chunkBox)
        self.placeBlock(world, Self.sand, originX, originY + 1, originZ + 4, chunkBox)
    }

    private func generateSuspiciousSandRoom<R: Random>(
        originX: Int32,
        originY: Int32,
        originZ: Int32,
        in world: StructureWorldView,
        chunkBox: BoundingBox,
        random: inout R
    ) {
        let x = originX
        let y = originY
        let z = originZ

        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 1, z - 3, x - 3, y + 1, z + 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x + 3, y + 1, z - 3, x + 3, y + 1, z + 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 1, z - 3, x + 3, y + 1, z - 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 1, z + 3, x + 3, y + 1, z + 3, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 2, z - 3, x - 3, y + 2, z + 2, Self.chiseledSandstone, Self.chiseledSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x + 3, y + 2, z - 3, x + 3, y + 2, z + 2, Self.chiseledSandstone, Self.chiseledSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 2, z - 3, x + 3, y + 2, z - 2, Self.chiseledSandstone, Self.chiseledSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, y + 2, z + 3, x + 3, y + 2, z + 3, Self.chiseledSandstone, Self.chiseledSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, -1, z - 3, x - 3, -1, z + 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x + 3, -1, z - 3, x + 3, -1, z + 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, -1, z - 3, x + 3, -1, z - 2, Self.cutSandstone, Self.cutSandstone)
        self.generateBoxPreservingAir(world, chunkBox, x - 3, -1, z + 3, x + 3, -1, z + 3, Self.cutSandstone, Self.cutSandstone)
        self.addPotentialSuspiciousSandArea(startX: x - 2, startY: y + 1, startZ: z - 2, endX: x + 2, endY: y + 3, endZ: z + 2)
        self.generateBasementRoof(world, chunkBox, startX: x - 2, y: y + 4, startZ: z - 2, endX: x + 2, endZ: z + 2, random: &random)
        self.placeBlock(world, Self.blueTerracotta, x, y, z, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x + 1, y, z - 1, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x + 1, y, z + 1, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x - 1, y, z - 1, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x - 1, y, z + 1, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x + 2, y, z, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x - 2, y, z, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x, y, z + 2, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x, y, z - 2, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x + 3, y, z, chunkBox)
        self.addPotentialSuspiciousSandPosition(x: x + 3, y: y + 1, z: z)
        self.addPotentialSuspiciousSandPosition(x: x + 3, y: y + 2, z: z)
        self.placeBlock(world, Self.cutSandstone, x + 4, y + 1, z, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, x + 4, y + 2, z, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x - 3, y, z, chunkBox)
        self.addPotentialSuspiciousSandPosition(x: x - 3, y: y + 1, z: z)
        self.addPotentialSuspiciousSandPosition(x: x - 3, y: y + 2, z: z)
        self.placeBlock(world, Self.cutSandstone, x - 4, y + 1, z, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, x - 4, y + 2, z, chunkBox)
        self.placeBlock(world, Self.orangeTerracotta, x, y, z + 3, chunkBox)
        self.addPotentialSuspiciousSandPosition(x: x, y: y + 1, z: z + 3)
        self.addPotentialSuspiciousSandPosition(x: x, y: y + 2, z: z + 3)
        self.placeBlock(world, Self.orangeTerracotta, x, y, z - 3, chunkBox)
        self.addPotentialSuspiciousSandPosition(x: x, y: y + 1, z: z - 3)
        self.addPotentialSuspiciousSandPosition(x: x, y: y + 2, z: z - 3)
        self.placeBlock(world, Self.cutSandstone, x, y + 1, z - 4, chunkBox)
        self.placeBlock(world, Self.chiseledSandstone, x, -2, z - 4, chunkBox)
    }

    private func applyArchaeologyPostProcessing(in world: StructureWorldView, chunkBox: BoundingBox) {
        if let basementMarkerPos = self.basementMarkerPos, chunkBox.contains(basementMarkerPos) {
            world.setBlock(Self.suspiciousSand, at: basementMarkerPos)
            self.archaeologyLootMarkers.append(
                DesertPyramidLootMarker(
                    pos: basementMarkerPos,
                    lootTable: Self.archaeologyLootTable,
                    lootSeed: Self.blockPosAsLong(basementMarkerPos)
                )
            )
        }

        var candidates = self.sortedUniquePositions(self.potentialSuspiciousSandPositions)
        var splitRandom = CheckedRandom(seed: self.worldSeed)
        let splitter = splitRandom.nextSplitter()
        var shuffleRandom = splitter.split(usingPos: self.boundingBoxCenter())
        self.shuffle(&candidates, random: &shuffleRandom)
        let suspiciousCount = min(candidates.count, Int(shuffleRandom.next(bound: 2)) + 6)

        for (index, pos) in candidates.enumerated() where chunkBox.contains(pos) {
            if index < suspiciousCount {
                world.setBlock(Self.suspiciousSand, at: pos)
                self.archaeologyLootMarkers.append(
                    DesertPyramidLootMarker(
                        pos: pos,
                        lootTable: Self.archaeologyLootTable,
                        lootSeed: Self.blockPosAsLong(pos)
                    )
                )
            } else {
                world.setBlock(Self.sand, at: pos)
            }
        }
    }

    private func placeChest<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32,
        random: inout R
    ) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        guard world.block(at: pos).type.id != Self.chest.type.id else { return }
        let lootSeed = Int64(bitPattern: random.nextLong())
        world.setBlock(Self.chest, at: pos)
        self.chestLootMarkers.append(
            DesertPyramidLootMarker(pos: pos, lootTable: Self.chestLootTable, lootSeed: lootSeed)
        )
    }

    private func addPotentialSuspiciousSandPosition(x: Int32, y: Int32, z: Int32) {
        self.potentialSuspiciousSandPositions.append(self.getWorldPos(x, y, z))
    }

    private func addPotentialSuspiciousSandArea(
        startX: Int32,
        startY: Int32,
        startZ: Int32,
        endX: Int32,
        endY: Int32,
        endZ: Int32
    ) {
        for y in startY...endY {
            for x in startX...endX {
                for z in startZ...endZ {
                    self.addPotentialSuspiciousSandPosition(x: x, y: y, z: z)
                }
            }
        }
    }

    private func generateBasementRoof<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        startX: Int32,
        y: Int32,
        startZ: Int32,
        endX: Int32,
        endZ: Int32,
        random: inout R
    ) {
        for x in startX...endX {
            for z in startZ...endZ {
                self.addSandOrSandstone(world, x: x, y: y, z: z, chunkBox: chunkBox, random: &random)
            }
        }

        var worldSeedRandom = CheckedRandom(seed: self.worldSeed)
        let splitter = worldSeedRandom.nextSplitter()
        var markerRandom = splitter.split(usingPos: self.getWorldPos(startX, y, startZ))
        let markerX = startX + Int32(markerRandom.next(bound: UInt32(endX - startX + 1)))
        let markerZ = startZ + Int32(markerRandom.next(bound: UInt32(endZ - startZ + 1)))
        self.basementMarkerPos = self.getWorldPos(markerX, y, markerZ)
    }

    private func addSandOrSandstone<R: Random>(
        _ world: StructureWorldView,
        x: Int32,
        y: Int32,
        z: Int32,
        chunkBox: BoundingBox,
        random: inout R
    ) {
        self.placeBlock(world, random.nextFloat() < 0.33 ? Self.sandstone : Self.sand, x, y, z, chunkBox)
    }

    private func generateBoxPreservingAir(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        _ boundary: BlockState,
        _ interior: BlockState
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    let pos = self.getWorldPos(x, y, z)
                    guard chunkBox.contains(pos) else { continue }
                    if world.block(at: pos).type.isAir {
                        continue
                    }
                    let state = (x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1) ? boundary : interior
                    self.placeBlock(world, state, x, y, z, chunkBox)
                }
            }
        }
    }

    private func boundingBoxCenter() -> PosInt3D {
        PosInt3D(
            x: (self.boundingBox.minX + self.boundingBox.maxX) / 2,
            y: (self.boundingBox.minY + self.boundingBox.maxY) / 2,
            z: (self.boundingBox.minZ + self.boundingBox.maxZ) / 2
        )
    }

    private func sortedUniquePositions(_ positions: [PosInt3D]) -> [PosInt3D] {
        var unique: [PosInt3D] = []
        for pos in positions where !unique.contains(pos) {
            unique.append(pos)
        }
        return unique.sorted { left, right in
            if left.y != right.y { return left.y < right.y }
            if left.z != right.z { return left.z < right.z }
            return left.x < right.x
        }
    }

    private func shuffle<R: Random>(_ values: inout [PosInt3D], random: inout R) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            let swapIndex = Int(random.next(bound: UInt32(index + 1)))
            if swapIndex != index {
                values.swapAt(index, swapIndex)
            }
        }
    }

    private func minimumSurfaceY(context: StructureGenerationContext) -> Int32? {
        var minimumY: Int32?
        for worldX in self.boundingBox.minX...self.boundingBox.maxX {
            for worldZ in self.boundingBox.minZ...self.boundingBox.maxZ {
                guard let surfaceY = self.surfaceY(atX: worldX, z: worldZ, context: context) else {
                    return nil
                }
                if let currentMinimum = minimumY {
                    minimumY = min(currentMinimum, surfaceY)
                } else {
                    minimumY = surfaceY
                }
            }
        }
        return minimumY
    }

    private func surfaceY(atX x: Int32, z: Int32, context: StructureGenerationContext) -> Int32? {
        let maxSearchY = max(Int32(319), context.seaLevel + 64)
        for y in stride(from: maxSearchY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if !state.type.isAir {
                return y + 1
            }
        }
        return nil
    }

    private func sandstoneStairs(localFacing: CardinalDirection) -> BlockState {
        BlockState(
            type: Block(withID: "minecraft:sandstone_stairs"),
            properties: ["facing": self.worldFacing(forLocal: localFacing).rawValue]
        )
    }

    private static func randomOrientation<R: Random>(using random: inout R) -> HorizontalDirection {
        switch Int(random.next(bound: 4)) {
        case 0: return .south
        case 1: return .west
        case 2: return .north
        default: return .east
        }
    }

    private static func blockPosAsLong(_ pos: PosInt3D) -> Int64 {
        let x = Int64(pos.x) & 0x3ffffff
        let y = Int64(pos.y) & 0xfff
        let z = Int64(pos.z) & 0x3ffffff
        return (x << 38) | (z << 12) | y
    }

    private static func makeWorldgenRegionRandom(worldSeed: WorldSeed, chunkX: Int32, chunkZ: Int32) -> XoroshiroRandom {
        var random = XoroshiroRandom(seed: worldSeed)
        let rootSplitter = XoroshiroRandomSplitter(seedLo: random.nextLong(), seedHi: random.nextLong())
        var regionRandom = rootSplitter.split(usingString: "minecraft:worldgen_region_random")
        let chunkSplitter = XoroshiroRandomSplitter(seedLo: regionRandom.nextLong(), seedHi: regionRandom.nextLong())
        return chunkSplitter.split(usingPos: PosInt3D(x: chunkX &* 16, y: 0, z: chunkZ &* 16))
    }

    private static func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
        precondition(divisor > 0)
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder >= 0 ? quotient : quotient - 1
    }

    override func getWorldZ(_ x: Int32, _ z: Int32) -> Int32 {
        switch self.orientation {
        case .north:
            return self.boundingBox.minZ + z
        case .south:
            return self.boundingBox.maxZ - z
        case .west, .east:
            return self.boundingBox.minZ + x
        }
    }

    private func worldFacing(forLocal localFacing: CardinalDirection) -> CardinalDirection {
        switch (self.orientation, localFacing) {
        case (.north, _):
            return localFacing
        case (.south, .north):
            return .south
        case (.south, .south):
            return .north
        case (.south, .east):
            return .west
        case (.south, .west):
            return .east
        case (.east, .north):
            return .west
        case (.east, .south):
            return .east
        case (.east, .east):
            return .south
        case (.east, .west):
            return .north
        case (.west, .north):
            return .east
        case (.west, .south):
            return .west
        case (.west, .east):
            return .north
        case (.west, .west):
            return .south
        }
    }
}
