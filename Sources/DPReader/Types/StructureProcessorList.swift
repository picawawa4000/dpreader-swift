import Foundation

/// The processor behavior needed by template-based structure generation.
public struct StructureProcessorList: Decodable {
    let processors: [StructureProcessor]
}

enum StructureProcessor: Decodable {
    case rule([StructureProcessorRule])
    case blockRot(integrity: Float, rottableBlocks: String?)
    case capped(limit: Int, delegate: Box)
    case protectedBlocks(value: JSONValue)

    final class Box: Decodable {
        let value: StructureProcessor
        init(from decoder: any Decoder) throws { self.value = try StructureProcessor(from: decoder) }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = addDefaultNamespace(try c.decode(String.self, forKey: .type))
        switch type {
        case "minecraft:rule": self = .rule(try c.decode([StructureProcessorRule].self, forKey: .rules))
        case "minecraft:block_rot":
            self = .blockRot(
                integrity: try c.decode(Float.self, forKey: .integrity),
                rottableBlocks: try c.decodeIfPresent(String.self, forKey: .rottableBlocks)
            )
        case "minecraft:capped": self = .capped(limit: try c.decode(Int.self, forKey: .limit), delegate: try c.decode(Box.self, forKey: .delegate))
        case "minecraft:protected_blocks":
            let value = try c.decode(JSONValue.self, forKey: .value)
            if decoder.dpReaderPackFormat < Version(major: 101, minor: 2) {
                guard case .string(let tag) = value, tag.hasPrefix("#") else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .value,
                        in: c,
                        debugDescription: "protected_blocks.value must be a hash-prefixed block tag before pack format 101.2"
                    )
                }
            } else {
                switch value {
                case .string(let identifier) where !identifier.isEmpty && identifier != "#":
                    break
                case .array(let identifiers) where !identifiers.isEmpty && identifiers.allSatisfy({ value in
                    guard case .string(let identifier) = value else { return false }
                    return !identifier.isEmpty && !identifier.hasPrefix("#")
                }):
                    break
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .value,
                        in: c,
                        debugDescription: "protected_blocks.value must be a block ID, list, or hash-prefixed block tag"
                    )
                }
            }
            self = .protectedBlocks(value: value)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown structure processor: \(type)")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type = "processor_type", rules, integrity, limit, delegate, value
        case rottableBlocks = "rottable_blocks"
    }
}

struct StructureProcessorRule: Decodable {
    let inputPredicate: StructureProcessorPredicate
    let outputState: StructureProcessorBlockState
    let lootTable: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputPredicate = try c.decode(StructureProcessorPredicate.self, forKey: .inputPredicate)
        self.outputState = try c.decode(StructureProcessorBlockState.self, forKey: .outputState)
        self.lootTable = try c.decodeIfPresent(StructureProcessorLootModifier.self, forKey: .blockEntityModifier)?.lootTable
    }
    private enum CodingKeys: String, CodingKey { case inputPredicate = "input_predicate", outputState = "output_state", blockEntityModifier = "block_entity_modifier" }
}

struct StructureProcessorPredicate: Decodable {
    let type: String
    let block: String?
    let blockState: StructureProcessorBlockState?
    let tag: String?
    let probability: Float?
    private enum CodingKeys: String, CodingKey { case type = "predicate_type", block, blockState = "block_state", tag, probability }
}

struct StructureProcessorBlockState: Decodable {
    let name: String
    let properties: [String: String]?

    init(from decoder: any Decoder) throws {
        let format = decoder.dpReaderPackFormat
        if format >= Version(major: 115, minor: 0) {
            if let singleValue = try? decoder.singleValueContainer(),
               let name = try? singleValue.decode(String.self) {
                guard !name.isEmpty else {
                    throw DecodingError.dataCorruptedError(in: singleValue, debugDescription: "A block-state ID cannot be empty")
                }
                self.name = name
                self.properties = nil
                return
            }

            let container = try decoder.container(keyedBy: ModernCodingKeys.self)
            guard !container.contains(.legacyName) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .legacyName,
                    in: container,
                    debugDescription: "Block states use id/properties rather than Name/Properties in pack format 115.0+"
                )
            }
            self.name = try container.decode(String.self, forKey: .id)
            self.properties = try container.decodeIfPresent([String: String].self, forKey: .properties)
            return
        }

        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        guard !container.contains(.id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Block states use Name/Properties before pack format 115.0"
            )
        }
        self.name = try container.decode(String.self, forKey: .name)
        self.properties = try container.decodeIfPresent([String: String].self, forKey: .properties)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case name = "Name"
        case properties = "Properties"
        case id
    }

    private enum ModernCodingKeys: String, CodingKey {
        case id
        case properties
        case legacyName = "Name"
    }

    var blockState: BlockState {
        if let properties { return BlockState(id: addDefaultNamespace(name), properties: properties) }
        return BlockState(id: addDefaultNamespace(name))
    }
}

private struct StructureProcessorLootModifier: Decodable {
    let lootTable: String?
    private enum CodingKeys: String, CodingKey { case lootTable = "loot_table" }
}
