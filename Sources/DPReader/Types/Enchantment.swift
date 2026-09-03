import Foundation

/// A registry selector expressed as one ID, one tag, or an explicit ID list.
public struct RegistryReferenceList: Codable, Equatable {
    public let values: [TagValue]

    public init(values: [TagValue]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let value = try? container.decode(String.self) {
            self.values = [TagValue(rawValue: value)]
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [TagValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(TagValue.self))
            }
            self.values = values
            return
        }

        self.values = [try TagValue(from: decoder)]
    }

    public func encode(to encoder: Encoder) throws {
        if values.count == 1, let first = values.first {
            try first.encode(to: encoder)
            return
        }

        var container = encoder.unkeyedContainer()
        for value in values {
            try container.encode(value)
        }
    }
}

/// A linear base-plus-per-level enchantment cost.
public struct EnchantmentCost: Codable, Equatable {
    public let base: Int
    public let perLevelAboveFirst: Int

    public init(base: Int, perLevelAboveFirst: Int) {
        self.base = base
        self.perLevelAboveFirst = perLevelAboveFirst
    }

    public func forLevel(_ level: Int) -> Int {
        self.base + self.perLevelAboveFirst * (level - 1)
    }

    enum CodingKeys: String, CodingKey {
        case base
        case perLevelAboveFirst = "per_level_above_first"
    }
}

/// The fields of an enchantment definition needed during loot evaluation.
public struct Enchantment: Codable, Equatable {
    public let description: JSONValue
    public let supportedItems: RegistryReferenceList
    public let primaryItems: RegistryReferenceList?
    public let weight: Int
    public let maxLevel: Int
    public let minCost: EnchantmentCost
    public let maxCost: EnchantmentCost
    public let anvilCost: Int
    public let slots: [String]
    public let exclusiveSet: RegistryReferenceList
    public let effects: [String: JSONValue]

    public init(
        description: JSONValue,
        supportedItems: RegistryReferenceList,
        primaryItems: RegistryReferenceList? = nil,
        weight: Int,
        maxLevel: Int,
        minCost: EnchantmentCost,
        maxCost: EnchantmentCost,
        anvilCost: Int,
        slots: [String],
        exclusiveSet: RegistryReferenceList = RegistryReferenceList(values: []),
        effects: [String: JSONValue] = [:]
    ) {
        self.description = description
        self.supportedItems = supportedItems
        self.primaryItems = primaryItems
        self.weight = weight
        self.maxLevel = maxLevel
        self.minCost = minCost
        self.maxCost = maxCost
        self.anvilCost = anvilCost
        self.slots = slots
        self.exclusiveSet = exclusiveSet
        self.effects = effects
    }

    public func minPower(for level: Int) -> Int {
        self.minCost.forLevel(level)
    }

    public func maxPower(for level: Int) -> Int {
        self.maxCost.forLevel(level)
    }

    enum CodingKeys: String, CodingKey {
        case description
        case supportedItems = "supported_items"
        case primaryItems = "primary_items"
        case weight
        case maxLevel = "max_level"
        case minCost = "min_cost"
        case maxCost = "max_cost"
        case anvilCost = "anvil_cost"
        case slots
        case exclusiveSet = "exclusive_set"
        case effects
    }

    public init(from decoder: Decoder) throws {
        try decoder.requirePackVersions(.atLeast(.init(major: 42, minor: 0)), for: "data-driven enchantments")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try container.decode(JSONValue.self, forKey: .description)
        self.supportedItems = try container.decode(RegistryReferenceList.self, forKey: .supportedItems)
        self.primaryItems = try container.decodeIfPresent(RegistryReferenceList.self, forKey: .primaryItems)
        self.weight = try container.decode(Int.self, forKey: .weight)
        self.maxLevel = try container.decode(Int.self, forKey: .maxLevel)
        self.minCost = try container.decode(EnchantmentCost.self, forKey: .minCost)
        self.maxCost = try container.decode(EnchantmentCost.self, forKey: .maxCost)
        self.anvilCost = try container.decode(Int.self, forKey: .anvilCost)
        self.slots = try container.decode([String].self, forKey: .slots)
        self.exclusiveSet = try container.decodeIfPresent(RegistryReferenceList.self, forKey: .exclusiveSet) ?? RegistryReferenceList(values: [])
        self.effects = try container.decodeIfPresent([String: JSONValue].self, forKey: .effects) ?? [:]

        guard !supportedItems.values.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .supportedItems, in: container, debugDescription: "Enchantment supported_items must not be empty")
        }
        if let primaryItems, primaryItems.values.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .primaryItems, in: container, debugDescription: "Enchantment primary_items must not be empty when present")
        }
        guard weight > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .weight, in: container, debugDescription: "Enchantment weight must be a positive integer")
        }
        guard maxLevel > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .maxLevel, in: container, debugDescription: "Enchantment max_level must be a positive integer")
        }
        if decoder.dpReaderPackFormat >= Version(major: 44, minor: 0) {
            guard weight <= 1_024 else {
                throw DecodingError.dataCorruptedError(forKey: .weight, in: container, debugDescription: "Enchantment weight must be at most 1024 in pack format \(decoder.dpReaderPackFormat)")
            }
            guard maxLevel <= 255 else {
                throw DecodingError.dataCorruptedError(forKey: .maxLevel, in: container, debugDescription: "Enchantment max_level must be at most 255 in pack format \(decoder.dpReaderPackFormat)")
            }
        }
        guard anvilCost >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .anvilCost, in: container, debugDescription: "Enchantment anvil_cost must be non-negative")
        }
        guard !slots.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .slots, in: container, debugDescription: "Enchantment slots must not be empty")
        }
        let allowedSlots: Set<String> = ["any", "hand", "mainhand", "offhand", "armor", "feet", "legs", "chest", "head", "body"]
        if let invalidSlot = slots.first(where: { !allowedSlots.contains($0) }) {
            throw DecodingError.dataCorruptedError(forKey: .slots, in: container, debugDescription: "Unknown enchantment slot group '\(invalidSlot)'")
        }
        try Self.validateEffects(effects, packFormat: decoder.dpReaderPackFormat, codingPath: decoder.codingPath + [CodingKeys.effects])
    }

    private static func validateEffects(_ effects: [String: JSONValue], packFormat: Version, codingPath: [CodingKey]) throws {
        func visit(_ value: JSONValue) throws {
            switch value {
            case .array(let values):
                try values.forEach(visit)
            case .object(let object):
                if case .string(let rawType)? = object["type"] {
                    let type = addDefaultNamespace(rawType)
                    if ["minecraft:linear", "minecraft:clamped", "minecraft:fraction", "minecraft:levels_squared", "minecraft:lookup"].contains(type) {
                        try validateLevelBasedValue(value, packFormat: packFormat, codingPath: codingPath)
                        return
                    }
                    switch type {
                    case "minecraft:damage_item" where packFormat >= Version(major: 56, minor: 0):
                        throw schemaError("enchantment effect minecraft:damage_item was removed in pack format 56.0; use minecraft:change_item_damage")
                    case "minecraft:change_item_damage" where packFormat < Version(major: 56, minor: 0):
                        throw schemaError("enchantment effect minecraft:change_item_damage requires pack format 56.0 or newer")
                    case "minecraft:replace_disc" where packFormat >= Version(major: 48, minor: 0):
                        throw schemaError("enchantment effect minecraft:replace_disc was removed in pack format 48.0; use minecraft:replace_disk")
                    case "minecraft:replace_disk" where packFormat < Version(major: 48, minor: 0):
                        throw schemaError("enchantment effect minecraft:replace_disk requires pack format 48.0 or newer")
                    default:
                        break
                    }
                    if object["trigger_game_event"] != nil,
                       packFormat < Version(major: 43, minor: 0),
                       ["minecraft:replace_block", "minecraft:replace_disc", "minecraft:replace_disk", "minecraft:set_block_properties"].contains(type) {
                        throw schemaError("enchantment effect trigger_game_event requires pack format 43.0 or newer")
                    }
                }
                try object.values.forEach(visit)
            default:
                break
            }
        }

        func schemaError(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
        }

        try effects.values.forEach(visit)
    }
}

/// Validates the recursive level-based-value grammar used by enchantment
/// effects and enchantment-aware loot constructs.
func validateLevelBasedValue(
    _ value: JSONValue,
    packFormat: Version,
    codingPath: [CodingKey]
) throws {
    func invalid(_ message: String) throws -> Never {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }
    func requireNumber(_ object: [String: JSONValue], _ field: String, type: String) throws -> Double {
        guard let number = object[field]?.doubleValue else {
            try invalid("enchantment level value \(type) requires numeric \(field)")
        }
        return number
    }
    func requireNested(_ object: [String: JSONValue], _ field: String, type: String) throws {
        guard let nested = object[field] else {
            try invalid("enchantment level value \(type) requires \(field)")
        }
        try validateLevelBasedValue(nested, packFormat: packFormat, codingPath: codingPath)
    }

    if value.doubleValue != nil { return }
    guard case .object(let object) = value, let rawType = object["type"]?.stringValue else {
        try invalid("an enchantment level value must be a number or an object with a type")
    }
    let type = addDefaultNamespace(rawType)
    switch type {
    case "minecraft:linear":
        _ = try requireNumber(object, "base", type: type)
        _ = try requireNumber(object, "per_level_above_first", type: type)
    case "minecraft:clamped":
        try requireNested(object, "value", type: type)
        let minimum = try requireNumber(object, "min", type: type)
        let maximum = try requireNumber(object, "max", type: type)
        guard minimum <= maximum else {
            try invalid("enchantment level value minecraft:clamped requires min to be at most max")
        }
    case "minecraft:fraction":
        try requireNested(object, "numerator", type: type)
        try requireNested(object, "denominator", type: type)
    case "minecraft:levels_squared":
        _ = try requireNumber(object, "added", type: type)
    case "minecraft:lookup":
        guard packFormat >= Version(major: 46, minor: 0) else {
            try invalid("enchantment level value minecraft:lookup requires pack format 46.0 or newer")
        }
        guard let values = object["values"]?.arrayValue, values.allSatisfy({ $0.doubleValue != nil }) else {
            try invalid("enchantment level value minecraft:lookup requires a list of numeric values")
        }
        try requireNested(object, "fallback", type: type)
    default:
        try invalid("unknown enchantment level value type '\(rawType)'")
    }
}

/// Enchantment registries and tags consulted by enchantment-related item modifiers.
public struct LootEnchantmentResources {
    public let enchantmentRegistry: Registry<Enchantment>
    public let tagRegistry: Registry<TagDefinition>

    public init(enchantmentRegistry: Registry<Enchantment>, tagRegistry: Registry<TagDefinition>) {
        self.enchantmentRegistry = enchantmentRegistry
        self.tagRegistry = tagRegistry
    }
}

public extension DataPack {
    var lootEnchantmentResources: LootEnchantmentResources {
        LootEnchantmentResources(
            enchantmentRegistry: self.enchantmentRegistry,
            tagRegistry: self.tagRegistry
        )
    }
}
