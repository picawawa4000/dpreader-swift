public class StructureFile: Codable {
    public let DataVersion: Int32
    public let size: [Int32]
    public let palette: [StructureFilePaletteElement]
    public let palettes: [[StructureFilePaletteElement]]?
    public let blocks: [StructureFileBlock]
    public let entities: [StructureFileEntity]
}

public struct StructureFilePaletteElement: Codable {
    public let Name: String
    public let Properties: [String: String]?
}

public struct StructureFileBlock: Codable {
    public let state: Int32
    public let pos: [Int32]
    /// TODO: this is not the correct block entity format
    public let nbt: [String: String]?
}

public struct StructureFileEntity: Codable {
    public let pos: [Int32]
    public let blockPos: [Int32]
    /// TODO: this is not the correct entity format
    public let nbt: [String: String]
}
