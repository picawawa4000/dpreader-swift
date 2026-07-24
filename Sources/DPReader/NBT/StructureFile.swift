import Foundation

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

public struct StructureTemplateBlock {
    public let state: Int
    public let pos: PosInt3D
    public let nbt: NBTTag?
}

public struct StructureTemplateEntity {
    public let pos: [Double]
    public let blockPos: PosInt3D
    public let nbt: NBTTag?
}

public struct StructureTemplate {
    public let size: PosInt3D
    public let palettes: [[BlockState]]
    public let blocks: [StructureTemplateBlock]
    public let entities: [StructureTemplateEntity]

    public var palette: [BlockState] {
        self.palettes[0]
    }

    public init(fromFileAt url: URL) throws {
        let root = try NBTDecoder().decodeRoot(fromFileAt: url)
        try self.init(fromRootTag: root)
    }

    public init(fromRootTag root: NBTTag.Root) throws {
        guard case .compound(let rootValues) = root.tag else {
            throw StructureTemplateDecodingError.invalidRoot
        }

        self.size = try StructureTemplate.decodeInt3(rootValues["size"], fieldName: "size")

        if let palettesTag = rootValues["palettes"] {
            self.palettes = try StructureTemplate.decodePalettes(palettesTag)
        } else {
            self.palettes = [try StructureTemplate.decodePalette(rootValues["palette"], fieldName: "palette")]
        }

        self.blocks = try StructureTemplate.decodeBlocks(rootValues["blocks"])
        self.entities = try StructureTemplate.decodeEntities(rootValues["entities"])
    }

    private static func decodePalettes(_ tag: NBTTag) throws -> [[BlockState]] {
        guard case .list(let paletteTags) = tag else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: "palettes", expected: "list", actual: tag.typeDescription)
        }
        return try paletteTags.enumerated().map { index, paletteTag in
            try decodePalette(paletteTag, fieldName: "palettes[\(index)]")
        }
    }

    private static func decodePalette(_ tag: NBTTag?, fieldName: String) throws -> [BlockState] {
        guard let tag else {
            throw StructureTemplateDecodingError.missingField(fieldName)
        }
        guard case .list(let entries) = tag else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: fieldName, expected: "list", actual: tag.typeDescription)
        }
        return try entries.enumerated().map { index, entry in
            guard case .compound(let values) = entry else {
                throw StructureTemplateDecodingError.typeMismatch(
                    fieldName: "\(fieldName)[\(index)]",
                    expected: "compound",
                    actual: entry.typeDescription
                )
            }
            guard case .string(let rawName)? = values["Name"] else {
                throw StructureTemplateDecodingError.missingField("\(fieldName)[\(index)].Name")
            }
            let name = addDefaultNamespace(rawName)
            let properties = try decodeStringMap(values["Properties"], fieldName: "\(fieldName)[\(index)].Properties")
            if let properties {
                return BlockState(type: Block(withID: name), properties: properties)
            }
            return BlockState(type: Block(withID: name))
        }
    }

    private static func decodeBlocks(_ tag: NBTTag?) throws -> [StructureTemplateBlock] {
        guard let tag else {
            throw StructureTemplateDecodingError.missingField("blocks")
        }
        guard case .list(let entries) = tag else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: "blocks", expected: "list", actual: tag.typeDescription)
        }
        return try entries.enumerated().map { index, entry in
            guard case .compound(let values) = entry else {
                throw StructureTemplateDecodingError.typeMismatch(
                    fieldName: "blocks[\(index)]",
                    expected: "compound",
                    actual: entry.typeDescription
                )
            }
            return StructureTemplateBlock(
                state: try decodeInt(values["state"], fieldName: "blocks[\(index)].state"),
                pos: try decodeInt3(values["pos"], fieldName: "blocks[\(index)].pos"),
                nbt: values["nbt"]
            )
        }
    }

    private static func decodeEntities(_ tag: NBTTag?) throws -> [StructureTemplateEntity] {
        guard let tag else {
            return []
        }
        guard case .list(let entries) = tag else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: "entities", expected: "list", actual: tag.typeDescription)
        }
        return try entries.enumerated().map { index, entry in
            guard case .compound(let values) = entry else {
                throw StructureTemplateDecodingError.typeMismatch(
                    fieldName: "entities[\(index)]",
                    expected: "compound",
                    actual: entry.typeDescription
                )
            }
            return StructureTemplateEntity(
                pos: try decodeDouble3(values["pos"], fieldName: "entities[\(index)].pos"),
                blockPos: try decodeInt3(values["blockPos"], fieldName: "entities[\(index)].blockPos"),
                nbt: values["nbt"]
            )
        }
    }

    private static func decodeInt(_ tag: NBTTag?, fieldName: String) throws -> Int {
        guard let tag else {
            throw StructureTemplateDecodingError.missingField(fieldName)
        }
        switch tag {
        case .byte(let value):
            return Int(value)
        case .short(let value):
            return Int(value)
        case .int(let value):
            return Int(value)
        case .long(let value):
            return Int(value)
        default:
            throw StructureTemplateDecodingError.typeMismatch(fieldName: fieldName, expected: "integer", actual: tag.typeDescription)
        }
    }

    private static func decodeInt3(_ tag: NBTTag?, fieldName: String) throws -> PosInt3D {
        guard let tag else {
            throw StructureTemplateDecodingError.missingField(fieldName)
        }
        guard case .list(let values) = tag, values.count == 3 else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: fieldName, expected: "list[3]", actual: tag.typeDescription)
        }
        return PosInt3D(
            x: Int32(try decodeInt(values[0], fieldName: "\(fieldName)[0]")),
            y: Int32(try decodeInt(values[1], fieldName: "\(fieldName)[1]")),
            z: Int32(try decodeInt(values[2], fieldName: "\(fieldName)[2]"))
        )
    }

    private static func decodeDouble3(_ tag: NBTTag?, fieldName: String) throws -> [Double] {
        guard let tag else {
            throw StructureTemplateDecodingError.missingField(fieldName)
        }
        guard case .list(let values) = tag, values.count == 3 else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: fieldName, expected: "list[3]", actual: tag.typeDescription)
        }
        return try values.enumerated().map { index, value in
            switch value {
            case .float(let floatValue):
                return Double(floatValue)
            case .double(let doubleValue):
                return doubleValue
            default:
                throw StructureTemplateDecodingError.typeMismatch(
                    fieldName: "\(fieldName)[\(index)]",
                    expected: "floating-point",
                    actual: value.typeDescription
                )
            }
        }
    }

    private static func decodeStringMap(_ tag: NBTTag?, fieldName: String) throws -> [String: String]? {
        guard let tag else {
            return nil
        }
        guard case .compound(let values) = tag else {
            throw StructureTemplateDecodingError.typeMismatch(fieldName: fieldName, expected: "compound", actual: tag.typeDescription)
        }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard case .string(let stringValue) = value else {
                throw StructureTemplateDecodingError.typeMismatch(
                    fieldName: "\(fieldName).\(key)",
                    expected: "string",
                    actual: value.typeDescription
                )
            }
            result[key] = stringValue
        }
        return result
    }
}

public enum StructureTemplateDecodingError: Error, Equatable {
    case invalidRoot
    case missingField(String)
    case typeMismatch(fieldName: String, expected: String, actual: String)
}

private extension NBTTag {
    var typeDescription: String {
        switch self {
        case .end: return "end"
        case .byte: return "byte"
        case .short: return "short"
        case .int: return "int"
        case .long: return "long"
        case .float: return "float"
        case .double: return "double"
        case .byteArray: return "byte_array"
        case .intArray: return "int_array"
        case .longArray: return "long_array"
        case .string: return "string"
        case .list: return "list"
        case .compound: return "compound"
        }
    }
}
