/// TODO: should this be a struct or a class?
public final class Block: Sendable {
    public let id: String

    /// It is recommended to use the `Blocks` interface to get vanilla block references,
    /// as opposed to creating them this way, as that way object equality works as a more efficient
    /// method of block comparison.
    /// - Parameter id: The namespaced block ID.
    public init(withID id: String) {
        self.id = id
    }

    public var isAir: Bool {
        get {
            return ["minecraft:air", "minecraft:cave_air", "minecraft:void_air"].contains(self.id)
        }
    }
}

public actor Blocks {
    public static let AIR = Block(withID: "minecraft:air")
}

/// TODO: should this be a struct or a class?
public struct BlockState {
    public let type: Block
    public var properties: [String: String]? = nil

    public init(type: Block) {
        self.type = type
    }

    public init(type: Block, properties: [String: String]) {
        self.type = type
        self.properties = properties
    }
}

/*
I still don't know how I want to do data storage, so I'm shelving this protocol for now.
Anything that wants chunks can just use `ProtoChunk`.

/// Represents a chunk (16x16 area) of the world.
public protocol Chunk {
    /// Set the block at the given chunk-relative position.
    /// - Parameters:
    ///   - state: The state to set.
    ///   - at: The position to set the state at.
    func setBlock(_ state: BlockState, at: PosInt3D)
    /// Get the block at the given chunk-relative position.
    /// - Parameter at: The position to get the block at.
    func getBlock(at: PosInt3D) -> BlockState

    func copyFrom(_ other: Chunk)

    /// Indicates that the given position is to be terrain.
    /// (In vanilla Minecraft and the default implementation, this is indicated by setting that block to stone.)
    /// - Parameter at: The position to set as terrain.
    func setTerrain(at: PosInt3D)
    /// Get whether the given position is terrain.
    /// (In the default implementation, this is indicated by checking whether that block is solid.)
    /// - Parameter at: The position to get the status of.
    func isTerrain(at: PosInt3D) -> Bool
}

public extension Chunk {
    func setTerrain(at pos: PosInt3D) {
        let stoneBlock = Block(withID: "minecraft:stone")
        let stoneState = BlockState(type: stoneBlock, properties: [:])
        self.setBlock(stoneState, at: pos)
    }

    func isTerrain(at pos: PosInt3D) -> Bool {
        let blockState = self.getBlock(at: pos)
        return !blockState.type.isAir
    }
}
*/

/// A compact container that stores a "palette" of `BlockState`s and data consisting of pointers to that array,
/// packed into `UInt64`s for efficient storage. The same type of storage as Minecraft uses.
public final class PalettedChunkBlockStorage {
    private static let sideLength = 16
    private static let totalBlockCount = sideLength * sideLength * sideLength

    private var palette: [BlockState]
    // Precise data format:
    // - Data is packed into 64-bit words
    // - Indices start from the lowest bit, so for indices A, B, C, the start of a word is ...CCCCBBBBAAAA
    // - The bit width of each index is max(4, bitwidth(palette.count))
    // - If a word runs out of space for a given index, the index starts at the next word (that is, indices are not packed across words)
    // - There are always exactly 4096 indices, and they are accessed by the formula `i = (y * 16 + z) * 16 + x`
    //   (which can be simplified to `i = (y << 4 | z) << 4 | x` using bitwise logic)
    // - If there is only one element in the palette, this field is not required and that element fills the section
    private var data: [UInt64]?

    public init(filledWith state: BlockState) {
        self.palette = [state]
        self.data = nil
    }

    public func setBlock(_ state: BlockState, at pos: PosInt3D) {
        let index = Self.index(for: pos)
        if let paletteIndex = self.paletteIndex(of: state) {
            guard self.palette.count > 1 else { return }
            if self.data == nil {
                let bitWidth = Self.bitWidth(for: self.palette.count)
                self.data = [UInt64](repeating: 0, count: Self.wordCount(for: bitWidth))
            }
            self.setPaletteIndex(paletteIndex, at: index)
            return
        }

        let oldPaletteCount = self.palette.count
        self.palette.append(state)
        let newPaletteCount = self.palette.count

        if oldPaletteCount == 1 {
            let bitWidth = Self.bitWidth(for: newPaletteCount)
            self.data = [UInt64](repeating: 0, count: Self.wordCount(for: bitWidth))
            self.setPaletteIndex(newPaletteCount - 1, at: index)
            return
        }

        let oldBitWidth = Self.bitWidth(for: oldPaletteCount)
        let newBitWidth = Self.bitWidth(for: newPaletteCount)
        if self.data == nil {
            self.data = [UInt64](repeating: 0, count: Self.wordCount(for: newBitWidth))
        } else if newBitWidth != oldBitWidth {
            self.data = Self.repackData(
                self.data!,
                fromBitWidth: oldBitWidth,
                toBitWidth: newBitWidth
            )
        }
        self.setPaletteIndex(newPaletteCount - 1, at: index)
    }

    public func getBlock(at pos: PosInt3D) -> BlockState {
        if self.palette.count == 1 { return self.palette[0] }
        guard let data = self.data else { return self.palette[0] }
        let index = Self.index(for: pos)
        let bitWidth = Self.bitWidth(for: self.palette.count)
        let paletteIndex = Self.readIndex(at: index, from: data, bitWidth: bitWidth)
        if paletteIndex < self.palette.count { return self.palette[paletteIndex] }
        return self.palette[0]
    }

    internal var debugData: [UInt64]? { self.data }
    internal var debugPaletteCount: Int { self.palette.count }

    private static func index(for pos: PosInt3D) -> Int {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.sideLength), "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")
        return (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
    }

    private func paletteIndex(of state: BlockState) -> Int? {
        for (index, entry) in self.palette.enumerated() {
            if entry.type.id == state.type.id && entry.properties == state.properties {
                return index
            }
        }
        return nil
    }

    private static func bitWidth(for paletteCount: Int) -> Int {
        let maxIndex = max(0, paletteCount - 1)
        let neededBits = max(1, 64 - maxIndex.leadingZeroBitCount)
        return max(4, neededBits)
    }

    private static func indicesPerWord(for bitWidth: Int) -> Int {
        return max(1, 64 / bitWidth)
    }

    private static func wordCount(for bitWidth: Int) -> Int {
        let perWord = Self.indicesPerWord(for: bitWidth)
        return (Self.totalBlockCount + perWord - 1) / perWord
    }

    private func setPaletteIndex(_ paletteIndex: Int, at index: Int) {
        guard var data = self.data else { return }
        let bitWidth = Self.bitWidth(for: self.palette.count)
        Self.writeIndex(paletteIndex, at: index, to: &data, bitWidth: bitWidth)
        self.data = data
    }

    private static func readIndex(at index: Int, from data: [UInt64], bitWidth: Int) -> Int {
        let perWord = Self.indicesPerWord(for: bitWidth)
        let wordIndex = index / perWord
        let slotIndex = index % perWord
        let shift = slotIndex * bitWidth
        let mask: UInt64 = (UInt64(1) << UInt64(bitWidth)) - 1
        return Int((data[wordIndex] >> UInt64(shift)) & mask)
    }

    private static func writeIndex(_ paletteIndex: Int, at index: Int, to data: inout [UInt64], bitWidth: Int) {
        let perWord = Self.indicesPerWord(for: bitWidth)
        let wordIndex = index / perWord
        let slotIndex = index % perWord
        let shift = slotIndex * bitWidth
        let mask: UInt64 = ((UInt64(1) << UInt64(bitWidth)) - 1) << UInt64(shift)
        let value = (UInt64(paletteIndex) << UInt64(shift)) & mask
        data[wordIndex] = (data[wordIndex] & ~mask) | value
    }

    private static func repackData(_ data: [UInt64], fromBitWidth: Int, toBitWidth: Int) -> [UInt64] {
        var newData = [UInt64](repeating: 0, count: Self.wordCount(for: toBitWidth))
        for index in 0..<Self.totalBlockCount {
            let paletteIndex = Self.readIndex(at: index, from: data, bitWidth: fromBitWidth)
            Self.writeIndex(paletteIndex, at: index, to: &newData, bitWidth: toBitWidth)
        }
        return newData
    }
}
