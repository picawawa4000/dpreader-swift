import Foundation

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
    }
}

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
