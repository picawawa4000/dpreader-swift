/// Vanilla abandoned-mineshaft piece selection and loot generation.
public struct MineshaftGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

public enum MineshaftPieceKind: String {
    case room, corridor, crossing, stairs
}

public final class MineshaftPiece: StructurePiece {
    public let kind: MineshaftPieceKind
    public let chainLength: Int
    public let mineshaftType: MineshaftType
    public let corridorSections: Int
    public let hasRails: Bool
    public let hasCobwebs: Bool

    fileprivate var entrances: [BoundingBox] = []
    fileprivate var generatedLoot: [StructureLootContainer] = []

    fileprivate init(
        kind: MineshaftPieceKind,
        chainLength: Int,
        type: MineshaftType,
        box: BoundingBox,
        orientation: HorizontalDirection = .south,
        corridorSections: Int = 0,
        hasRails: Bool = false,
        hasCobwebs: Bool = false
    ) {
        self.kind = kind
        self.chainLength = chainLength
        self.mineshaftType = type
        self.corridorSections = corridorSections
        self.hasRails = hasRails
        self.hasCobwebs = hasCobwebs
        super.init(orientation: orientation.publicValue, boundingBox: box)
    }

    fileprivate func translate(y: Int32) {
        self.boundingBox.move(0, y, 0)
        for index in self.entrances.indices { self.entrances[index].move(0, y, 0) }
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        guard !self.touchesLiquid(in: world, chunkBox: chunkBox) else { return }
        switch self.kind {
        case .corridor:
            self.generateCorridor(in: world, chunkBox: chunkBox, random: &random)
        case .stairs:
            self.generateStairs(in: world, chunkBox: chunkBox)
        case .room, .crossing:
            // Rooms and crossings are intentionally represented as excavated volumes. This is
            // sufficient for their interaction with later corridor pieces and mirrors their
            // principal world-generation effect.
            self.excavate(in: world, chunkBox: chunkBox)
        }
    }

    /// Vanilla rejects the intersecting chunk-slice of a piece when water or lava touches its
    /// one-block-expanded shell. This commonly removes corridors that run into aquifers.
    private func touchesLiquid(in world: StructureWorldView, chunkBox: BoundingBox) -> Bool {
        let minX = max(self.boundingBox.minX - 1, chunkBox.minX)
        let minY = max(self.boundingBox.minY - 1, chunkBox.minY)
        let minZ = max(self.boundingBox.minZ - 1, chunkBox.minZ)
        let maxX = min(self.boundingBox.maxX + 1, chunkBox.maxX)
        let maxY = min(self.boundingBox.maxY + 1, chunkBox.maxY)
        let maxZ = min(self.boundingBox.maxZ + 1, chunkBox.maxZ)
        guard minX <= maxX, minY <= maxY, minZ <= maxZ else { return false }
        func liquid(_ x: Int32, _ y: Int32, _ z: Int32) -> Bool {
            let id = world.block(at: PosInt3D(x: x, y: y, z: z)).id
            return id == "minecraft:water" || id == "minecraft:lava"
        }
        for x in minX...maxX {
            for z in minZ...maxZ where liquid(x, minY, z) || liquid(x, maxY, z) { return true }
        }
        for x in minX...maxX {
            for y in minY...maxY where liquid(x, y, minZ) || liquid(x, y, maxZ) { return true }
        }
        for z in minZ...maxZ {
            for y in minY...maxY where liquid(minX, y, z) || liquid(maxX, y, z) { return true }
        }
        return false
    }

    private func excavate(in world: StructureWorldView, chunkBox: BoundingBox) {
        let low = self.kind == .room ? min(self.boundingBox.minY + 1, self.boundingBox.maxY) : self.boundingBox.minY
        let high = self.kind == .room ? min(self.boundingBox.minY + 3, self.boundingBox.maxY) : self.boundingBox.maxY
        guard low <= high else { return }
        for y in low...high {
            for x in self.boundingBox.minX...self.boundingBox.maxX {
                for z in self.boundingBox.minZ...self.boundingBox.maxZ where chunkBox.contains(PosInt3D(x: x, y: y, z: z)) {
                    world.setBlock(Blocks.caveAirState, at: PosInt3D(x: x, y: y, z: z))
                }
            }
        }
    }

    private func generateStairs(in world: StructureWorldView, chunkBox: BoundingBox) {
        // The five descending slices in MineshaftGenerator.MineshaftStairs.
        for step in 0..<5 {
            let z = Int32(2 + step)
            let minY = Int32(5 - step - (step < 4 ? 1 : 0))
            let maxY = Int32(7 - step)
            for y in minY...maxY {
                for x: Int32 in 0...2 {
                    let pos = self.getWorldPos(x, y, z)
                    if chunkBox.contains(pos) { world.setBlock(Blocks.caveAirState, at: pos) }
                }
            }
        }
    }

    private func generateCorridor<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let end = Int32(self.corridorSections * 5 - 1)
        guard end >= 0 else { return }

        // Carve the lower two layers before chest-minecart placement. Vanilla's upper-layer
        // integrity processor consumes one float for each position, even outside this chunk.
        for z in 0...end {
            for y: Int32 in 0...1 {
                for x: Int32 in 0...2 {
                    let pos = self.getWorldPos(x, y, z)
                    if chunkBox.contains(pos) { world.setBlock(Blocks.caveAirState, at: pos) }
                }
            }
        }
        for _: Int32 in 0...end { for _: Int32 in 0...2 { _ = random.nextFloat() } }
        if self.hasCobwebs {
            for _: Int32 in 0...end { for _: Int32 in 0...2 { for _: Int32 in 0...1 { _ = random.nextFloat() } } }
        }

        let planks = BlockState(id: self.mineshaftType == .mesa ? "minecraft:dark_oak_planks" : "minecraft:oak_planks")
        for section in 0..<self.corridorSections {
            let supportZ = Int32(2 + section * 5)
            // Supports consume either one or three calls when there is a solid ceiling.
            let ceilingIsSolid = (0...2).allSatisfy {
                let pos = self.getWorldPos(Int32($0), 3, supportZ)
                return chunkBox.contains(pos) && !world.block(at: pos).isAir
            }
            if ceilingIsSolid {
                if random.next(bound: 4) != 0 { _ = random.nextFloat(); _ = random.nextFloat() }
            }

            // Each cobweb attempt consumes a float only when its heightmap check is in this chunk.
            let webOffsets: [(Int32, Float)] = [(-1, 0.1), (-1, 0.1), (1, 0.1), (1, 0.1), (-2, 0.05), (-2, 0.05), (2, 0.05), (2, 0.05)]
            for (index, entry) in webOffsets.enumerated() {
                let x: Int32 = index % 2 == 0 ? 0 : 2
                let pos = self.getWorldPos(x, 2, supportZ + entry.0)
                if chunkBox.contains(pos) { _ = random.nextFloat() }
            }

            if random.next(bound: 100) == 0 {
                self.addMinecart(x: 2, z: supportZ - 1, in: world, chunkBox: chunkBox, random: &random)
            }
            if random.next(bound: 100) == 0 {
                self.addMinecart(x: 0, z: supportZ + 1, in: world, chunkBox: chunkBox, random: &random)
            }
            if self.hasCobwebs { _ = random.next(bound: 3) }
        }

        // Floors are significant for a later piece's minecart precondition.
        for z in 0...end {
            for x: Int32 in 0...2 {
                let pos = self.getWorldPos(x, -1, z)
                if chunkBox.contains(pos), world.block(at: pos).isAir { world.setBlock(planks, at: pos) }
            }
        }
        if self.hasRails {
            for z in 0...end {
                let floor = self.getWorldPos(1, -1, z)
                if chunkBox.contains(floor), !world.block(at: floor).isAir { _ = random.nextFloat() }
            }
        }
    }

    private func addMinecart<R: Random>(x: Int32, z: Int32, in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        let pos = self.getWorldPos(x, 0, z)
        let below = PosInt3D(x: pos.x, y: pos.y - 1, z: pos.z)
        guard chunkBox.contains(pos), world.block(at: pos).isAir, !world.block(at: below).isAir else { return }
        _ = random.nextBoolean() // rail orientation
        let seed = Int64(bitPattern: random.nextLong())
        world.setBlock(BlockState(id: "minecraft:rail"), at: pos)
        self.generatedLoot.append(StructureLootContainer(
            block: "minecraft:chest_minecart", pos: pos,
            lootTable: "minecraft:chests/abandoned_mineshaft", lootSeed: seed
        ))
    }
}

public enum Mineshaft {
    public static func generatePieceGraph(
        type: MineshaftType, worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext
    ) -> PieceGraph {
        var builder = MineshaftBuilder(type: type, worldSeed: worldSeed, startChunk: startChunk, context: context)
        return builder.generate()
    }

    public static func generate(
        type: MineshaftType, worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext
    ) -> MineshaftGenerationResult {
        let graph = self.generatePieceGraph(type: type, worldSeed: worldSeed, startChunk: startChunk, context: context)
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let id = type == .mesa ? "minecraft:mineshaft_mesa" : "minecraft:mineshaft"
        let decoration = context.structureDecorationParameters(forStructureID: id)
            ?? StructureDecorationParameters(step: StructureGenerationStep.undergroundStructures.rawIndex, index: 0)
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let box = BoundingBox(
                    minX: chunkX << 4, minY: context.minimumWorldY, minZ: chunkZ << 4,
                    maxX: (chunkX << 4) + 15, maxY: context.maximumWorldY, maxZ: (chunkZ << 4) + 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: decoration.index, decoratorStep: decoration.step
                )
                for piece in graph.pieces where piece.boundingBox.intersects(box) {
                    piece.write(in: world, chunkBox: box, random: &random)
                }
            }
        }
        let loot = graph.pieces.compactMap { $0 as? MineshaftPiece }.flatMap(\.generatedLoot)
        return MineshaftGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    public static func generateLoot(
        type: MineshaftType, worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext
    ) -> [StructureLootContainer] {
        self.generate(type: type, worldSeed: worldSeed, startChunk: startChunk, context: context).lootContainers
    }
}

private struct MineshaftBuilder {
    let type: MineshaftType
    let startChunk: PosInt2D
    let context: StructureGenerationContext
    var random: CheckedRandom
    var pieces: [MineshaftPiece] = []
    var root: MineshaftPiece!

    init(type: MineshaftType, worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) {
        self.type = type
        self.startChunk = startChunk
        self.context = context
        self.random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
    }

    mutating func generate() -> PieceGraph {
        _ = self.random.nextDouble()
        let x = self.startChunk.x << 4 + 2
        let z = self.startChunk.z << 4 + 2
        let box = BoundingBox(
            minX: x, minY: 50, minZ: z,
            maxX: x + 7 + Int32(self.random.next(bound: 6)),
            maxY: 54 + Int32(self.random.next(bound: 6)),
            maxZ: z + 7 + Int32(self.random.next(bound: 6))
        )
        let room = MineshaftPiece(kind: .room, chainLength: 0, type: self.type, box: box)
        self.root = room
        self.pieces.append(room)
        self.fillRoomOpenings(room)

        var bounds = self.combinedBounds()
        let shift: Int32
        if self.type == .normal {
            let ceiling = self.context.seaLevel - 10
            var target = (bounds.maxY - bounds.minY + 1) + self.context.minimumWorldY + 1
            if target < ceiling { target += Int32(self.random.next(bound: UInt32(ceiling - target))) }
            shift = target - bounds.maxY
        } else {
            let centerX = (bounds.minX + bounds.maxX + 1) / 2
            let centerZ = (bounds.minZ + bounds.maxZ + 1) / 2
            let surface = surfaceY(atX: centerX, z: centerZ, context: self.context) ?? self.context.seaLevel
            let target = surface <= self.context.seaLevel
                ? self.context.seaLevel
                : self.context.seaLevel + Int32(self.random.next(bound: UInt32(surface - self.context.seaLevel + 1)))
            shift = target - ((bounds.minY + bounds.maxY + 1) / 2)
        }
        for piece in self.pieces { piece.translate(y: shift) }
        bounds.move(0, shift, 0)
        return PieceGraph(startChunk: self.startChunk, orientation: .south, boundingBox: bounds, pieces: self.pieces)
    }

    private func combinedBounds() -> BoundingBox {
        self.pieces.dropFirst().reduce(self.pieces[0].boundingBox) { $0.union($1.boundingBox) }
    }

    private func intersects(_ box: BoundingBox) -> Bool { self.pieces.contains { $0.boundingBox.intersects(box) } }

    mutating private func pickPiece(x: Int32, y: Int32, z: Int32, direction: HorizontalDirection, chain: Int) -> MineshaftPiece? {
        guard chain <= 8, abs(x - self.root.boundingBox.minX) <= 80, abs(z - self.root.boundingBox.minZ) <= 80 else { return nil }
        let nextChain = chain + 1
        let roll = self.random.next(bound: 100)
        let piece: MineshaftPiece?
        if roll >= 80 { piece = self.makeCrossing(x: x, y: y, z: z, direction: direction, chain: nextChain) }
        else if roll >= 70 { piece = self.makeStairs(x: x, y: y, z: z, direction: direction, chain: nextChain) }
        else { piece = self.makeCorridor(x: x, y: y, z: z, direction: direction, chain: nextChain) }
        guard let piece else { return nil }
        self.pieces.append(piece)
        self.fillOpenings(piece)
        return piece
    }

    mutating private func makeCorridor(x: Int32, y: Int32, z: Int32, direction: HorizontalDirection, chain: Int) -> MineshaftPiece? {
        for sections in stride(from: Int(self.random.next(bound: 3)) + 2, through: 1, by: -1) {
            let box = makeBoundingBox(x: x, y: y, z: z, orientation: direction, width: 3, height: 3, depth: Int32(sections * 5))
            if !self.intersects(box) {
                let rails = self.random.next(bound: 3) == 0
                let webs = !rails && self.random.next(bound: 23) == 0
                return MineshaftPiece(kind: .corridor, chainLength: chain, type: self.type, box: box, orientation: direction, corridorSections: sections, hasRails: rails, hasCobwebs: webs)
            }
        }
        return nil
    }

    private func stairsBox(x: Int32, y: Int32, z: Int32, direction: HorizontalDirection) -> BoundingBox {
        switch direction {
        case .north: return BoundingBox(minX: x, minY: y-5, minZ: z-8, maxX: x+2, maxY: y+2, maxZ: z)
        case .south: return BoundingBox(minX: x, minY: y-5, minZ: z, maxX: x+2, maxY: y+2, maxZ: z+8)
        case .west: return BoundingBox(minX: x-8, minY: y-5, minZ: z, maxX: x, maxY: y+2, maxZ: z+2)
        case .east: return BoundingBox(minX: x, minY: y-5, minZ: z, maxX: x+8, maxY: y+2, maxZ: z+2)
        }
    }

    mutating private func makeStairs(x: Int32, y: Int32, z: Int32, direction: HorizontalDirection, chain: Int) -> MineshaftPiece? {
        let box = self.stairsBox(x: x, y: y, z: z, direction: direction)
        return self.intersects(box) ? nil : MineshaftPiece(kind: .stairs, chainLength: chain, type: self.type, box: box, orientation: direction)
    }

    mutating private func makeCrossing(x: Int32, y: Int32, z: Int32, direction: HorizontalDirection, chain: Int) -> MineshaftPiece? {
        let height: Int32 = self.random.next(bound: 4) == 0 ? 6 : 2
        let box: BoundingBox
        switch direction {
        case .north: box = BoundingBox(minX: x-1, minY: y, minZ: z-4, maxX: x+3, maxY: y+height, maxZ: z)
        case .south: box = BoundingBox(minX: x-1, minY: y, minZ: z, maxX: x+3, maxY: y+height, maxZ: z+4)
        case .west: box = BoundingBox(minX: x-4, minY: y, minZ: z-1, maxX: x, maxY: y+height, maxZ: z+3)
        case .east: box = BoundingBox(minX: x, minY: y, minZ: z-1, maxX: x+4, maxY: y+height, maxZ: z+3)
        }
        return self.intersects(box) ? nil : MineshaftPiece(kind: .crossing, chainLength: chain, type: self.type, box: box, orientation: direction)
    }

    mutating private func fillOpenings(_ piece: MineshaftPiece) {
        switch piece.kind {
        case .corridor: self.fillCorridorOpenings(piece)
        case .crossing: self.fillCrossingOpenings(piece)
        case .stairs: self.fillStairsOpenings(piece)
        case .room: self.fillRoomOpenings(piece)
        }
    }

    mutating private func fillCorridorOpenings(_ p: MineshaftPiece) {
        let b = p.boundingBox; let i = p.chainLength; let j = self.random.next(bound: 4); let d = HorizontalDirection(from: p.orientation)
        switch d {
        case .north:
            if j <= 1 { _ = self.pickPiece(x:b.minX,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ-1,direction:.north,chain:i) }
            else if j == 2 { _ = self.pickPiece(x:b.minX-1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ,direction:.west,chain:i) }
            else { _ = self.pickPiece(x:b.maxX+1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ,direction:.east,chain:i) }
        case .south:
            if j <= 1 { _ = self.pickPiece(x:b.minX,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.maxZ+1,direction:.south,chain:i) }
            else if j == 2 { _ = self.pickPiece(x:b.minX-1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.maxZ-3,direction:.west,chain:i) }
            else { _ = self.pickPiece(x:b.maxX+1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.maxZ-3,direction:.east,chain:i) }
        case .west:
            if j <= 1 { _ = self.pickPiece(x:b.minX-1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ,direction:.west,chain:i) }
            else if j == 2 { _ = self.pickPiece(x:b.minX,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ-1,direction:.north,chain:i) }
            else { _ = self.pickPiece(x:b.minX,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.maxZ+1,direction:.south,chain:i) }
        case .east:
            if j <= 1 { _ = self.pickPiece(x:b.maxX+1,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ,direction:.east,chain:i) }
            else if j == 2 { _ = self.pickPiece(x:b.maxX-3,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.minZ-1,direction:.north,chain:i) }
            else { _ = self.pickPiece(x:b.maxX-3,y:b.minY-1+Int32(self.random.next(bound:3)),z:b.maxZ+1,direction:.south,chain:i) }
        }
        guard i < 8 else { return }
        if d == .north || d == .south {
            var z = b.minZ + 3; while z + 3 <= b.maxZ { let r=self.random.next(bound:5); if r==0 {_=self.pickPiece(x:b.minX-1,y:b.minY,z:z,direction:.west,chain:i+1)} else if r==1 {_=self.pickPiece(x:b.maxX+1,y:b.minY,z:z,direction:.east,chain:i+1)}; z += 5 }
        } else {
            var x = b.minX + 3; while x + 3 <= b.maxX { let r=self.random.next(bound:5); if r==0 {_=self.pickPiece(x:x,y:b.minY,z:b.minZ-1,direction:.north,chain:i+1)} else if r==1 {_=self.pickPiece(x:x,y:b.minY,z:b.maxZ+1,direction:.south,chain:i+1)}; x += 5 }
        }
    }

    mutating private func fillStairsOpenings(_ p: MineshaftPiece) {
        let b=p.boundingBox; let i=p.chainLength
        switch HorizontalDirection(from:p.orientation) {
        case .north: _=self.pickPiece(x:b.minX,y:b.minY,z:b.minZ-1,direction:.north,chain:i)
        case .south: _=self.pickPiece(x:b.minX,y:b.minY,z:b.maxZ+1,direction:.south,chain:i)
        case .west: _=self.pickPiece(x:b.minX-1,y:b.minY,z:b.minZ,direction:.west,chain:i)
        case .east: _=self.pickPiece(x:b.maxX+1,y:b.minY,z:b.minZ,direction:.east,chain:i)
        }
    }

    mutating private func fillCrossingOpenings(_ p: MineshaftPiece) {
        let b=p.boundingBox; let i=p.chainLength; let d=HorizontalDirection(from:p.orientation)
        func endpoint(_ d: HorizontalDirection) -> (Int32,Int32,Int32) { switch d { case .north:return(b.minX+1,b.minY,b.minZ-1); case .south:return(b.minX+1,b.minY,b.maxZ+1); case .west:return(b.minX-1,b.minY,b.minZ+1); case .east:return(b.maxX+1,b.minY,b.minZ+1) } }
        let branches: [HorizontalDirection] = d == .north ? [.north,.west,.east] : d == .south ? [.south,.west,.east] : d == .west ? [.north,.south,.west] : [.north,.south,.east]
        for branch in branches { let e=endpoint(branch); _=self.pickPiece(x:e.0,y:e.1,z:e.2,direction:branch,chain:i) }
        if b.maxY-b.minY+1 > 3 {
            for branch in [HorizontalDirection.north,.west,.east,.south] where self.random.nextBoolean() { let e=endpoint(branch); _=self.pickPiece(x:e.0,y:e.1+4,z:e.2,direction:branch,chain:i) }
        }
    }

    mutating private func fillRoomOpenings(_ p: MineshaftPiece) {
        let b=p.boundingBox; let vertical=max(1,b.maxY-b.minY-3)
        func add(_ direction: HorizontalDirection, _ x:Int32,_ z:Int32) { _=self.pickPiece(x:x,y:b.minY+Int32(self.random.next(bound:UInt32(vertical)))+1,z:z,direction:direction,chain:p.chainLength) }
        var k:Int32=0
        while k < b.maxX-b.minX+1 { k += Int32(self.random.next(bound:UInt32(b.maxX-b.minX+1))); if k+3 > b.maxX-b.minX+1 {break}; add(.north,b.minX+k,b.minZ-1); k += 4 }
        k=0; while k < b.maxX-b.minX+1 { k += Int32(self.random.next(bound:UInt32(b.maxX-b.minX+1))); if k+3 > b.maxX-b.minX+1 {break}; add(.south,b.minX+k,b.maxZ+1); k += 4 }
        k=0; while k < b.maxZ-b.minZ+1 { k += Int32(self.random.next(bound:UInt32(b.maxZ-b.minZ+1))); if k+3 > b.maxZ-b.minZ+1 {break}; add(.west,b.minX-1,b.minZ+k); k += 4 }
        k=0; while k < b.maxZ-b.minZ+1 { k += Int32(self.random.next(bound:UInt32(b.maxZ-b.minZ+1))); if k+3 > b.maxZ-b.minZ+1 {break}; add(.east,b.maxX+1,b.minZ+k); k += 4 }
    }
}

private extension HorizontalDirection {
    init(from direction: CardinalDirection) {
        switch direction { case .north:self = .north; case .south:self = .south; case .west:self = .west; case .east:self = .east }
    }
}
