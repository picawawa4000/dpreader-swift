import Foundation

/// The processor behavior needed by template-based structure generation.
public struct StructureProcessorList: Decodable {
    let processors: [StructureProcessor]
}

enum StructureProcessor: Decodable {
    case rule([StructureProcessorRule])
    case blockRot(integrity: Float, rottableBlocks: String?)
    case capped(limit: Int, delegate: Box)
    case protectedBlocks

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
        case "minecraft:protected_blocks": self = .protectedBlocks
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown structure processor: \(type)")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type = "processor_type", rules, integrity, limit, delegate
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
    let tag: String?
    let probability: Float?
    private enum CodingKeys: String, CodingKey { case type = "predicate_type", block, tag, probability }
}

struct StructureProcessorBlockState: Decodable {
    let name: String
    let properties: [String: String]?
    private enum CodingKeys: String, CodingKey { case name = "Name", properties = "Properties" }
    var blockState: BlockState {
        if let properties { return BlockState(id: addDefaultNamespace(name), properties: properties) }
        return BlockState(id: addDefaultNamespace(name))
    }
}

private struct StructureProcessorLootModifier: Decodable {
    let lootTable: String?
    private enum CodingKeys: String, CodingKey { case lootTable = "loot_table" }
}
