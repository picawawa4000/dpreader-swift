import Foundation

/// The complete block, loot, and special-marker output of a Nether fortress.
public struct NetherFortressGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
    public let markers: [StructureMarker]
}

/// Deterministic vanilla Nether fortress layout and generation.
public enum NetherFortress {
    // `fortress` is normally resolved from the loaded structure registry. This
    // preserves useful standalone generation for callers with a minimal context.
    private static let fallbackDecoration = StructureDecorationParameters(step: 3, index: 1)

    public static func generatePieceGraph(worldSeed: WorldSeed, startChunk: PosInt2D, context _: StructureGenerationContext) -> PieceGraph {
        let layout = self.layout(worldSeed: worldSeed, startChunk: startChunk)
        return self.graph(for: layout, startChunk: startChunk)
    }

    public static func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> [StructureLootContainer] {
        self.generate(worldSeed: worldSeed, startChunk: startChunk, context: context).lootContainers
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> NetherFortressGenerationResult {
        let layout = self.layout(worldSeed: worldSeed, startChunk: startChunk)
        let graph = self.graph(for: layout, startChunk: startChunk)
        let bounds = BoundingBox(
            minX: graph.boundingBox.minX,
            minY: context.minimumWorldY + 1,
            minZ: graph.boundingBox.minZ,
            maxX: graph.boundingBox.maxX,
            maxY: graph.boundingBox.maxY,
            maxZ: graph.boundingBox.maxZ
        )
        let volume = StructureBlockVolume(bounds: bounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.structureDecorationParameters(forStructureID: "minecraft:fortress") ?? Self.fallbackDecoration
        for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
            for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: bounds.minY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: bounds.maxY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: decoration.index, decoratorStep: decoration.step
                )
                for piece in layout.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: world, chunkBox: chunkBox, random: &random)
                }
            }
        }
        let fortressPieces = layout.pieces.compactMap { $0 as? NetherFortressPiece }
        return NetherFortressGenerationResult(
            graph: graph,
            blocks: volume,
            lootContainers: fortressPieces.flatMap(\.lootContainers),
            markers: world.markers
        )
    }

    private static func layout(worldSeed: WorldSeed, startChunk: PosInt2D) -> NetherFortressLayout {
        var random = getRandomWithCarverSeed(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let orientation: CardinalDirection
        // `Direction.Type.HORIZONTAL` is iterated north, east, south, west.
        switch random.next(bound: 4) {
        case 0: orientation = .north
        case 1: orientation = .east
        case 2: orientation = .south
        default: orientation = .west
        }
        // StartPiece is the one fortress piece whose box is not made through
        // StructurePiece.createBox: it always extends east and south from x/z.
        let startX = startChunk.x &* 16 &+ 2
        let startZ = startChunk.z &* 16 &+ 2
        let startBox = BoundingBox(
            minX: startX, minY: 64, minZ: startZ,
            maxX: startX &+ 18, maxY: 73, maxZ: startZ &+ 18
        )
        let start = NetherFortressPiece(kind: .bridgeCrossing, chainLength: 0, boundingBox: startBox, orientation: orientation)
        let state = NetherFortressLayoutState(start: start)
        start.fillOpenings(state: state, random: &random)
        while !state.pending.isEmpty {
            let index = Int(random.next(bound: UInt32(state.pending.count)))
            let piece = state.pending.remove(at: index)
            piece.fillOpenings(state: state, random: &random)
        }
        let bounds = state.pieces.dropFirst().reduce(start.boundingBox) { $0.union($1.boundingBox) }
        let availableY = 70 - 48 + 1 - (bounds.maxY - bounds.minY + 1)
        let targetMinY = availableY > 1 ? 48 + Int32(random.next(bound: UInt32(availableY))) : 48
        let deltaY = targetMinY - bounds.minY
        for piece in state.pieces {
            piece.boundingBox.move(0, deltaY, 0)
        }
        return NetherFortressLayout(start: start, pieces: state.pieces)
    }

    private static func graph(for layout: NetherFortressLayout, startChunk: PosInt2D) -> PieceGraph {
        let bounds = layout.pieces.dropFirst().reduce(layout.start.boundingBox) { $0.union($1.boundingBox) }
        return PieceGraph(startChunk: startChunk, orientation: layout.start.orientation, boundingBox: bounds, pieces: layout.pieces)
    }
}

private struct NetherFortressLayout {
    let start: NetherFortressPiece
    let pieces: [StructurePiece]
}

private enum NetherFortressPieceKind: CaseIterable {
    case bridge, bridgeCrossing, bridgeSmallCrossing, bridgeStairs, bridgePlatform, corridorExit
    case smallCorridor, corridorCrossing, corridorRightTurn, corridorLeftTurn, corridorStairs, corridorBalcony, corridorNetherWartsRoom
    case bridgeEnd

    var dimensions: (Int32, Int32, Int32) {
        switch self {
        case .bridge: return (5, 10, 19)
        case .bridgeCrossing: return (19, 10, 19)
        case .bridgeSmallCrossing: return (7, 9, 7)
        case .bridgeStairs: return (7, 11, 7)
        case .bridgePlatform: return (7, 8, 9)
        case .corridorExit, .corridorNetherWartsRoom: return (13, 14, 13)
        case .smallCorridor, .corridorCrossing, .corridorRightTurn, .corridorLeftTurn: return (5, 7, 5)
        case .corridorStairs: return (5, 14, 10)
        case .corridorBalcony: return (9, 7, 9)
        case .bridgeEnd: return (5, 10, 8)
        }
    }

    var isCorridor: Bool {
        switch self {
        case .smallCorridor, .corridorCrossing, .corridorRightTurn, .corridorLeftTurn, .corridorStairs, .corridorBalcony, .corridorNetherWartsRoom:
            return true
        default: return false
        }
    }
}

private struct NetherFortressPieceData {
    let kind: NetherFortressPieceKind
    let weight: Int
    let limit: Int
    let repeatable: Bool
    var generatedCount = 0

    func canGenerate() -> Bool { self.limit == 0 || self.generatedCount < self.limit }
}

private final class NetherFortressLayoutState {
    let start: NetherFortressPiece
    var pieces: [StructurePiece]
    var pending: [NetherFortressPiece] = []
    var lastPiece: NetherFortressPieceKind?
    var bridgePieces: [NetherFortressPieceData] = [
        .init(kind: .bridge, weight: 30, limit: 0, repeatable: true),
        .init(kind: .bridgeCrossing, weight: 10, limit: 4, repeatable: false),
        .init(kind: .bridgeSmallCrossing, weight: 10, limit: 4, repeatable: false),
        .init(kind: .bridgeStairs, weight: 10, limit: 3, repeatable: false),
        .init(kind: .bridgePlatform, weight: 5, limit: 2, repeatable: false),
        .init(kind: .corridorExit, weight: 5, limit: 1, repeatable: false)
    ]
    var corridorPieces: [NetherFortressPieceData] = [
        .init(kind: .smallCorridor, weight: 25, limit: 0, repeatable: true),
        .init(kind: .corridorCrossing, weight: 15, limit: 5, repeatable: false),
        .init(kind: .corridorRightTurn, weight: 5, limit: 10, repeatable: false),
        .init(kind: .corridorLeftTurn, weight: 5, limit: 10, repeatable: false),
        .init(kind: .corridorStairs, weight: 10, limit: 3, repeatable: true),
        .init(kind: .corridorBalcony, weight: 7, limit: 2, repeatable: false),
        .init(kind: .corridorNetherWartsRoom, weight: 5, limit: 2, repeatable: false)
    ]

    init(start: NetherFortressPiece) {
        self.start = start
        self.pieces = [start]
    }

    func intersects(_ box: BoundingBox) -> Bool { self.pieces.contains { $0.boundingBox.intersects(box) } }

    func add(_ piece: NetherFortressPiece) {
        self.pieces.append(piece)
        self.pending.append(piece)
    }
}

private final class NetherFortressPiece: StructurePiece {
    let kind: NetherFortressPieceKind
    let chainLength: Int
    private var containsChest = false
    private var chestPlaced = false
    private var spawnerPlaced = false
    private(set) var lootContainers: [StructureLootContainer] = []

    init(kind: NetherFortressPieceKind, chainLength: Int, boundingBox: BoundingBox, orientation: CardinalDirection) {
        self.kind = kind
        self.chainLength = chainLength
        super.init(orientation: orientation, boundingBox: boundingBox)
    }

    override var cachesGeneratedContents: Bool { false }

    func fillOpenings<R: Random>(state: NetherFortressLayoutState, random: inout R) {
        switch self.kind {
        case .bridge: _ = self.forward(state: state, random: &random, left: 1, height: 3, inside: false)
        case .bridgeCrossing:
            _ = self.forward(state: state, random: &random, left: 8, height: 3, inside: false)
            _ = self.northWest(state: state, random: &random, height: 3, left: 8, inside: false)
            _ = self.southEast(state: state, random: &random, height: 3, left: 8, inside: false)
        case .bridgeSmallCrossing:
            _ = self.forward(state: state, random: &random, left: 2, height: 0, inside: false)
            _ = self.northWest(state: state, random: &random, height: 0, left: 2, inside: false)
            _ = self.southEast(state: state, random: &random, height: 0, left: 2, inside: false)
        case .bridgeStairs: _ = self.southEast(state: state, random: &random, height: 6, left: 2, inside: false)
        case .corridorExit: _ = self.forward(state: state, random: &random, left: 5, height: 3, inside: true)
        case .smallCorridor: _ = self.forward(state: state, random: &random, left: 1, height: 0, inside: true)
        case .corridorCrossing:
            _ = self.forward(state: state, random: &random, left: 1, height: 0, inside: true)
            _ = self.northWest(state: state, random: &random, height: 0, left: 1, inside: true)
            _ = self.southEast(state: state, random: &random, height: 0, left: 1, inside: true)
        case .corridorRightTurn: _ = self.southEast(state: state, random: &random, height: 0, left: 1, inside: true)
        case .corridorLeftTurn: _ = self.northWest(state: state, random: &random, height: 0, left: 1, inside: true)
        case .corridorStairs: _ = self.forward(state: state, random: &random, left: 1, height: 0, inside: true)
        case .corridorBalcony:
            let left: Int32 = (self.orientation == .west || self.orientation == .north) ? 5 : 1
            _ = self.northWest(state: state, random: &random, height: 0, left: left, inside: random.next(bound: 8) > 0)
            _ = self.southEast(state: state, random: &random, height: 0, left: left, inside: random.next(bound: 8) > 0)
        case .corridorNetherWartsRoom:
            _ = self.forward(state: state, random: &random, left: 5, height: 3, inside: true)
            _ = self.forward(state: state, random: &random, left: 5, height: 11, inside: true)
        case .bridgePlatform, .bridgeEnd: break
        }
    }

    private func forward<R: Random>(state: NetherFortressLayoutState, random: inout R, left: Int32, height: Int32, inside: Bool) -> NetherFortressPiece? {
        switch self.orientation {
        case .north: return self.generator(state: state, random: &random, x: boundingBox.minX + left, y: boundingBox.minY + height, z: boundingBox.minZ - 1, orientation: .north, inside: inside)
        case .south: return self.generator(state: state, random: &random, x: boundingBox.minX + left, y: boundingBox.minY + height, z: boundingBox.maxZ + 1, orientation: .south, inside: inside)
        case .west: return self.generator(state: state, random: &random, x: boundingBox.minX - 1, y: boundingBox.minY + height, z: boundingBox.minZ + left, orientation: .west, inside: inside)
        case .east: return self.generator(state: state, random: &random, x: boundingBox.maxX + 1, y: boundingBox.minY + height, z: boundingBox.minZ + left, orientation: .east, inside: inside)
        }
    }

    private func northWest<R: Random>(state: NetherFortressLayoutState, random: inout R, height: Int32, left: Int32, inside: Bool) -> NetherFortressPiece? {
        switch self.orientation {
        case .north, .south: return self.generator(state: state, random: &random, x: boundingBox.minX - 1, y: boundingBox.minY + height, z: boundingBox.minZ + left, orientation: .west, inside: inside)
        case .west, .east: return self.generator(state: state, random: &random, x: boundingBox.minX + left, y: boundingBox.minY + height, z: boundingBox.minZ - 1, orientation: .north, inside: inside)
        }
    }

    private func southEast<R: Random>(state: NetherFortressLayoutState, random: inout R, height: Int32, left: Int32, inside: Bool) -> NetherFortressPiece? {
        switch self.orientation {
        case .north, .south: return self.generator(state: state, random: &random, x: boundingBox.maxX + 1, y: boundingBox.minY + height, z: boundingBox.minZ + left, orientation: .east, inside: inside)
        case .west, .east: return self.generator(state: state, random: &random, x: boundingBox.minX + left, y: boundingBox.minY + height, z: boundingBox.maxZ + 1, orientation: .south, inside: inside)
        }
    }

    private func generator<R: Random>(state: NetherFortressLayoutState, random: inout R, x: Int32, y: Int32, z: Int32, orientation: CardinalDirection, inside: Bool) -> NetherFortressPiece? {
        guard abs(x - state.start.boundingBox.minX) <= 112, abs(z - state.start.boundingBox.minZ) <= 112 else {
            return self.create(kind: .bridgeEnd, state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chain: chainLength)
        }
        let piece = self.pickPiece(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, inside: inside)
        if let piece { state.add(piece) }
        return piece
    }

    private func pickPiece<R: Random>(state: NetherFortressLayoutState, random: inout R, x: Int32, y: Int32, z: Int32, orientation: CardinalDirection, inside: Bool) -> NetherFortressPiece? {
        let source = inside ? state.corridorPieces : state.bridgePieces
        let hasLimitedRemaining = source.contains { $0.limit > 0 && $0.canGenerate() }
        let total = hasLimitedRemaining ? source.reduce(0) { $0 + $1.weight } : -1
        // `pieceGenerator` passes `chainLength + 1` to vanilla's picker.
        guard total > 0, chainLength + 1 <= 30 else {
            return self.create(kind: .bridgeEnd, state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chain: chainLength + 1)
        }
        for _ in 0..<5 {
            var choice = Int(random.next(bound: UInt32(total)))
            for data in source {
                choice -= data.weight
                guard choice < 0 else { continue }
                guard data.canGenerate(), (data.kind != state.lastPiece || data.repeatable) else { break }
                // Vanilla keeps scanning the remaining weights after a factory
                // rejects a colliding box, without drawing another random value.
                guard let piece = self.create(kind: data.kind, state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chain: chainLength + 1) else { continue }
                var target = inside ? state.corridorPieces : state.bridgePieces
                guard let index = target.firstIndex(where: { $0.kind == data.kind }) else { return nil }
                target[index].generatedCount += 1
                state.lastPiece = data.kind
                if !target[index].canGenerate() { target.remove(at: index) }
                if inside { state.corridorPieces = target } else { state.bridgePieces = target }
                return piece
            }
        }
        return self.create(kind: .bridgeEnd, state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chain: chainLength + 1)
    }

    private func create<R: Random>(kind: NetherFortressPieceKind, state: NetherFortressLayoutState, random: inout R, x: Int32, y: Int32, z: Int32, orientation: CardinalDirection, chain: Int) -> NetherFortressPiece? {
        let offsets: (Int32, Int32, Int32)
        switch kind {
        case .bridge: offsets = (-1, -3, 0)
        case .bridgeCrossing: offsets = (-8, -3, 0)
        case .bridgeSmallCrossing, .bridgeStairs: offsets = (-2, 0, 0)
        case .bridgePlatform: offsets = (-2, 0, 0)
        case .corridorExit, .corridorNetherWartsRoom: offsets = (-5, -3, 0)
        case .smallCorridor, .corridorCrossing, .corridorRightTurn, .corridorLeftTurn: offsets = (-1, 0, 0)
        case .corridorStairs: offsets = (-1, -7, 0)
        case .corridorBalcony: offsets = (-3, 0, 0)
        case .bridgeEnd: offsets = (-1, -3, 0)
        }
        let dimensions = kind.dimensions
        let box = fortressBox(x: x, y: y, z: z, offsetX: offsets.0, offsetY: offsets.1, offsetZ: offsets.2, width: dimensions.0, height: dimensions.1, depth: dimensions.2, orientation: orientation)
        guard box.minY > 10, !state.intersects(box) else { return nil }
        let piece = NetherFortressPiece(kind: kind, chainLength: chain, boundingBox: box, orientation: orientation)
        switch kind {
        case .corridorLeftTurn, .corridorRightTurn: piece.containsChest = random.next(bound: 3) == 0
        case .bridgeEnd: _ = random.nextInt32()
        default: break
        }
        return piece
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let dimensions = self.kind.dimensions
        let brick = BlockState(id: "minecraft:nether_bricks")
        self.generateBox(world, chunkBox, 0, 0, 0, dimensions.0 - 1, dimensions.1 - 1, dimensions.2 - 1, brick, Blocks.airState)
        // Nether-wart rooms have the vanilla crop beds; the remaining room-specific
        // brick and fence detailing is represented by the shared shell above.
        if self.kind == .corridorNetherWartsRoom {
            self.generateBox(world, chunkBox, 3, 4, 4, 4, 4, 8, BlockState(id: "minecraft:soul_sand"), BlockState(id: "minecraft:soul_sand"))
            self.generateBox(world, chunkBox, 8, 4, 4, 9, 4, 8, BlockState(id: "minecraft:soul_sand"), BlockState(id: "minecraft:soul_sand"))
            self.generateBox(world, chunkBox, 3, 5, 4, 4, 5, 8, BlockState(id: "minecraft:nether_wart"), BlockState(id: "minecraft:nether_wart"))
            self.generateBox(world, chunkBox, 8, 5, 4, 9, 5, 8, BlockState(id: "minecraft:nether_wart"), BlockState(id: "minecraft:nether_wart"))
        }
        if self.kind == .bridgePlatform, !self.spawnerPlaced {
            let pos = self.getWorldPos(3, 5, 5)
            if chunkBox.contains(pos) {
                self.spawnerPlaced = true
                self.placeBlock(world, BlockState(id: "minecraft:spawner"), 3, 5, 5, chunkBox)
                self.placeMarker(world, chunkBox, 3, 5, 5, represents: "minecraft:blaze_spawner")
            }
        }
        guard self.containsChest, !self.chestPlaced else { return }
        let local: (Int32, Int32, Int32) = self.kind == .corridorLeftTurn ? (3, 2, 3) : (1, 2, 3)
        let pos = self.getWorldPos(local.0, local.1, local.2)
        guard chunkBox.contains(pos) else { return }
        self.chestPlaced = true
        self.placeBlock(world, BlockState(id: "minecraft:chest"), local.0, local.1, local.2, chunkBox)
        self.placeMarker(world, chunkBox, local.0, local.1, local.2, represents: "minecraft:chests/nether_bridge")
        self.lootContainers.append(StructureLootContainer(
            block: "minecraft:chest", pos: pos, lootTable: "minecraft:chests/nether_bridge", lootSeed: Int64(bitPattern: random.nextLong())
        ))
    }
}

private func fortressBox(
    x: Int32, y: Int32, z: Int32,
    offsetX: Int32, offsetY: Int32, offsetZ: Int32,
    width: Int32, height: Int32, depth: Int32,
    orientation: CardinalDirection
) -> BoundingBox {
    let minY = y + offsetY
    let maxY = minY + height - 1
    switch orientation {
    case .north:
        let minX = x + offsetX
        let maxZ = z + offsetZ
        return BoundingBox(minX: minX, minY: minY, minZ: maxZ - depth + 1, maxX: minX + width - 1, maxY: maxY, maxZ: maxZ)
    case .south:
        let minX = x + offsetX
        let minZ = z + offsetZ
        return BoundingBox(minX: minX, minY: minY, minZ: minZ, maxX: minX + width - 1, maxY: maxY, maxZ: minZ + depth - 1)
    case .west:
        let maxX = x + offsetZ
        let minZ = z + offsetX
        return BoundingBox(minX: maxX - depth + 1, minY: minY, minZ: minZ, maxX: maxX, maxY: maxY, maxZ: minZ + width - 1)
    case .east:
        let minX = x + offsetZ
        let minZ = z + offsetX
        return BoundingBox(minX: minX, minY: minY, minZ: minZ, maxX: minX + depth - 1, maxY: maxY, maxZ: minZ + width - 1)
    }
}
