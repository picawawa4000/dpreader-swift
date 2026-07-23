/// Shared code for structure generation.

/// Samples the existing world state for structure generation.
///
/// Desert pyramids only need `seaLevel`, `minimumWorldY`, and `blockSampler`.
/// Ocean monuments only need `seaLevel`, `minimumWorldY`, and `blockSampler`.
///
/// Everything else is generated directly from the structure seed and the start chunk.
public struct StructureGenerationContext {
    public let seaLevel: Int32
    public let minimumWorldY: Int32
    public let blockSampler: (PosInt3D) -> BlockState

    public init(
        seaLevel: Int32,
        minimumWorldY: Int32,
        blockSampler: @escaping (PosInt3D) -> BlockState = { _ in BlockState(type: Block(withID: "minecraft:air")) }
    ) {
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.blockSampler = blockSampler
    }
}

/// Blocks.
public enum Blocks {
    static let air = Block(withID: "minecraft:air")
    static let water = Block(withID: "minecraft:water")
    static let prismarine = Block(withID: "minecraft:prismarine")
    static let prismarineBricks = Block(withID: "minecraft:prismarine_bricks")
    static let darkPrismarine = Block(withID: "minecraft:dark_prismarine")
    static let seaLantern = Block(withID: "minecraft:sea_lantern")
    static let ice = Block(withID: "minecraft:ice")
    static let packedIce = Block(withID: "minecraft:packed_ice")
    static let blueIce = Block(withID: "minecraft:blue_ice")
    static let goldBlock = Block(withID: "minecraft:gold_block")
    static let wetSponge = Block(withID: "minecraft:wet_sponge")
    static let kelp = Block(withID: "minecraft:kelp")
    static let kelpPlant = Block(withID: "minecraft:kelp_plant")
    static let seagrass = Block(withID: "minecraft:seagrass")
    static let tallSeagrass = Block(withID: "minecraft:tall_seagrass")

    static let airState = BlockState(type: air)
    static let waterState = BlockState(type: water)
    static let prismarineState = BlockState(type: prismarine)
    static let prismarineBricksState = BlockState(type: prismarineBricks)
    static let darkPrismarineState = BlockState(type: darkPrismarine)
    static let seaLanternState = BlockState(type: seaLantern)
    static let goldBlockState = BlockState(type: goldBlock)
    static let wetSpongeState = BlockState(type: wetSponge)
}

/// A cardinal direction in world space.
public enum CardinalDirection: String {
    case north
    case east
    case south
    case west
}

/// A local direction.
/// TODO: merge `CardinalDirection`, `LocalDirection`, and `HorizontalDirection`.
public enum LocalDirection: Int, CaseIterable {
    case down = 0
    case up = 1
    case north = 2
    case south = 3
    case west = 4
    case east = 5

    var opposite: LocalDirection {
        switch self {
        case .down: return .up
        case .up: return .down
        case .north: return .south
        case .south: return .north
        case .west: return .east
        case .east: return .west
        }
    }

    var stepX: Int32 {
        switch self {
        case .west: return -1
        case .east: return 1
        default: return 0
        }
    }

    var stepY: Int32 {
        switch self {
        case .down: return -1
        case .up: return 1
        default: return 0
        }
    }

    var stepZ: Int32 {
        switch self {
        case .north: return -1
        case .south: return 1
        default: return 0
        }
    }
}

enum HorizontalDirection: CaseIterable {
    case north
    case east
    case south
    case west

    var publicValue: CardinalDirection {
        switch self {
        case .north: return .north
        case .east: return .east
        case .south: return .south
        case .west: return .west
        }
    }

    static func random<R: Random>(using random: inout R) -> HorizontalDirection {
        switch Int(random.next(bound: 4)) {
        case 0: return .north
        case 1: return .east
        case 2: return .south
        default: return .west
        }
    }
}

/// A public bounding box type.
public struct BoundingBox: Equatable {
    public var minX: Int32
    public var minY: Int32
    public var minZ: Int32
    public var maxX: Int32
    public var maxY: Int32
    public var maxZ: Int32

    public init(minX: Int32, minY: Int32, minZ: Int32, maxX: Int32, maxY: Int32, maxZ: Int32) {
        self.minX = minX
        self.minY = minY
        self.minZ = minZ
        self.maxX = maxX
        self.maxY = maxY
        self.maxZ = maxZ
    }

    public func contains(_ pos: PosInt3D) -> Bool {
        pos.x >= self.minX && pos.x <= self.maxX
            && pos.y >= self.minY && pos.y <= self.maxY
            && pos.z >= self.minZ && pos.z <= self.maxZ
    }

    mutating func move(_ dx: Int32, _ dy: Int32, _ dz: Int32) {
        self.minX += dx
        self.maxX += dx
        self.minY += dy
        self.maxY += dy
        self.minZ += dz
        self.maxZ += dz
    }

    func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(
            minX: min(self.minX, other.minX),
            minY: min(self.minY, other.minY),
            minZ: min(self.minZ, other.minZ),
            maxX: max(self.maxX, other.maxX),
            maxY: max(self.maxY, other.maxY),
            maxZ: max(self.maxZ, other.maxZ)
        )
    }

    func intersects(_ other: BoundingBox) -> Bool {
        self.maxX >= other.minX
            && self.minX <= other.maxX
            && self.maxY >= other.minY
            && self.minY <= other.maxY
            && self.maxZ >= other.minZ
            && self.minZ <= other.maxZ
    }

    func intersects(minX: Int32, minZ: Int32, maxX: Int32, maxZ: Int32) -> Bool {
        self.maxX >= minX
            && self.minX <= maxX
            && self.maxZ >= minZ
            && self.minZ <= maxZ
    }

    static func fromCorners(_ a: PosInt3D, _ b: PosInt3D) -> BoundingBox {
        BoundingBox(
            minX: min(a.x, b.x),
            minY: min(a.y, b.y),
            minZ: min(a.z, b.z),
            maxX: max(a.x, b.x),
            maxY: max(a.y, b.y),
            maxZ: max(a.z, b.z)
        )
    }
}

public struct PieceGraph<Kind> {
    public let startChunk: PosInt2D
    public let orientation: CardinalDirection
    public let boundingBox: BoundingBox
    public let pieces: [StructurePiece<Kind>]
}

private struct LocalStructurePosition {
    let x: Int32
    let y: Int32
    let z: Int32
}

private struct LocalStructureBox {
    let minX: Int32
    let minY: Int32
    let minZ: Int32
    let maxX: Int32
    let maxY: Int32
    let maxZ: Int32
}

private enum StructurePieceOperation {
    case block(LocalStructurePosition, BlockState)
    case box(LocalStructureBox, boundary: BlockState, interior: BlockState)
    case waterBox(LocalStructureBox)
    case boxOnFillOnly(LocalStructureBox, state: BlockState)
    case fillColumnDown(LocalStructurePosition, state: BlockState)
    case spawnElder(LocalStructurePosition)
}

private struct StructurePieceContents {
    let operations: [StructurePieceOperation]

    func write<Kind>(piece: StructurePiece<Kind>, into world: StructureWorldView, chunkBox: BoundingBox) {
        for operation in self.operations {
            switch operation {
            case .block(let pos, let state):
                piece.applyBlock(world, state, pos.x, pos.y, pos.z, chunkBox)
            case .box(let box, let boundary, let interior):
                piece.applyGenerateBox(
                    world,
                    chunkBox,
                    box.minX,
                    box.minY,
                    box.minZ,
                    box.maxX,
                    box.maxY,
                    box.maxZ,
                    boundary,
                    interior
                )
            case .waterBox(let box):
                piece.applyGenerateWaterBox(
                    world,
                    chunkBox,
                    box.minX,
                    box.minY,
                    box.minZ,
                    box.maxX,
                    box.maxY,
                    box.maxZ
                )
            case .boxOnFillOnly(let box, let state):
                piece.applyGenerateBoxOnFillOnly(
                    world,
                    chunkBox,
                    box.minX,
                    box.minY,
                    box.minZ,
                    box.maxX,
                    box.maxY,
                    box.maxZ,
                    state
                )
            case .fillColumnDown(let pos, let state):
                piece.applyFillColumnDown(world, state, pos.x, pos.y, pos.z, chunkBox)
            case .spawnElder(let pos):
                piece.applySpawnElder(world, chunkBox, pos.x, pos.y, pos.z)
            }
        }
    }
}

private final class StructurePieceContentsRecorder {
    private(set) var operations: [StructurePieceOperation] = []

    func record(_ operation: StructurePieceOperation) {
        self.operations.append(operation)
    }
}

public class StructurePiece<Kind> {
    public let kind: Kind
    public let orientation: CardinalDirection
    public var boundingBox: BoundingBox
    public let roomIndex: Int?
    public let design: Int?

    private var storedContents: StructurePieceContents?
    private var recorder: StructurePieceContentsRecorder?

    init(
        kind: Kind,
        orientation: CardinalDirection,
        boundingBox: BoundingBox,
        roomIndex: Int? = nil,
        design: Int? = nil
    ) {
        self.kind = kind
        self.orientation = orientation
        self.boundingBox = boundingBox
        self.roomIndex = roomIndex
        self.design = design
    }

    class var fillBlock: BlockState { Blocks.waterState }

    class var fillKeep: Set<String> {
        [
            "minecraft:ice",
            "minecraft:packed_ice",
            "minecraft:blue_ice",
            "minecraft:water"
        ]
    }

    func write<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        if let storedContents = self.storedContents {
            storedContents.write(piece: self, into: world, chunkBox: chunkBox)
            return
        }

        let recorder = StructurePieceContentsRecorder()
        self.recorder = recorder
        self.postProcess(in: world, chunkBox: chunkBox, random: &random)
        self.recorder = nil
        self.storedContents = StructurePieceContents(operations: recorder.operations)
    }

    func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
    }

    func getWorldX(_ x: Int32, _ z: Int32) -> Int32 {
        switch self.orientation {
        case .north, .south:
            return self.boundingBox.minX + x
        case .west:
            return self.boundingBox.maxX - z
        case .east:
            return self.boundingBox.minX + z
        }
    }

    func getWorldY(_ y: Int32) -> Int32 {
        self.boundingBox.minY + y
    }

    func getWorldZ(_ x: Int32, _ z: Int32) -> Int32 {
        switch self.orientation {
        case .north:
            return self.boundingBox.maxZ - z
        case .south:
            return self.boundingBox.minZ + z
        case .west, .east:
            return self.boundingBox.minZ + x
        }
    }

    func getWorldPos(_ x: Int32, _ y: Int32, _ z: Int32) -> PosInt3D {
        PosInt3D(x: self.getWorldX(x, z), y: self.getWorldY(y), z: self.getWorldZ(x, z))
    }

    func placeBlock(_ world: StructureWorldView, _ state: BlockState, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: BoundingBox) {
        self.record(.block(LocalStructurePosition(x: x, y: y, z: z), state))
        self.applyBlock(world, state, x, y, z, chunkBox)
    }

    func getBlock(_ world: StructureWorldView, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: BoundingBox) -> BlockState {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else {
            return Blocks.airState
        }
        return world.block(at: pos)
    }

    func generateBox(
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
        self.record(
            .box(
                LocalStructureBox(minX: x0, minY: y0, minZ: z0, maxX: x1, maxY: y1, maxZ: z1),
                boundary: boundary,
                interior: interior
            )
        )
        self.applyGenerateBox(world, chunkBox, x0, y0, z0, x1, y1, z1, boundary, interior)
    }

    func generateWaterBox(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32
    ) {
        self.record(.waterBox(LocalStructureBox(minX: x0, minY: y0, minZ: z0, maxX: x1, maxY: y1, maxZ: z1)))
        self.applyGenerateWaterBox(world, chunkBox, x0, y0, z0, x1, y1, z1)
    }

    func generateBoxOnFillOnly(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        _ state: BlockState
    ) {
        self.record(
            .boxOnFillOnly(
                LocalStructureBox(minX: x0, minY: y0, minZ: z0, maxX: x1, maxY: y1, maxZ: z1),
                state: state
            )
        )
        self.applyGenerateBoxOnFillOnly(world, chunkBox, x0, y0, z0, x1, y1, z1, state)
    }

    func fillColumnDown(_ world: StructureWorldView, _ state: BlockState, _ x: Int32, _ y: Int32, _ z: Int32, _ chunkBox: BoundingBox) {
        self.record(.fillColumnDown(LocalStructurePosition(x: x, y: y, z: z), state: state))
        self.applyFillColumnDown(world, state, x, y, z, chunkBox)
    }

    func chunkIntersects(_ chunkBox: BoundingBox, _ x0: Int32, _ z0: Int32, _ x1: Int32, _ z1: Int32) -> Bool {
        let wx0 = self.getWorldX(x0, z0)
        let wz0 = self.getWorldZ(x0, z0)
        let wx1 = self.getWorldX(x1, z1)
        let wz1 = self.getWorldZ(x1, z1)
        return chunkBox.intersects(minX: min(wx0, wx1), minZ: min(wz0, wz1), maxX: max(wx0, wx1), maxZ: max(wz0, wz1))
    }

    func spawnElder(_ world: StructureWorldView, _ chunkBox: BoundingBox, _ x: Int32, _ y: Int32, _ z: Int32) {
        self.record(.spawnElder(LocalStructurePosition(x: x, y: y, z: z)))
        self.applySpawnElder(world, chunkBox, x, y, z)
    }

    fileprivate func applyBlock(
        _ world: StructureWorldView,
        _ state: BlockState,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32,
        _ chunkBox: BoundingBox
    ) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        world.setBlock(state, at: pos)
    }

    fileprivate func applyGenerateBox(
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
                    let block = (x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1) ? boundary : interior
                    self.applyBlock(world, block, x, y, z, chunkBox)
                }
            }
        }
    }

    fileprivate func applyGenerateWaterBox(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    let block = self.getBlock(world, x, y, z, chunkBox)
                    if !Self.fillKeep.contains(block.type.id) {
                        if self.getWorldY(y) >= world.seaLevel && block != Self.fillBlock {
                            self.applyBlock(world, Blocks.airState, x, y, z, chunkBox)
                        } else {
                            self.applyBlock(world, Self.fillBlock, x, y, z, chunkBox)
                        }
                    }
                }
            }
        }
    }

    fileprivate func applyGenerateBoxOnFillOnly(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x0: Int32,
        _ y0: Int32,
        _ z0: Int32,
        _ x1: Int32,
        _ y1: Int32,
        _ z1: Int32,
        _ state: BlockState
    ) {
        for y in y0...y1 {
            for x in x0...x1 {
                for z in z0...z1 {
                    if self.getBlock(world, x, y, z, chunkBox) == Self.fillBlock {
                        self.applyBlock(world, state, x, y, z, chunkBox)
                    }
                }
            }
        }
    }

    fileprivate func applyFillColumnDown(
        _ world: StructureWorldView,
        _ state: BlockState,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32,
        _ chunkBox: BoundingBox
    ) {
        var pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        while pos.y > world.minimumWorldY + 1 && world.isReplaceableForStructure(world.block(at: pos)) {
            world.setBlock(state, at: pos)
            pos = PosInt3D(x: pos.x, y: pos.y - 1, z: pos.z)
        }
    }

    fileprivate func applySpawnElder(
        _ world: StructureWorldView,
        _ chunkBox: BoundingBox,
        _ x: Int32,
        _ y: Int32,
        _ z: Int32
    ) {
        let pos = self.getWorldPos(x, y, z)
        guard chunkBox.contains(pos) else { return }
        world.elderGuardians.append(pos)
    }

    private func record(_ operation: StructurePieceOperation) {
        self.recorder?.record(operation)
    }
}

/// A sparse block volume backed by per-section paletted storage.
///
/// The storage is intentionally simple:
/// - the world is divided into 16x16x16 sections
/// - each touched section stores a dense palette/index array plus a touched bitset
/// - untouched cells read through to the caller-provided world sampler
///
/// This keeps the implementation compact while still giving structure generation the same
/// "read world, then overlay writes" model that vanilla piece code expects.
public final class StructureBlockVolume {
    public let bounds: BoundingBox

    private struct SectionKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private final class Section {
        private let storage = PalettedChunkBlockStorage(filledWith: Blocks.airState)
        private var touched = [UInt64](repeating: 0, count: 64)

        func set(_ state: BlockState, at localPos: PosInt3D) {
            self.storage.setBlock(state, at: localPos)
            let index = (Int(localPos.y) << 8) | (Int(localPos.z) << 4) | Int(localPos.x)
            self.touched[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }

        func get(at localPos: PosInt3D) -> BlockState? {
            let index = (Int(localPos.y) << 8) | (Int(localPos.z) << 4) | Int(localPos.x)
            let mask = UInt64(1) << UInt64(index & 63)
            guard (self.touched[index >> 6] & mask) != 0 else {
                return nil
            }
            return self.storage.getBlock(at: localPos)
        }
    }

    private let fallbackSampler: (PosInt3D) -> BlockState
    private var sections: [SectionKey: Section] = [:]

    public init(bounds: BoundingBox, fallbackSampler: @escaping (PosInt3D) -> BlockState) {
        self.bounds = bounds
        self.fallbackSampler = fallbackSampler
    }

    public func block(at pos: PosInt3D) -> BlockState {
        guard self.bounds.contains(pos) else {
            return self.fallbackSampler(pos)
        }
        let (key, localPos) = self.sectionKeyAndLocalPos(for: pos)
        if let section = self.sections[key], let state = section.get(at: localPos) {
            return state
        }
        return self.fallbackSampler(pos)
    }

    public func setBlock(_ state: BlockState, at pos: PosInt3D) {
        guard self.bounds.contains(pos) else {
            return
        }
        let (key, localPos) = self.sectionKeyAndLocalPos(for: pos)
        let section: Section
        if let existing = self.sections[key] {
            section = existing
        } else {
            let created = Section()
            self.sections[key] = created
            section = created
        }
        section.set(state, at: localPos)
    }

    public func allTouchedBlocks() -> [(PosInt3D, BlockState)] {
        var result: [(PosInt3D, BlockState)] = []
        for (key, section) in self.sections {
            for localY in 0..<16 {
                for localZ in 0..<16 {
                    for localX in 0..<16 {
                        let local = PosInt3D(x: Int32(localX), y: Int32(localY), z: Int32(localZ))
                        guard let state = section.get(at: local) else { continue }
                        let worldPos = PosInt3D(
                            x: key.x &* 16 &+ Int32(localX),
                            y: key.y &* 16 &+ Int32(localY),
                            z: key.z &* 16 &+ Int32(localZ)
                        )
                        result.append((worldPos, state))
                    }
                }
            }
        }
        result.sort { left, right in
            if left.0.y != right.0.y { return left.0.y < right.0.y }
            if left.0.z != right.0.z { return left.0.z < right.0.z }
            return left.0.x < right.0.x
        }
        return result
    }

    private func sectionKeyAndLocalPos(for pos: PosInt3D) -> (SectionKey, PosInt3D) {
        let sectionX = floorDiv(pos.x, by: 16)
        let sectionY = floorDiv(pos.y, by: 16)
        let sectionZ = floorDiv(pos.z, by: 16)
        let localX = pos.x - sectionX * 16
        let localY = pos.y - sectionY * 16
        let localZ = pos.z - sectionZ * 16
        return (
            SectionKey(x: sectionX, y: sectionY, z: sectionZ),
            PosInt3D(x: localX, y: localY, z: localZ)
        )
    }
}

final class StructureWorldView {
    let seaLevel: Int32
    let minimumWorldY: Int32
    let volume: StructureBlockVolume
    var elderGuardians: [PosInt3D] = []

    init(seaLevel: Int32, minimumWorldY: Int32, volume: StructureBlockVolume) {
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.volume = volume
    }

    func block(at pos: PosInt3D) -> BlockState {
        self.volume.block(at: pos)
    }

    func setBlock(_ state: BlockState, at pos: PosInt3D) {
        self.volume.setBlock(state, at: pos)
    }

    func isReplaceableForStructure(_ state: BlockState) -> Bool {
        let id = state.type.id
        return state.type.isAir
            || id == "minecraft:water"
            || id == "minecraft:lava"
            || id == "minecraft:kelp"
            || id == "minecraft:kelp_plant"
            || id == "minecraft:seagrass"
            || id == "minecraft:tall_seagrass"
            || id == "minecraft:bubble_column"
    }
}

func getRandomWithCarverSeed(worldSeed: WorldSeed, chunkX: Int32, chunkZ: Int32) -> CheckedRandom {
    checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ)
}
