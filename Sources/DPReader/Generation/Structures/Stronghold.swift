import Foundation

public typealias StrongholdPieceGraph = PieceGraph

public struct StrongholdLootChestMarker: Equatable {
    public let pos: PosInt3D
    public let lootTable: String
    public let lootSeed: Int64
}

public struct StrongholdGenerationResult {
    public let graph: StrongholdPieceGraph
    public let blocks: StructureBlockVolume
    public let chestLootMarkers: [StrongholdLootChestMarker]
    public let markers: [StructureMarker]
}

public enum Stronghold {
    private static let decoratorStep: Int32 = 4
    private static let decoratorIndex: Int32 = 19

    public static func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> StrongholdPieceGraph {
        let layout = self.generateLayout(
            worldSeed: worldSeed,
            startChunk: startChunk,
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY
        )
        return StrongholdPieceGraph(
            startChunk: startChunk,
            orientation: layout.start.orientation,
            boundingBox: combinedBounds(for: layout.pieces),
            pieces: layout.pieces
        )
    }

    public static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> StrongholdGenerationResult {
        self.generate(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: context,
            decoratorIndex: Self.decoratorIndex,
            decoratorStep: Self.decoratorStep
        )
    }

    static func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext,
        decoratorIndex: Int32,
        decoratorStep: Int32
    ) -> StrongholdGenerationResult {
        let layout = self.generateLayout(
            worldSeed: worldSeed,
            startChunk: startChunk,
            seaLevel: context.seaLevel,
            minimumWorldY: context.minimumWorldY
        )
        let graph = StrongholdPieceGraph(
            startChunk: startChunk,
            orientation: layout.start.orientation,
            boundingBox: combinedBounds(for: layout.pieces),
            pieces: layout.pieces
        )

        let writeBounds = expandedWriteBounds(for: graph.boundingBox, minimumWorldY: context.minimumWorldY)
        let volume = StructureBlockVolume(bounds: writeBounds, fallbackSampler: context.blockSampler)
        var markers: [StructureMarker] = []
        let minChunkX = graph.boundingBox.minX >> 4
        let maxChunkX = graph.boundingBox.maxX >> 4
        let minChunkZ = graph.boundingBox.minZ >> 4
        let maxChunkZ = graph.boundingBox.maxZ >> 4
        for chunkX in minChunkX...maxChunkX {
            for chunkZ in minChunkZ...maxChunkZ {
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed,
                    chunkX: chunkX,
                    chunkZ: chunkZ,
                    decoratorIndex: decoratorIndex,
                    decoratorStep: decoratorStep
                )
                let chunkBox = BoundingBox(
                    minX: chunkX << 4,
                    minY: writeBounds.minY,
                    minZ: chunkZ << 4,
                    maxX: (chunkX << 4) + 15,
                    maxY: writeBounds.maxY,
                    maxZ: (chunkZ << 4) + 15
                )
                let chunkVolume = StructureBlockVolume(bounds: chunkBox, fallbackSampler: context.blockSampler)
                let chunkWorld = StructureWorldView(
                    seaLevel: context.seaLevel,
                    minimumWorldY: context.minimumWorldY,
                    volume: chunkVolume
                )
                for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: chunkWorld, chunkBox: chunkBox, random: &random)
                }
                for (pos, state) in chunkVolume.allTouchedBlocks() {
                    volume.setBlock(state, at: pos)
                }
                markers.append(contentsOf: chunkWorld.markers)
            }
        }
        let chestMarkers = graph.pieces.compactMap { $0 as? StrongholdPiece }.flatMap(\.chestLootMarkers)
        return StrongholdGenerationResult(
            graph: graph,
            blocks: volume,
            chestLootMarkers: chestMarkers,
            markers: markers
        )
    }

    private static func generateLayout(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        seaLevel: Int32,
        minimumWorldY: Int32
    ) -> StrongholdLayout {
        var attempt: UInt64 = 0

        while true {
            var random = getRandomWithCarverSeed(
                worldSeed: worldSeed &+ attempt,
                chunkX: startChunk.x,
                chunkZ: startChunk.z
            )
            let start = StrongholdStart(
                random: &random,
                worldX: startChunk.x &* 16 &+ 2,
                worldZ: startChunk.z &* 16 &+ 2
            )
            let state = StrongholdLayoutState(start: start)
            start.fillOpenings(start: start, state: state, random: &random)

            while !state.pendingPieces.isEmpty {
                let index = Int(random.next(bound: UInt32(state.pendingPieces.count)))
                let piece = state.pendingPieces.remove(at: index)
                piece.fillOpenings(start: start, state: state, random: &random)
            }

            guard start.portalRoom != nil else {
                attempt &+= 1
                continue
            }

            shiftPiecesIntoWorld(
                state.pieces,
                seaLevel: seaLevel,
                minimumWorldY: minimumWorldY,
                random: &random,
                offset: 10
            )
            return StrongholdLayout(start: start, pieces: state.pieces)
        }
    }

    private static func combinedBounds(for pieces: [StructurePiece]) -> BoundingBox {
        guard let first = pieces.first else {
            return BoundingBox(minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0)
        }
        return pieces.dropFirst().reduce(first.boundingBox) { partial, piece in
            partial.union(piece.boundingBox)
        }
    }

    private static func expandedWriteBounds(for boundingBox: BoundingBox, minimumWorldY: Int32) -> BoundingBox {
        BoundingBox(
            minX: boundingBox.minX,
            minY: minimumWorldY + 1,
            minZ: boundingBox.minZ,
            maxX: boundingBox.maxX,
            maxY: boundingBox.maxY,
            maxZ: boundingBox.maxZ
        )
    }

}

private struct StrongholdLayout {
    let start: StrongholdStart
    let pieces: [StructurePiece]
}

private enum StrongholdPieceKind: CaseIterable {
    case corridor
    case prisonHall
    case leftTurn
    case rightTurn
    case squareRoom
    case stairs
    case spiralStaircase
    case fiveWayCrossing
    case chestCorridor
    case library
    case portalRoom
}

private struct StrongholdPieceData {
    let kind: StrongholdPieceKind
    let weight: Int
    let limit: Int
    let minimumChainLength: Int
    var generatedCount: Int = 0

    var canGenerateAgain: Bool {
        self.limit == 0 || self.generatedCount < self.limit
    }

    func canGenerate(chainLength: Int) -> Bool {
        self.canGenerateAgain && chainLength >= self.minimumChainLength
    }
}

private final class StrongholdLayoutState {
    let start: StrongholdStart
    var pieces: [StrongholdPiece]
    var pendingPieces: [StrongholdPiece] = []
    var activePieceKind: StrongholdPieceKind?
    var pieceData: [StrongholdPieceData]

    init(start: StrongholdStart) {
        self.start = start
        self.pieces = [start]
        self.pieceData = [
            StrongholdPieceData(kind: .corridor, weight: 40, limit: 0, minimumChainLength: 0),
            StrongholdPieceData(kind: .prisonHall, weight: 5, limit: 5, minimumChainLength: 0),
            StrongholdPieceData(kind: .leftTurn, weight: 20, limit: 0, minimumChainLength: 0),
            StrongholdPieceData(kind: .rightTurn, weight: 20, limit: 0, minimumChainLength: 0),
            StrongholdPieceData(kind: .squareRoom, weight: 10, limit: 6, minimumChainLength: 0),
            StrongholdPieceData(kind: .stairs, weight: 5, limit: 5, minimumChainLength: 0),
            StrongholdPieceData(kind: .spiralStaircase, weight: 5, limit: 5, minimumChainLength: 0),
            StrongholdPieceData(kind: .fiveWayCrossing, weight: 5, limit: 4, minimumChainLength: 0),
            StrongholdPieceData(kind: .chestCorridor, weight: 5, limit: 4, minimumChainLength: 0),
            StrongholdPieceData(kind: .library, weight: 10, limit: 2, minimumChainLength: 5),
            StrongholdPieceData(kind: .portalRoom, weight: 20, limit: 1, minimumChainLength: 6)
        ]
    }

    func intersecting(_ box: BoundingBox) -> StrongholdPiece? {
        self.pieces.first { $0.boundingBox.intersects(box) }
    }

    func add(_ piece: StrongholdPiece) {
        self.pieces.append(piece)
        self.pendingPieces.append(piece)
    }

    var totalWeight: Int {
        self.pieceData.reduce(into: 0) { $0 += $1.weight }
    }

    func hasRemainingPieces() -> Bool {
        self.pieceData.contains { $0.limit > 0 && $0.generatedCount < $0.limit }
    }

    func recordGenerated(_ kind: StrongholdPieceKind) {
        guard let index = self.pieceData.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        self.pieceData[index].generatedCount += 1
        self.start.lastPieceKind = kind
        if !self.pieceData[index].canGenerateAgain {
            self.pieceData.remove(at: index)
        }
    }
}

private enum StrongholdEntranceType {
    case opening
    case woodDoor
    case grates
    case ironDoor
}

private func randomStrongholdEntrance<R: Random>(using random: inout R) -> StrongholdEntranceType {
    switch Int(random.next(bound: 5)) {
    case 2: return .woodDoor
    case 3: return .grates
    case 4: return .ironDoor
    default: return .opening
    }
}

private enum StrongholdStoneBrickRandomizer {
    static func state<R: Random>(using random: inout R, placeBlock: Bool) -> BlockState {
        guard placeBlock else {
            return Blocks.caveAirState
        }
        let value = random.nextFloat()
        if value < 0.2 {
            return Blocks.crackedStoneBricksState
        }
        if value < 0.5 {
            return Blocks.mossyStoneBricksState
        }
        if value < 0.55 {
            return Blocks.infestedStoneBricksState
        }
        return Blocks.stoneBricksState
    }
}

private class StrongholdPiece: StructurePiece {
    let chainLength: Int
    var entryDoor: StrongholdEntranceType = .opening
    private(set) var chestLootMarkers: [StrongholdLootChestMarker] = []

    init(chainLength: Int, orientation: CardinalDirection, boundingBox: BoundingBox) {
        self.chainLength = chainLength
        super.init(orientation: orientation, boundingBox: boundingBox)
    }

    override var cachesGeneratedContents: Bool {
        false
    }

    func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
    }

    func getRandomEntrance<R: Random>(using random: inout R) -> StrongholdEntranceType {
        randomStrongholdEntrance(using: &random)
    }

    func fillForwardOpening<R: Random>(
        start: StrongholdStart,
        state: StrongholdLayoutState,
        random: inout R,
        leftRightOffset: Int32,
        heightOffset: Int32
    ) -> StrongholdPiece? {
        switch self.orientation {
        case .north:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX + leftRightOffset,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ - 1,
                orientation: .north,
                chainLength: self.chainLength
            )
        case .south:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX + leftRightOffset,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.maxZ + 1,
                orientation: .south,
                chainLength: self.chainLength
            )
        case .west:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX - 1,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ + leftRightOffset,
                orientation: .west,
                chainLength: self.chainLength
            )
        case .east:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.maxX + 1,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ + leftRightOffset,
                orientation: .east,
                chainLength: self.chainLength
            )
        }
    }

    func fillNWOpening<R: Random>(
        start: StrongholdStart,
        state: StrongholdLayoutState,
        random: inout R,
        heightOffset: Int32,
        leftRightOffset: Int32
    ) -> StrongholdPiece? {
        switch self.orientation {
        case .north, .south:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX - 1,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ + leftRightOffset,
                orientation: .west,
                chainLength: self.chainLength
            )
        case .west, .east:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX + leftRightOffset,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ - 1,
                orientation: .north,
                chainLength: self.chainLength
            )
        }
    }

    func fillSEOpening<R: Random>(
        start: StrongholdStart,
        state: StrongholdLayoutState,
        random: inout R,
        heightOffset: Int32,
        leftRightOffset: Int32
    ) -> StrongholdPiece? {
        switch self.orientation {
        case .north, .south:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.maxX + 1,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.minZ + leftRightOffset,
                orientation: .east,
                chainLength: self.chainLength
            )
        case .west, .east:
            return strongholdPieceGenerator(
                start: start,
                state: state,
                random: &random,
                x: self.boundingBox.minX + leftRightOffset,
                y: self.boundingBox.minY + heightOffset,
                z: self.boundingBox.maxZ + 1,
                orientation: .south,
                chainLength: self.chainLength
            )
        }
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
    }

    func placeStrongholdBlock(
        _ world: StructureWorldView,
        _ state: BlockState,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32,
        _ chunkBox: BoundingBox
    ) {
        super.placeBlock(world, self.oriented(state), x, y, z, chunkBox)
    }

    func fillStrongholdBox(
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
                    let state = (x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1) ? boundary : interior
                    self.placeStrongholdBlock(world, state, x, y, z, chunkBox)
                }
            }
        }
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
        boundaryOnly: Bool,
        random: inout R
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    if boundaryOnly && self.getBlock(world, x, y, z, chunkBox).type.isAir {
                        continue
                    }
                    let isBoundary = x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1
                    let placeBlock = boundaryOnly ? isBoundary : true
                    let state = StrongholdStoneBrickRandomizer.state(using: &random, placeBlock: placeBlock)
                    self.placeStrongholdBlock(world, state, x, y, z, chunkBox)
                }
            }
        }
    }

    func addBlockWithRandomThreshold<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        random: inout R,
        threshold: Float,
        x: Int32,
        y: Int32,
        z: Int32,
        state: BlockState
    ) {
        guard random.nextFloat() < threshold else { return }
        self.placeStrongholdBlock(world, state, x, y, z, chunkBox)
    }

    func fillWithRandomThreshold<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        random: inout R,
        threshold: Float,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        state: BlockState
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    guard random.nextFloat() < threshold else { continue }
                    self.placeStrongholdBlock(world, state, x, y, z, chunkBox)
                }
            }
        }
    }

    func generateEntrance<R: Random>(
        _ world: StructureWorldView,
        _ random: inout R,
        _ chunkBox: BoundingBox,
        _ type: StrongholdEntranceType,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32
    ) {
        switch type {
        case .opening:
            self.fillStrongholdBox(world, chunkBox, x, y, z, x + 2, y + 2, z, Blocks.airState, Blocks.airState)
        case .woodDoor:
            let brick = Blocks.stoneBricksState
            self.placeStrongholdBlock(world, brick, x, y, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 1, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y, z, chunkBox)
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:oak_door", facing: .north),
                x + 1,
                y,
                z,
                chunkBox
            )
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:oak_door", facing: .north, properties: ["half": "upper"]),
                x + 1,
                y + 1,
                z,
                chunkBox
            )
        case .grates:
            let westBars = strongholdState("minecraft:iron_bars", ["west": "true"])
            let eastBars = strongholdState("minecraft:iron_bars", ["east": "true"])
            let bothBars = strongholdState("minecraft:iron_bars", ["east": "true", "west": "true"])
            self.placeStrongholdBlock(world, strongholdState("minecraft:cave_air"), x + 1, y, z, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:cave_air"), x + 1, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, westBars, x, y, z, chunkBox)
            self.placeStrongholdBlock(world, westBars, x, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, bothBars, x, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, bothBars, x + 1, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, bothBars, x + 2, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, eastBars, x + 2, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, eastBars, x + 2, y, z, chunkBox)
        case .ironDoor:
            let brick = strongholdState("minecraft:stone_bricks")
            self.placeStrongholdBlock(world, brick, x, y, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 1, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y + 2, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y + 1, z, chunkBox)
            self.placeStrongholdBlock(world, brick, x + 2, y, z, chunkBox)
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:iron_door", facing: .north),
                x + 1,
                y,
                z,
                chunkBox
            )
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:iron_door", facing: .north, properties: ["half": "upper"]),
                x + 1,
                y + 1,
                z,
                chunkBox
            )
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:stone_button", facing: .north),
                x + 2,
                y + 1,
                z + 1,
                chunkBox
            )
            self.placeStrongholdBlock(
                world,
                strongholdDirectionalState("minecraft:stone_button", facing: .south),
                x + 2,
                y + 1,
                z - 1,
                chunkBox
            )
        }
    }

    @discardableResult
    func placeChestMarker<R: Random>(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32,
        random: inout R,
        lootTable: String
    ) -> Bool {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else {
            return false
        }
        let lootSeed = Int64(bitPattern: random.nextLong())
        self.chestLootMarkers.append(
            StrongholdLootChestMarker(pos: pos, lootTable: lootTable, lootSeed: lootSeed)
        )
        self.placeStrongholdBlock(world, strongholdState("minecraft:chest"), x, y, z, chunkBox)
        self.placeMarker(world, chunkBox, x, y, z, represents: lootTable)
        return true
    }

    func worldDirection(for local: CardinalDirection) -> CardinalDirection {
        let origin = self.getWorldPos(0, 0, 0)
        let target: PosInt3D
        switch local {
        case .north:
            target = self.getWorldPos(0, 0, -1)
        case .east:
            target = self.getWorldPos(1, 0, 0)
        case .south:
            target = self.getWorldPos(0, 0, 1)
        case .west:
            target = self.getWorldPos(-1, 0, 0)
        }
        let dx = target.x - origin.x
        let dz = target.z - origin.z
        if abs(dx) > abs(dz) {
            return dx > 0 ? .east : .west
        }
        return dz > 0 ? .south : .north
    }

    private func oriented(_ state: BlockState) -> BlockState {
        guard let properties = state.properties, !properties.isEmpty else {
            return state
        }
        var transformed = properties
        if let facing = properties["facing"], let localFacing = cardinalDirection(from: facing) {
            transformed["facing"] = self.worldDirection(for: localFacing).rawValue
        }

        let directionalKeys = ["north", "east", "south", "west"]
        if directionalKeys.contains(where: { properties[$0] != nil }) {
            for key in directionalKeys {
                transformed.removeValue(forKey: key)
            }
            for key in directionalKeys {
                guard let value = properties[key], let localDirection = cardinalDirection(from: key) else { continue }
                transformed[self.worldDirection(for: localDirection).rawValue] = value
            }
        }

        return BlockState(type: state.type, properties: transformed)
    }

    class func isInBounds(_ boundingBox: BoundingBox) -> Bool {
        boundingBox.minY > 10
    }
}

private final class StrongholdChestCorridor: StrongholdPiece {
    private var chestGenerated = false

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 1, heightOffset: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 4, 6, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 1, 0)
        self.generateEntrance(world, &random, chunkBox, .opening, 1, 1, 6)
        let brick = strongholdState("minecraft:stone_bricks")
        let slab = strongholdState("minecraft:stone_brick_slab")
        self.fillStrongholdBox(world, chunkBox, 3, 1, 2, 3, 1, 4, brick, brick)
        self.placeStrongholdBlock(world, slab, 3, 1, 1, chunkBox)
        self.placeStrongholdBlock(world, slab, 3, 1, 5, chunkBox)
        self.placeStrongholdBlock(world, slab, 3, 2, 2, chunkBox)
        self.placeStrongholdBlock(world, slab, 3, 2, 4, chunkBox)
        for z in 2...4 {
            self.placeStrongholdBlock(world, slab, 2, 1, Int32(z), chunkBox)
        }
        if !self.chestGenerated,
           self.placeChestMarker(world, chunkBox, 3, 2, 3, random: &random, lootTable: "minecraft:chests/stronghold_corridor") {
            self.chestGenerated = true
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdChestCorridor? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -1, offsetZ: 0, width: 5, height: 5, depth: 7, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdChestCorridor(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdCorridor: StrongholdPiece {
    private var leftExitExists = false
    private var rightExitExists = false

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        let entryDoor = randomStrongholdEntrance(using: &random)
        let leftExitExists = random.next(bound: 2) == 0
        let rightExitExists = random.next(bound: 2) == 0
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = entryDoor
        self.leftExitExists = leftExitExists
        self.rightExitExists = rightExitExists
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 1, heightOffset: 1)
        if self.leftExitExists {
            _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 2)
        }
        if self.rightExitExists {
            _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 2)
        }
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 4, 6, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 1, 0)
        self.generateEntrance(world, &random, chunkBox, .opening, 1, 1, 6)
        let eastTorch = strongholdDirectionalState("minecraft:wall_torch", facing: .east)
        let westTorch = strongholdDirectionalState("minecraft:wall_torch", facing: .west)
        self.addBlockWithRandomThreshold(world, chunkBox, random: &random, threshold: 0.1, x: 1, y: 2, z: 1, state: eastTorch)
        self.addBlockWithRandomThreshold(world, chunkBox, random: &random, threshold: 0.1, x: 3, y: 2, z: 1, state: westTorch)
        self.addBlockWithRandomThreshold(world, chunkBox, random: &random, threshold: 0.1, x: 1, y: 2, z: 5, state: eastTorch)
        self.addBlockWithRandomThreshold(world, chunkBox, random: &random, threshold: 0.1, x: 3, y: 2, z: 5, state: westTorch)
        if self.leftExitExists {
            self.fillStrongholdBox(world, chunkBox, 0, 1, 2, 0, 3, 4, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
        if self.rightExitExists {
            self.fillStrongholdBox(world, chunkBox, 4, 1, 2, 4, 3, 4, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdCorridor? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -1, offsetZ: 0, width: 5, height: 5, depth: 7, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdCorridor(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdFiveWayCrossing: StrongholdPiece {
    private var lowerLeftExists = false
    private var upperLeftExists = false
    private var lowerRightExists = false
    private var upperRightExists = false

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        let entryDoor = randomStrongholdEntrance(using: &random)
        let lowerLeftExists = random.nextBoolean()
        let upperLeftExists = random.nextBoolean()
        let lowerRightExists = random.nextBoolean()
        let upperRightExists = random.next(bound: 3) > 0
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = entryDoor
        self.lowerLeftExists = lowerLeftExists
        self.upperLeftExists = upperLeftExists
        self.lowerRightExists = lowerRightExists
        self.upperRightExists = upperRightExists
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        var lower = Int32(3)
        var upper = Int32(5)
        if self.orientation == .west || self.orientation == .north {
            lower = 8 - lower
            upper = 8 - upper
        }
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 5, heightOffset: 1)
        if self.lowerLeftExists {
            _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: lower, leftRightOffset: 1)
        }
        if self.upperLeftExists {
            _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: upper, leftRightOffset: 7)
        }
        if self.lowerRightExists {
            _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: lower, leftRightOffset: 1)
        }
        if self.upperRightExists {
            _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: upper, leftRightOffset: 7)
        }
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 9, 8, 10, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 4, 3, 0)
        if self.lowerLeftExists {
            self.fillStrongholdBox(world, chunkBox, 0, 3, 1, 0, 5, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
        if self.lowerRightExists {
            self.fillStrongholdBox(world, chunkBox, 9, 3, 1, 9, 5, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
        if self.upperLeftExists {
            self.fillStrongholdBox(world, chunkBox, 0, 5, 7, 0, 7, 9, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
        if self.upperRightExists {
            self.fillStrongholdBox(world, chunkBox, 9, 5, 7, 9, 7, 9, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
        self.fillStrongholdBox(world, chunkBox, 5, 1, 10, 7, 3, 10, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        self.fillRandomizedBox(world, chunkBox, 1, 2, 1, 8, 2, 6, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 5, 4, 4, 9, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 8, 1, 5, 8, 4, 9, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 4, 7, 3, 4, 9, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 3, 5, 3, 3, 6, boundaryOnly: false, random: &random)
        let slab = strongholdState("minecraft:smooth_stone_slab")
        let doubleSlab = strongholdState("minecraft:smooth_stone_slab", ["type": "double"])
        self.fillStrongholdBox(world, chunkBox, 1, 3, 4, 3, 3, 4, slab, slab)
        self.fillStrongholdBox(world, chunkBox, 1, 4, 6, 3, 4, 6, slab, slab)
        self.fillRandomizedBox(world, chunkBox, 5, 1, 7, 7, 1, 8, boundaryOnly: false, random: &random)
        self.fillStrongholdBox(world, chunkBox, 5, 1, 9, 7, 1, 9, slab, slab)
        self.fillStrongholdBox(world, chunkBox, 5, 2, 7, 7, 2, 7, slab, slab)
        self.fillStrongholdBox(world, chunkBox, 4, 5, 7, 4, 5, 9, slab, slab)
        self.fillStrongholdBox(world, chunkBox, 8, 5, 7, 8, 5, 9, slab, slab)
        self.fillStrongholdBox(world, chunkBox, 5, 5, 7, 7, 5, 9, doubleSlab, doubleSlab)
        self.placeStrongholdBlock(world, strongholdDirectionalState("minecraft:wall_torch", facing: .south), 6, 5, 6, chunkBox)
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdFiveWayCrossing? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -4, offsetY: -3, offsetZ: 0, width: 10, height: 9, depth: 11, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdFiveWayCrossing(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private class StrongholdTurn: StrongholdPiece {
}

private final class StrongholdLeftTurn: StrongholdTurn {
    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        if self.orientation != .north && self.orientation != .east {
            _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 1)
        } else {
            _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 1)
        }
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 4, 4, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 1, 0)
        if self.orientation != .north && self.orientation != .east {
            self.fillStrongholdBox(world, chunkBox, 4, 1, 1, 4, 3, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        } else {
            self.fillStrongholdBox(world, chunkBox, 0, 1, 1, 0, 3, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdLeftTurn? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -1, offsetZ: 0, width: 5, height: 5, depth: 5, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdLeftTurn(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdLibrary: StrongholdPiece {
    private let tall: Bool

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        self.tall = boundingBox.maxY - boundingBox.minY + 1 > 6
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let height: Int32 = self.tall ? 11 : 6
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 13, height - 1, 14, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 4, 1, 0)
        self.fillWithRandomThreshold(world, chunkBox, random: &random, threshold: 0.07, 2, 1, 1, 11, 4, 13, state: strongholdState("minecraft:cobweb"))

        let planks = strongholdState("minecraft:oak_planks")
        let bookshelves = strongholdState("minecraft:bookshelf")
        let eastTorch = strongholdDirectionalState("minecraft:wall_torch", facing: .east)
        let westTorch = strongholdDirectionalState("minecraft:wall_torch", facing: .west)
        for z in 1...13 {
            let zPos = Int32(z)
            if (z - 1) % 4 == 0 {
                self.fillStrongholdBox(world, chunkBox, 1, 1, zPos, 1, 4, zPos, planks, planks)
                self.fillStrongholdBox(world, chunkBox, 12, 1, zPos, 12, 4, zPos, planks, planks)
                self.placeStrongholdBlock(world, eastTorch, 2, 3, zPos, chunkBox)
                self.placeStrongholdBlock(world, westTorch, 11, 3, zPos, chunkBox)
                if self.tall {
                    self.fillStrongholdBox(world, chunkBox, 1, 6, zPos, 1, 9, zPos, planks, planks)
                    self.fillStrongholdBox(world, chunkBox, 12, 6, zPos, 12, 9, zPos, planks, planks)
                }
            } else {
                self.fillStrongholdBox(world, chunkBox, 1, 1, zPos, 1, 4, zPos, bookshelves, bookshelves)
                self.fillStrongholdBox(world, chunkBox, 12, 1, zPos, 12, 4, zPos, bookshelves, bookshelves)
                if self.tall {
                    self.fillStrongholdBox(world, chunkBox, 1, 6, zPos, 1, 9, zPos, bookshelves, bookshelves)
                    self.fillStrongholdBox(world, chunkBox, 12, 6, zPos, 12, 9, zPos, bookshelves, bookshelves)
                }
            }
        }

        for z in stride(from: 3, to: 12, by: 2) {
            let zPos = Int32(z)
            self.fillStrongholdBox(world, chunkBox, 3, 1, zPos, 4, 3, zPos, bookshelves, bookshelves)
            self.fillStrongholdBox(world, chunkBox, 6, 1, zPos, 7, 3, zPos, bookshelves, bookshelves)
            self.fillStrongholdBox(world, chunkBox, 9, 1, zPos, 10, 3, zPos, bookshelves, bookshelves)
        }

        if self.tall {
            self.fillStrongholdBox(world, chunkBox, 1, 5, 1, 3, 5, 13, planks, planks)
            self.fillStrongholdBox(world, chunkBox, 10, 5, 1, 12, 5, 13, planks, planks)
            self.fillStrongholdBox(world, chunkBox, 4, 5, 1, 9, 5, 2, planks, planks)
            self.fillStrongholdBox(world, chunkBox, 4, 5, 12, 9, 5, 13, planks, planks)
            self.placeStrongholdBlock(world, planks, 9, 5, 11, chunkBox)
            self.placeStrongholdBlock(world, planks, 8, 5, 11, chunkBox)
            self.placeStrongholdBlock(world, planks, 9, 5, 10, chunkBox)

            let fenceEW = strongholdState("minecraft:oak_fence", ["west": "true", "east": "true"])
            let fenceNS = strongholdState("minecraft:oak_fence", ["north": "true", "south": "true"])
            self.fillStrongholdBox(world, chunkBox, 3, 6, 3, 3, 6, 11, fenceNS, fenceNS)
            self.fillStrongholdBox(world, chunkBox, 10, 6, 3, 10, 6, 9, fenceNS, fenceNS)
            self.fillStrongholdBox(world, chunkBox, 4, 6, 2, 9, 6, 2, fenceEW, fenceEW)
            self.fillStrongholdBox(world, chunkBox, 4, 6, 12, 7, 6, 12, fenceEW, fenceEW)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["north": "true", "east": "true"]), 3, 6, 2, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["south": "true", "east": "true"]), 3, 6, 12, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["north": "true", "west": "true"]), 10, 6, 2, chunkBox)

            for step in 0...2 {
                let offset = Int32(step)
                self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["south": "true", "west": "true"]), 8 + offset, 6, 12 - offset, chunkBox)
                if step != 2 {
                    self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["north": "true", "east": "true"]), 8 + offset, 6, 11 - offset, chunkBox)
                }
            }

            let ladder = strongholdDirectionalState("minecraft:ladder", facing: .south)
            for y in 1...7 {
                self.placeStrongholdBlock(world, ladder, 10, Int32(y), 13, chunkBox)
            }

            let fenceEast = strongholdState("minecraft:oak_fence", ["east": "true"])
            let fenceWest = strongholdState("minecraft:oak_fence", ["west": "true"])
            let fenceBoth = strongholdState("minecraft:oak_fence", ["west": "true", "east": "true", "north": "true", "south": "true"])
            self.placeStrongholdBlock(world, fenceEast, 6, 9, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceWest, 7, 9, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceEast, 6, 8, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceWest, 7, 8, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceBoth, 6, 7, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceBoth, 7, 7, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceEast, 5, 7, 7, chunkBox)
            self.placeStrongholdBlock(world, fenceWest, 8, 7, 7, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["east": "true", "north": "true"]), 6, 7, 6, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["east": "true", "south": "true"]), 6, 7, 8, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["west": "true", "north": "true"]), 7, 7, 6, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:oak_fence", ["west": "true", "south": "true"]), 7, 7, 8, chunkBox)
            let torch = strongholdState("minecraft:torch")
            self.placeStrongholdBlock(world, torch, 5, 8, 7, chunkBox)
            self.placeStrongholdBlock(world, torch, 8, 8, 7, chunkBox)
            self.placeStrongholdBlock(world, torch, 6, 8, 6, chunkBox)
            self.placeStrongholdBlock(world, torch, 6, 8, 8, chunkBox)
            self.placeStrongholdBlock(world, torch, 7, 8, 6, chunkBox)
            self.placeStrongholdBlock(world, torch, 7, 8, 8, chunkBox)
        }

        self.placeChestMarker(world, chunkBox, 3, 3, 5, random: &random, lootTable: "minecraft:chests/stronghold_library")
        if self.tall {
            self.placeStrongholdBlock(world, strongholdState("minecraft:air"), 12, 9, 1, chunkBox)
            self.placeChestMarker(world, chunkBox, 12, 8, 1, random: &random, lootTable: "minecraft:chests/stronghold_library")
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdLibrary? {
        var box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -4, offsetY: -1, offsetZ: 0, width: 14, height: 11, depth: 15, orientation: orientation)
        if !Self.isInBounds(box) || state.intersecting(box) != nil {
            box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -4, offsetY: -1, offsetZ: 0, width: 14, height: 6, depth: 15, orientation: orientation)
            guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        }
        return StrongholdLibrary(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdPortalRoom: StrongholdPiece {
    private var spawnerPlaced = false

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        start.portalRoom = self
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 10, 7, 15, boundaryOnly: false, random: &random)
        self.generateEntrance(world, &random, chunkBox, .grates, 4, 1, 0)
        self.fillRandomizedBox(world, chunkBox, 1, 6, 1, 1, 6, 14, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 9, 6, 1, 9, 6, 14, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 6, 1, 8, 6, 2, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 2, 6, 14, 8, 6, 14, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 1, 1, 1, 2, 1, 4, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 8, 1, 1, 9, 1, 4, boundaryOnly: false, random: &random)
        let lava = strongholdState("minecraft:lava")
        self.fillStrongholdBox(world, chunkBox, 1, 1, 1, 1, 1, 3, lava, lava)
        self.fillStrongholdBox(world, chunkBox, 9, 1, 1, 9, 1, 3, lava, lava)
        self.fillRandomizedBox(world, chunkBox, 3, 1, 8, 7, 1, 12, boundaryOnly: false, random: &random)
        self.fillStrongholdBox(world, chunkBox, 4, 1, 9, 6, 1, 11, lava, lava)

        let barsNS = strongholdState("minecraft:iron_bars", ["north": "true", "south": "true"])
        let barsEW = strongholdState("minecraft:iron_bars", ["west": "true", "east": "true"])
        for z in stride(from: 3, to: 14, by: 2) {
            let zPos = Int32(z)
            self.fillStrongholdBox(world, chunkBox, 0, 3, zPos, 0, 4, zPos, barsNS, barsNS)
            self.fillStrongholdBox(world, chunkBox, 10, 3, zPos, 10, 4, zPos, barsNS, barsNS)
        }
        for x in stride(from: 2, to: 9, by: 2) {
            let xPos = Int32(x)
            self.fillStrongholdBox(world, chunkBox, xPos, 3, 15, xPos, 4, 15, barsEW, barsEW)
        }

        let stairs = strongholdDirectionalState("minecraft:stone_brick_stairs", facing: .north)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 5, 6, 1, 7, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 2, 6, 6, 2, 7, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 3, 7, 6, 3, 7, boundaryOnly: false, random: &random)
        for x in 4...6 {
            let xPos = Int32(x)
            self.placeStrongholdBlock(world, stairs, xPos, 1, 4, chunkBox)
            self.placeStrongholdBlock(world, stairs, xPos, 2, 5, chunkBox)
            self.placeStrongholdBlock(world, stairs, xPos, 3, 6, chunkBox)
        }

        let northFrame = strongholdDirectionalState("minecraft:end_portal_frame", facing: .north)
        let southFrame = strongholdDirectionalState("minecraft:end_portal_frame", facing: .south)
        let eastFrame = strongholdDirectionalState("minecraft:end_portal_frame", facing: .east)
        let westFrame = strongholdDirectionalState("minecraft:end_portal_frame", facing: .west)
        var allEyes = true
        var eyes: [Bool] = []
        eyes.reserveCapacity(12)
        for _ in 0..<12 {
            let hasEye = random.nextFloat() > 0.9
            eyes.append(hasEye)
            allEyes = allEyes && hasEye
        }

        self.placeStrongholdBlock(world, withEye(northFrame, eyes[0]), 4, 3, 8, chunkBox)
        self.placeStrongholdBlock(world, withEye(northFrame, eyes[1]), 5, 3, 8, chunkBox)
        self.placeStrongholdBlock(world, withEye(northFrame, eyes[2]), 6, 3, 8, chunkBox)
        self.placeStrongholdBlock(world, withEye(southFrame, eyes[3]), 4, 3, 12, chunkBox)
        self.placeStrongholdBlock(world, withEye(southFrame, eyes[4]), 5, 3, 12, chunkBox)
        self.placeStrongholdBlock(world, withEye(southFrame, eyes[5]), 6, 3, 12, chunkBox)
        self.placeStrongholdBlock(world, withEye(eastFrame, eyes[6]), 3, 3, 9, chunkBox)
        self.placeStrongholdBlock(world, withEye(eastFrame, eyes[7]), 3, 3, 10, chunkBox)
        self.placeStrongholdBlock(world, withEye(eastFrame, eyes[8]), 3, 3, 11, chunkBox)
        self.placeStrongholdBlock(world, withEye(westFrame, eyes[9]), 7, 3, 9, chunkBox)
        self.placeStrongholdBlock(world, withEye(westFrame, eyes[10]), 7, 3, 10, chunkBox)
        self.placeStrongholdBlock(world, withEye(westFrame, eyes[11]), 7, 3, 11, chunkBox)

        if allEyes {
            let portal = strongholdState("minecraft:end_portal")
            for x in 4...6 {
                for z in 9...11 {
                    self.placeStrongholdBlock(world, portal, Int32(x), 3, Int32(z), chunkBox)
                }
            }
            self.placeMarker(world, chunkBox, 5, 3, 10, represents: "minecraft:end_portal")
        }

        let spawnerPos = self.getWorldPos(5, 3, 6)
        if !self.spawnerPlaced, chunkBox.contains(spawnerPos) {
            self.spawnerPlaced = true
            self.placeStrongholdBlock(world, strongholdState("minecraft:spawner"), 5, 3, 6, chunkBox)
            self.placeMarker(world, chunkBox, 5, 3, 6, represents: "minecraft:silverfish_spawner")
        }
    }

    static func create(
        state: StrongholdLayoutState,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdPortalRoom? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -4, offsetY: -1, offsetZ: 0, width: 11, height: 8, depth: 16, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdPortalRoom(chainLength: chainLength, orientation: orientation, boundingBox: box)
    }
}

private final class StrongholdPrisonHall: StrongholdPiece {
    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 1, heightOffset: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 8, 4, 10, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 1, 0)
        self.fillStrongholdBox(world, chunkBox, 1, 1, 10, 3, 3, 10, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        self.fillRandomizedBox(world, chunkBox, 4, 1, 1, 4, 3, 1, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 3, 4, 3, 3, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 7, 4, 3, 7, boundaryOnly: false, random: &random)
        self.fillRandomizedBox(world, chunkBox, 4, 1, 9, 4, 3, 9, boundaryOnly: false, random: &random)

        let barsNS = strongholdState("minecraft:iron_bars", ["north": "true", "south": "true"])
        let barsCenter = strongholdState("minecraft:iron_bars", ["north": "true", "south": "true", "east": "true"])
        let barsEW = strongholdState("minecraft:iron_bars", ["west": "true", "east": "true"])
        for y in 1...3 {
            let yPos = Int32(y)
            self.placeStrongholdBlock(world, barsNS, 4, yPos, 4, chunkBox)
            self.placeStrongholdBlock(world, barsCenter, 4, yPos, 5, chunkBox)
            self.placeStrongholdBlock(world, barsNS, 4, yPos, 6, chunkBox)
            self.placeStrongholdBlock(world, barsEW, 5, yPos, 5, chunkBox)
            self.placeStrongholdBlock(world, barsEW, 6, yPos, 5, chunkBox)
            self.placeStrongholdBlock(world, barsEW, 7, yPos, 5, chunkBox)
        }
        self.placeStrongholdBlock(world, barsNS, 4, 3, 2, chunkBox)
        self.placeStrongholdBlock(world, barsNS, 4, 3, 8, chunkBox)
        let ironDoorLower = strongholdDirectionalState("minecraft:iron_door", facing: .west)
        let ironDoorUpper = strongholdDirectionalState("minecraft:iron_door", facing: .west, properties: ["half": "upper"])
        self.placeStrongholdBlock(world, ironDoorLower, 4, 1, 2, chunkBox)
        self.placeStrongholdBlock(world, ironDoorUpper, 4, 2, 2, chunkBox)
        self.placeStrongholdBlock(world, ironDoorLower, 4, 1, 8, chunkBox)
        self.placeStrongholdBlock(world, ironDoorUpper, 4, 2, 8, chunkBox)
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdPrisonHall? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -1, offsetZ: 0, width: 9, height: 5, depth: 11, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdPrisonHall(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdRightTurn: StrongholdTurn {
    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        if self.orientation != .north && self.orientation != .east {
            _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 1)
        } else {
            _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 1)
        }
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 4, 4, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 1, 0)
        if self.orientation != .north && self.orientation != .east {
            self.fillStrongholdBox(world, chunkBox, 0, 1, 1, 0, 3, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        } else {
            self.fillStrongholdBox(world, chunkBox, 4, 1, 1, 4, 3, 3, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdRightTurn? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -1, offsetZ: 0, width: 5, height: 5, depth: 5, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdRightTurn(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdSmallCorridor: StrongholdPiece {
    private let length: Int32

    init(chainLength: Int, boundingBox: BoundingBox, orientation: CardinalDirection) {
        if orientation == .north || orientation == .south {
            self.length = boundingBox.maxZ - boundingBox.minZ + 1
        } else {
            self.length = boundingBox.maxX - boundingBox.minX + 1
        }
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let brick = strongholdState("minecraft:stone_bricks")
        let air = strongholdState("minecraft:cave_air")
        for z in 0..<self.length {
            for x in 0...4 {
                let xPos = Int32(x)
                self.placeStrongholdBlock(world, brick, xPos, 0, z, chunkBox)
                self.placeStrongholdBlock(world, brick, xPos, 4, z, chunkBox)
            }
            for y in 1...3 {
                let yPos = Int32(y)
                self.placeStrongholdBlock(world, brick, 0, yPos, z, chunkBox)
                self.placeStrongholdBlock(world, air, 1, yPos, z, chunkBox)
                self.placeStrongholdBlock(world, air, 2, yPos, z, chunkBox)
                self.placeStrongholdBlock(world, air, 3, yPos, z, chunkBox)
                self.placeStrongholdBlock(world, brick, 4, yPos, z, chunkBox)
            }
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection
    ) -> BoundingBox? {
        guard let intersecting = state.intersecting(rotatedStrongholdBox(
            x: x,
            y: y,
            z: z,
            offsetX: -1,
            offsetY: -1,
            offsetZ: 0,
            width: 5,
            height: 5,
            depth: 4,
            orientation: orientation
        )) else {
            return nil
        }

        guard intersecting.boundingBox.minY == y - 1 else {
            return nil
        }

        for depth in stride(from: 2, through: 1, by: -1) {
            let box = rotatedStrongholdBox(
                x: x,
                y: y,
                z: z,
                offsetX: -1,
                offsetY: -1,
                offsetZ: 0,
                width: 5,
                height: 5,
                depth: Int32(depth),
                orientation: orientation
            )
            if !intersecting.boundingBox.intersects(box) {
                return rotatedStrongholdBox(
                    x: x,
                    y: y,
                    z: z,
                    offsetX: -1,
                    offsetY: -1,
                    offsetZ: 0,
                    width: 5,
                    height: 5,
                    depth: Int32(depth + 1),
                    orientation: orientation
                )
            }
        }

        return nil
    }
}

private class StrongholdSpiralStaircase: StrongholdPiece {
    private let isStructureStart: Bool

    init(worldX: Int32, worldZ: Int32, orientation: CardinalDirection) {
        self.isStructureStart = true
        let box = startStrongholdBox(x: worldX, y: 64, z: worldZ, orientation: orientation, width: 5, height: 11, depth: 5)
        super.init(chainLength: 0, orientation: orientation, boundingBox: box)
        self.entryDoor = .opening
    }

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        self.isStructureStart = false
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        if self.isStructureStart {
            state.activePieceKind = .fiveWayCrossing
        }
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 1, heightOffset: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 10, 4, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 7, 0)
        self.generateEntrance(world, &random, chunkBox, .opening, 1, 1, 4)
        let brick = strongholdState("minecraft:stone_bricks")
        let slab = strongholdState("minecraft:smooth_stone_slab")
        self.placeStrongholdBlock(world, brick, 2, 6, 1, chunkBox)
        self.placeStrongholdBlock(world, brick, 1, 5, 1, chunkBox)
        self.placeStrongholdBlock(world, slab, 1, 6, 1, chunkBox)
        self.placeStrongholdBlock(world, brick, 1, 5, 2, chunkBox)
        self.placeStrongholdBlock(world, brick, 1, 4, 3, chunkBox)
        self.placeStrongholdBlock(world, slab, 1, 5, 3, chunkBox)
        self.placeStrongholdBlock(world, brick, 2, 4, 3, chunkBox)
        self.placeStrongholdBlock(world, brick, 3, 3, 3, chunkBox)
        self.placeStrongholdBlock(world, slab, 3, 4, 3, chunkBox)
        self.placeStrongholdBlock(world, brick, 3, 3, 2, chunkBox)
        self.placeStrongholdBlock(world, brick, 3, 2, 1, chunkBox)
        self.placeStrongholdBlock(world, slab, 3, 3, 1, chunkBox)
        self.placeStrongholdBlock(world, brick, 2, 2, 1, chunkBox)
        self.placeStrongholdBlock(world, brick, 1, 1, 1, chunkBox)
        self.placeStrongholdBlock(world, slab, 1, 2, 1, chunkBox)
        self.placeStrongholdBlock(world, brick, 1, 1, 2, chunkBox)
        self.placeStrongholdBlock(world, slab, 1, 1, 3, chunkBox)
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdSpiralStaircase? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -7, offsetZ: 0, width: 5, height: 11, depth: 5, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdSpiralStaircase(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdSquareRoom: StrongholdPiece {
    fileprivate var roomType = 0

    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        let entryDoor = randomStrongholdEntrance(using: &random)
        let roomType = Int(random.next(bound: 5))
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = entryDoor
        self.roomType = roomType
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 4, heightOffset: 1)
        _ = self.fillNWOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 4)
        _ = self.fillSEOpening(start: start, state: state, random: &random, heightOffset: 1, leftRightOffset: 4)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 10, 6, 10, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 4, 1, 0)
        self.fillStrongholdBox(world, chunkBox, 4, 1, 10, 6, 3, 10, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        self.fillStrongholdBox(world, chunkBox, 0, 1, 4, 0, 3, 6, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        self.fillStrongholdBox(world, chunkBox, 10, 1, 4, 10, 3, 6, strongholdState("minecraft:air"), strongholdState("minecraft:air"))
        let brick = strongholdState("minecraft:stone_bricks")
        let slab = strongholdState("minecraft:smooth_stone_slab")
        switch self.roomType {
        case 0:
            self.placeStrongholdBlock(world, brick, 5, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, brick, 5, 2, 5, chunkBox)
            self.placeStrongholdBlock(world, brick, 5, 3, 5, chunkBox)
            self.placeStrongholdBlock(world, strongholdDirectionalState("minecraft:wall_torch", facing: .west), 4, 3, 5, chunkBox)
            self.placeStrongholdBlock(world, strongholdDirectionalState("minecraft:wall_torch", facing: .east), 6, 3, 5, chunkBox)
            self.placeStrongholdBlock(world, strongholdDirectionalState("minecraft:wall_torch", facing: .south), 5, 3, 4, chunkBox)
            self.placeStrongholdBlock(world, strongholdDirectionalState("minecraft:wall_torch", facing: .north), 5, 3, 6, chunkBox)
            self.placeStrongholdBlock(world, slab, 4, 1, 4, chunkBox)
            self.placeStrongholdBlock(world, slab, 4, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, slab, 4, 1, 6, chunkBox)
            self.placeStrongholdBlock(world, slab, 5, 1, 4, chunkBox)
            self.placeStrongholdBlock(world, slab, 5, 1, 6, chunkBox)
            self.placeStrongholdBlock(world, slab, 6, 1, 4, chunkBox)
            self.placeStrongholdBlock(world, slab, 6, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, slab, 6, 1, 6, chunkBox)
        case 1:
            for offset in 0..<5 {
                let value = Int32(offset)
                self.placeStrongholdBlock(world, brick, 3, 1, 3 + value, chunkBox)
                self.placeStrongholdBlock(world, brick, 7, 1, 3 + value, chunkBox)
                self.placeStrongholdBlock(world, brick, 3 + value, 1, 3, chunkBox)
                self.placeStrongholdBlock(world, brick, 3 + value, 1, 7, chunkBox)
            }
            self.placeStrongholdBlock(world, brick, 5, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, brick, 5, 2, 5, chunkBox)
            self.placeStrongholdBlock(world, brick, 5, 3, 5, chunkBox)
            self.placeStrongholdBlock(world, strongholdState("minecraft:water"), 5, 4, 5, chunkBox)
        case 2:
            let cobblestone = strongholdState("minecraft:cobblestone")
            let planks = strongholdState("minecraft:oak_planks")
            for i in 1...9 {
                let v = Int32(i)
                self.placeStrongholdBlock(world, cobblestone, 1, 3, v, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, 9, 3, v, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, v, 3, 1, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, v, 3, 9, chunkBox)
            }
            self.placeStrongholdBlock(world, cobblestone, 5, 1, 4, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 5, 1, 6, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 5, 3, 4, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 5, 3, 6, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 4, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 6, 1, 5, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 4, 3, 5, chunkBox)
            self.placeStrongholdBlock(world, cobblestone, 6, 3, 5, chunkBox)
            for y in 1...3 {
                let yPos = Int32(y)
                self.placeStrongholdBlock(world, cobblestone, 4, yPos, 4, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, 6, yPos, 4, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, 4, yPos, 6, chunkBox)
                self.placeStrongholdBlock(world, cobblestone, 6, yPos, 6, chunkBox)
            }
            self.placeStrongholdBlock(world, strongholdState("minecraft:wall_torch"), 5, 3, 5, chunkBox)
            for z in 2...8 {
                let zPos = Int32(z)
                self.placeStrongholdBlock(world, planks, 2, 3, zPos, chunkBox)
                self.placeStrongholdBlock(world, planks, 3, 3, zPos, chunkBox)
                if z <= 3 || z >= 7 {
                    self.placeStrongholdBlock(world, planks, 4, 3, zPos, chunkBox)
                    self.placeStrongholdBlock(world, planks, 5, 3, zPos, chunkBox)
                    self.placeStrongholdBlock(world, planks, 6, 3, zPos, chunkBox)
                }
                self.placeStrongholdBlock(world, planks, 7, 3, zPos, chunkBox)
                self.placeStrongholdBlock(world, planks, 8, 3, zPos, chunkBox)
            }
            let ladder = strongholdDirectionalState("minecraft:ladder", facing: .west)
            self.placeStrongholdBlock(world, ladder, 9, 1, 3, chunkBox)
            self.placeStrongholdBlock(world, ladder, 9, 2, 3, chunkBox)
            self.placeStrongholdBlock(world, ladder, 9, 3, 3, chunkBox)
            self.placeChestMarker(world, chunkBox, 3, 4, 8, random: &random, lootTable: "minecraft:chests/stronghold_crossing")
        default:
            break
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdSquareRoom? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -4, offsetY: -1, offsetZ: 0, width: 11, height: 7, depth: 11, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdSquareRoom(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdStairs: StrongholdPiece {
    init<R: Random>(chainLength: Int, random: inout R, boundingBox: BoundingBox, orientation: CardinalDirection) {
        super.init(chainLength: chainLength, orientation: orientation, boundingBox: boundingBox)
        self.entryDoor = self.getRandomEntrance(using: &random)
    }

    override func fillOpenings<R: Random>(start: StrongholdStart, state: StrongholdLayoutState, random: inout R) {
        _ = self.fillForwardOpening(start: start, state: state, random: &random, leftRightOffset: 1, heightOffset: 1)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        self.fillRandomizedBox(world, chunkBox, 0, 0, 0, 4, 10, 7, boundaryOnly: true, random: &random)
        self.generateEntrance(world, &random, chunkBox, self.entryDoor, 1, 7, 0)
        self.generateEntrance(world, &random, chunkBox, .opening, 1, 1, 7)
        let stairs = strongholdDirectionalState("minecraft:cobblestone_stairs", facing: .south)
        let brick = Blocks.stoneBricksState
        for step in 0..<6 {
            let offset = Int32(step)
            self.placeStrongholdBlock(world, stairs, 1, 6 - offset, 1 + offset, chunkBox)
            self.placeStrongholdBlock(world, stairs, 2, 6 - offset, 1 + offset, chunkBox)
            self.placeStrongholdBlock(world, stairs, 3, 6 - offset, 1 + offset, chunkBox)
            if step < 5 {
                self.placeStrongholdBlock(world, brick, 1, 5 - offset, 1 + offset, chunkBox)
                self.placeStrongholdBlock(world, brick, 2, 5 - offset, 1 + offset, chunkBox)
                self.placeStrongholdBlock(world, brick, 3, 5 - offset, 1 + offset, chunkBox)
            }
        }
    }

    static func create<R: Random>(
        state: StrongholdLayoutState,
        random: inout R,
        x: Int32,
        y: Int32,
        z: Int32,
        orientation: CardinalDirection,
        chainLength: Int
    ) -> StrongholdStairs? {
        let box = rotatedStrongholdBox(x: x, y: y, z: z, offsetX: -1, offsetY: -7, offsetZ: 0, width: 5, height: 11, depth: 8, orientation: orientation)
        guard Self.isInBounds(box), state.intersecting(box) == nil else { return nil }
        return StrongholdStairs(chainLength: chainLength, random: &random, boundingBox: box, orientation: orientation)
    }
}

private final class StrongholdStart: StrongholdSpiralStaircase {
    var lastPieceKind: StrongholdPieceKind?
    var portalRoom: StrongholdPortalRoom?

    init<R: Random>(random: inout R, worldX: Int32, worldZ: Int32) {
        let orientation = HorizontalDirection.random(using: &random).publicValue
        super.init(worldX: worldX, worldZ: worldZ, orientation: orientation)
    }
}

private func strongholdPieceGenerator<R: Random>(
    start: StrongholdStart,
    state: StrongholdLayoutState,
    random: inout R,
    x: Int32,
    y: Int32,
    z: Int32,
    orientation: CardinalDirection,
    chainLength: Int
) -> StrongholdPiece? {
    guard chainLength <= 50 else { return nil }
    guard abs(x - start.boundingBox.minX) <= 112, abs(z - start.boundingBox.minZ) <= 112 else {
        return nil
    }

    guard let piece = pickStrongholdPiece(
        start: start,
        state: state,
        random: &random,
        x: x,
        y: y,
        z: z,
        orientation: orientation,
        chainLength: chainLength + 1
    ) else {
        return nil
    }
    state.add(piece)
    return piece
}

private func pickStrongholdPiece<R: Random>(
    start: StrongholdStart,
    state: StrongholdLayoutState,
    random: inout R,
    x: Int32,
    y: Int32,
    z: Int32,
    orientation: CardinalDirection,
    chainLength: Int
) -> StrongholdPiece? {
    guard state.hasRemainingPieces() else {
        return nil
    }

    if let activePieceKind = state.activePieceKind {
        state.activePieceKind = nil
        if let piece = createStrongholdPiece(
            kind: activePieceKind,
            state: state,
            random: &random,
            x: x,
            y: y,
            z: z,
            orientation: orientation,
            chainLength: chainLength
        ) {
            return piece
        }
    }

    for _ in 0..<5 {
        var selectedWeight = Int(random.next(bound: UInt32(state.totalWeight)))
        for entry in state.pieceData {
            selectedWeight -= entry.weight
            guard selectedWeight < 0 else { continue }
            guard entry.canGenerate(chainLength: chainLength) else { break }
            guard entry.kind != start.lastPieceKind else { break }
            guard let piece = createStrongholdPiece(
                kind: entry.kind,
                state: state,
                random: &random,
                x: x,
                y: y,
                z: z,
                orientation: orientation,
                chainLength: chainLength
            ) else {
                continue
            }
            state.recordGenerated(entry.kind)
            return piece
        }
    }

    guard let box = StrongholdSmallCorridor.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation), box.minY > 1 else {
        return nil
    }
    return StrongholdSmallCorridor(chainLength: chainLength, boundingBox: box, orientation: orientation)
}

private func createStrongholdPiece<R: Random>(
    kind: StrongholdPieceKind,
    state: StrongholdLayoutState,
    random: inout R,
    x: Int32,
    y: Int32,
    z: Int32,
    orientation: CardinalDirection,
    chainLength: Int
) -> StrongholdPiece? {
    switch kind {
    case .corridor:
        return StrongholdCorridor.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .prisonHall:
        return StrongholdPrisonHall.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .leftTurn:
        return StrongholdLeftTurn.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .rightTurn:
        return StrongholdRightTurn.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .squareRoom:
        return StrongholdSquareRoom.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .stairs:
        return StrongholdStairs.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .spiralStaircase:
        return StrongholdSpiralStaircase.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .fiveWayCrossing:
        return StrongholdFiveWayCrossing.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .chestCorridor:
        return StrongholdChestCorridor.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .library:
        return StrongholdLibrary.create(state: state, random: &random, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    case .portalRoom:
        return StrongholdPortalRoom.create(state: state, x: x, y: y, z: z, orientation: orientation, chainLength: chainLength)
    }
}

private func rotatedStrongholdBox(
    x: Int32,
    y: Int32,
    z: Int32,
    offsetX: Int32,
    offsetY: Int32,
    offsetZ: Int32,
    width: Int32,
    height: Int32,
    depth: Int32,
    orientation: CardinalDirection
) -> BoundingBox {
    let minY = y + offsetY
    let maxY = minY + height - 1
    switch orientation {
    case .north:
        let minX = x + offsetX
        let maxX = minX + width - 1
        let maxZ = z + offsetZ
        return BoundingBox(minX: minX, minY: minY, minZ: maxZ - depth + 1, maxX: maxX, maxY: maxY, maxZ: maxZ)
    case .east:
        let minX = x + offsetZ
        let minZ = z + offsetX
        return BoundingBox(minX: minX, minY: minY, minZ: minZ, maxX: minX + depth - 1, maxY: maxY, maxZ: minZ + width - 1)
    case .south:
        let minX = x + offsetX
        let minZ = z + offsetZ
        return BoundingBox(minX: minX, minY: minY, minZ: minZ, maxX: minX + width - 1, maxY: maxY, maxZ: minZ + depth - 1)
    case .west:
        let maxX = x + offsetZ
        let minZ = z + offsetX
        return BoundingBox(minX: maxX - depth + 1, minY: minY, minZ: minZ, maxX: maxX, maxY: maxY, maxZ: minZ + width - 1)
    }
}

private func startStrongholdBox(
    x: Int32,
    y: Int32,
    z: Int32,
    orientation: CardinalDirection,
    width: Int32,
    height: Int32,
    depth: Int32
) -> BoundingBox {
    switch orientation {
    case .north, .south:
        return BoundingBox(
            minX: x,
            minY: y,
            minZ: z,
            maxX: x + width - 1,
            maxY: y + height - 1,
            maxZ: z + depth - 1
        )
    case .west, .east:
        return BoundingBox(
            minX: x,
            minY: y,
            minZ: z,
            maxX: x + depth - 1,
            maxY: y + height - 1,
            maxZ: z + width - 1
        )
    }
}

private func shiftPiecesIntoWorld<R: Random>(
    _ pieces: [StrongholdPiece],
    seaLevel: Int32,
    minimumWorldY: Int32,
    random: inout R,
    offset: Int32
) {
    guard let first = pieces.first else { return }
    var minY = first.boundingBox.minY
    var maxY = first.boundingBox.maxY
    for piece in pieces.dropFirst() {
        minY = min(minY, piece.boundingBox.minY)
        maxY = max(maxY, piece.boundingBox.maxY)
    }

    let height = maxY - minY + 1
    let maxAllowedY = seaLevel - offset
    var targetMaxY = height + minimumWorldY + 1
    if targetMaxY < maxAllowedY {
        let range = maxAllowedY - targetMaxY
        if range > 0 {
            targetMaxY += Int32(random.next(bound: UInt32(range)))
        }
    }
    let deltaY = targetMaxY - maxY
    for piece in pieces {
        piece.boundingBox.move(0, deltaY, 0)
    }
}

private func strongholdState(_ id: String, _ properties: [String: String] = [:]) -> BlockState {
    if properties.isEmpty {
        return BlockState(type: Block(withID: id))
    }
    return BlockState(type: Block(withID: id), properties: properties)
}

private func strongholdDirectionalState(
    _ id: String,
    facing: CardinalDirection,
    properties: [String: String] = [:]
) -> BlockState {
    var merged = properties
    merged["facing"] = facing.rawValue
    return strongholdState(id, merged)
}

private func withEye(_ state: BlockState, _ hasEye: Bool) -> BlockState {
    var properties = state.properties ?? [:]
    properties["eye"] = hasEye ? "true" : "false"
    return BlockState(type: state.type, properties: properties)
}

private func cardinalDirection(from value: String) -> CardinalDirection? {
    switch value {
    case "north": return .north
    case "east": return .east
    case "south": return .south
    case "west": return .west
    default: return nil
    }
}
