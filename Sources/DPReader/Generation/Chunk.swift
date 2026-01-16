/// TODO: should this be a struct or a class?
public class Block {
    public let id: String

    public init(withID id: String) {
        self.id = id
    }
}

/// TODO: should this be a struct or a class?
public struct BlockState {
    public let type: Block
    public let properties: [String: String]
}

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

    /// Indicates that the given position is to be terrain.
    /// (In vanilla Minecraft, this is indicated by setting that block to stone.)
    /// - Parameter at: The position to set as terrain.
    func setTerrain(at: PosInt3D)
    /// Get whether the given position is terrain.
    /// - Parameter at: The position to get the status of.
    func isTerrain(at: PosInt3D) -> Bool
}