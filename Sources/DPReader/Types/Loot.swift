/// Loot table implementations.
/// Mostly ChatGPT'd spaghetti code.

public final class LootTable: Codable {
    let pools: [LootPool]
    let randomSequenceLocation: String
}

public final class LootPool: Codable {
    let rolls: LootNumberProvider
    let bonusRolls: LootNumberProvider
    let entries: [LootEntry]

    public init(rolls: LootNumberProvider, bonusRolls: LootNumberProvider, entries: [LootEntry]) {
        self.rolls = rolls
        self.bonusRolls = bonusRolls
        self.entries = entries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rolls = try c.decode(LootNumberProviderInitializer.self, forKey: .rolls).value
        if (c.contains(.bonusRolls)) {
            self.bonusRolls = try c.decode(LootNumberProviderInitializer.self, forKey: .bonusRolls).value
        } else {
            self.bonusRolls = ConstantLootNumberProvider(value: 0.0)
        }
        var arr = try c.nestedUnkeyedContainer(forKey: .entries)
        var entries: [LootEntry] = []
        while !arr.isAtEnd {
            let box = try arr.decode(LootEntryInitializer.self)
            entries.append(box.value)
        }
        self.entries = entries
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LootNumberProviderInitializer(rolls), forKey: .rolls)
        try c.encode(LootNumberProviderInitializer(bonusRolls), forKey: .bonusRolls)
        var arr = c.nestedUnkeyedContainer(forKey: .entries)
        for entry in entries {
            try arr.encode(LootEntryInitializer(entry))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rolls, bonusRolls = "bonus_rolls", entries
    }
}

public protocol LootEntry: Codable {
    
}

private enum LootEntryTypeKey: String, CodingKey {
    case type
}

public struct LootEntryInitializer: Codable {
    let value: LootEntry

    public init(_ entry: LootEntry) { self.value = entry }

    public init(from decoder: Decoder) throws {
        self.value = try decodeLootEntry(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeLootEntry(value, to: encoder)
    }
}

func decodeLootEntry(from decoder: Decoder) throws -> LootEntry {
    let container = try decoder.container(keyedBy: LootEntryTypeKey.self)
    let type = try addDefaultNamespace(container.decode(String.self, forKey: .type))
    switch type {
    case "minecraft:item":
        return try ItemEntry(from: decoder)
    case "minecraft:loot_table":
        return try LootTableEntry(from: decoder)
    case "minecraft:dynamic":
        return try DynamicEntry(from: decoder)
    case "minecraft:empty":
        return try EmptyEntry(from: decoder)
    case "minecraft:tag":
        return try TagEntry(from: decoder)
    case "minecraft:group":
        return try GroupEntry(from: decoder)
    case "minecraft:alternatives":
        return try AlternativesEntry(from: decoder)
    case "minecraft:sequence":
        return try SequenceEntry(from: decoder)
    default:
        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown LootEntry type: \(type)")
    }
}

func encodeLootEntry(_ entry: LootEntry, to encoder: Encoder) throws {
    switch entry {
    case let e as ItemEntry: try e.encode(to: encoder)
    case let e as LootTableEntry: try e.encode(to: encoder)
    case let e as DynamicEntry: try e.encode(to: encoder)
    case let e as EmptyEntry: try e.encode(to: encoder)
    case let e as TagEntry: try e.encode(to: encoder)
    case let e as GroupEntry: try e.encode(to: encoder)
    case let e as AlternativesEntry: try e.encode(to: encoder)
    case let e as SequenceEntry: try e.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported LootEntry type")
        throw EncodingError.invalidValue(entry, context)
    }
}

public class SingletonLootEntry: LootEntry {
    // let conditions: [Predicate]
    // let functions: [ItemModifier]
    let weight: Int
    let quality: Int

    public init(weight: Int = 1, quality: Int = 0) {
        self.weight = weight
        self.quality = quality
    }
}

public final class ItemEntry: SingletonLootEntry {
    let name: String

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    public init(name: String) { self.name = name; super.init() }

    public init(name: String, weight: Int, quality: Int) {
        self.name = name
        super.init(weight: weight, quality: quality)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type) // validate presence
        self.name = try c.decode(String.self, forKey: .name)
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:item", forKey: .type)
        try c.encode(name, forKey: .name)
    }
}

public final class LootTableEntry: SingletonLootEntry {
    public enum Value {
        /// TODO: make this a registry key
        case name(String)
        case table(LootTable)
    }

    let value: Value

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(value: Value) { self.value = value; super.init() }

    public init(value: Value, weight: Int, quality: Int) {
        self.value = value
        super.init(weight: weight, quality: quality)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type)
        if let s = try? c.decode(String.self, forKey: .value) {
            self.value = .name(s)
        } else if let t = try? c.decode(LootTable.self, forKey: .value) {
            self.value = .table(t)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "value must be String or LootTable")
        }
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:loot_table", forKey: .type)
        switch value {
        case .name(let s): try c.encode(s, forKey: .value)
        case .table(let t): try c.encode(t, forKey: .value)
        }
    }
}

public final class DynamicEntry: SingletonLootEntry {
    let type: DynamicType

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    public enum DynamicType: String, Codable {
        case shulkerBoxContents = "contents"
        case decoratedPotSherds = "sherds"
    }

    public init(type: DynamicType) { self.type = type; super.init() }

    public init(type: DynamicType, weight: Int, quality: Int) {
        self.type = type
        super.init(weight: weight, quality: quality)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type)
        self.type = try c.decode(DynamicType.self, forKey: .name)
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:dynamic", forKey: .type)
        try c.encode(type, forKey: .name)
    }
}

public final class EmptyEntry: SingletonLootEntry {
    private enum CodingKeys: String, CodingKey { case type }

    public init() { super.init() }

    public override init(weight: Int, quality: Int) {
        super.init(weight: weight, quality: quality)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:empty", forKey: .type)
    }
}

/// TODO: these need to expand into multiple entries when decoded if expand=true
public final class TagEntry: SingletonLootEntry {
    /// TODO: make this a registry key
    let name: String
    let expand: Bool

    private enum CodingKeys: String, CodingKey {
        case type, name, expand
    }

    public init(name: String, expand: Bool) {
        self.name = name
        self.expand = expand
        super.init()
    }

    public init(name: String, expand: Bool, weight: Int, quality: Int) {
        self.name = name
        self.expand = expand
        super.init(weight: weight, quality: quality)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type)
        self.name = try c.decode(String.self, forKey: .name)
        self.expand = try c.decode(Bool.self, forKey: .expand)
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:tag", forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(expand, forKey: .expand)
    }
}

public class CompositeLootEntry: LootEntry {
    let children: [LootEntry]

    public init(children: [LootEntry]) {
        self.children = children
    }

    public required init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .type)
        var arr = try c.nestedUnkeyedContainer(forKey: .children)
        var entries: [LootEntry] = []
        while !arr.isAtEnd {
            let box = try arr.decode(LootEntryInitializer.self)
            entries.append(box.value)
        }
        self.children = entries
    }

    func encode(to encoder: any Encoder, type: String) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var arr = c.nestedUnkeyedContainer(forKey: .children)
        for child in children {
            try arr.encode(LootEntryInitializer(child))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "CompositeLootEntry is abstract and cannot be encoded directly"))
    }

    private enum CodingKeys: String, CodingKey {
        case type, children
    }
}

public final class GroupEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:group")
    }
}

public final class AlternativesEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:alternatives")
    }
}

public final class SequenceEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:sequence")
    }
}

public protocol LootNumberProvider: Codable {
    func getInt(fromContext: LootContext) -> Int
    func getFloat(fromContext: LootContext) -> Float
}

extension LootNumberProvider {
    public func getInt(fromContext context: LootContext) -> Int {
        // This solution only matches Java's for positive numbers,
        // but loot number providers can only provide positive numbers anyways.
        return Int(self.getFloat(fromContext: context).rounded(.toNearestOrAwayFromZero))
    }
}

public final class ConstantLootNumberProvider: LootNumberProvider {
    let value: Float

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(value: Float) { self.value = value }

    public required init(from decoder: Decoder) throws {
        // support bare number
        if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Float.self) {
            self.value = v
            return
        }
        if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Int.self) {
            self.value = Float(v)
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        // allow object with or without type
        if let v = try? c.decode(Float.self, forKey: .value) {
            self.value = v
        } else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Missing value for IntConstant")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:constant", forKey: .type)
        try c.encode(value, forKey: .value)
    }

    public func getFloat(fromContext: LootContext) -> Float {
        return self.value
    }
}

public final class UniformLootNumberProvider: LootNumberProvider {
    let min: any LootNumberProvider
    let max: any LootNumberProvider

    private enum CodingKeys: String, CodingKey { case type, min, max }

    public init(min: LootNumberProvider, max: LootNumberProvider) {
        self.min = min
        self.max = max
    }

    public required init(from decoder: Decoder) throws {
        // if an object without type -> treat as uniform
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.min = try c.decode(LootNumberProviderInitializer.self, forKey: .min).value
        self.max = try c.decode(LootNumberProviderInitializer.self, forKey: .max).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:uniform", forKey: .type)
        try c.encode(LootNumberProviderInitializer(min), forKey: .min)
        try c.encode(LootNumberProviderInitializer(max), forKey: .max)
    }

    public func getFloat(fromContext context: LootContext) -> Float {
        let min = self.min.getFloat(fromContext: context)
        let max = self.max.getFloat(fromContext: context)
        if min >= max { return min }
        return context.random.nextFloat() * (max - min) + min
    }

    public func getInt(fromContext context: LootContext) -> Int {
        let min = self.min.getInt(fromContext: context)
        let max = self.max.getInt(fromContext: context)
        if min >= max { return min }
        return Int(context.random.next(bound: UInt32(max - min + 1))) + min
    }
}

public final class BinomialLootNumberProvider: LootNumberProvider {
    let n: any LootNumberProvider
    let p: any LootNumberProvider

    private enum CodingKeys: String, CodingKey { case type, n, p }

    public init(n: any LootNumberProvider, p: any LootNumberProvider) {
        self.n = n
        self.p = p
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.n = try c.decode(LootNumberProviderInitializer.self, forKey: .n).value
        self.p = try c.decode(LootNumberProviderInitializer.self, forKey: .p).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("minecraft:binomial", forKey: .type)
        try c.encode(LootNumberProviderInitializer(n), forKey: .n)
        try c.encode(LootNumberProviderInitializer(p), forKey: .p)
    }

    public func getInt(fromContext context: LootContext) -> Int {
        // The obvious way to do this calculation, but it's how the game does it.
        let numTrials = self.n.getInt(fromContext: context)
        let successChance = self.p.getFloat(fromContext: context)
        var successfulTrials = 0;
        for _ in 0..<numTrials { if context.random.nextFloat() < successChance { successfulTrials += 1 } }
        return successfulTrials;
    }

    public func getFloat(fromContext context: LootContext) -> Float {
        return Float(self.getInt(fromContext: context))
    }
}

// score and storage unimplemented here because they don't appear in vanilla
// and can't be sampled without more knowledge of the world than we have
// same with enchantment_level, except that one does appear in vanilla
// but not in worldgen-related loot tables so we still don't care
/// TODO: (low priority) implement score, storage, and enchantment_level such
/// that the user can supply relevant numbers through `LootContext`

public struct LootNumberProviderInitializer: Codable {
    public let value: any LootNumberProvider

    public init(_ v: LootNumberProvider) { self.value = v }

    public init(from decoder: Decoder) throws {
        self.value = try decodeLootNumberProvider(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeLootNumberProvider(value, to: encoder)
    }
}

private enum ProviderTypeKey: String, CodingKey {
    case type
}

func decodeLootNumberProvider(from decoder: Decoder) throws -> LootNumberProvider {
    // bare number -> constant
    if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Float.self) {
        return ConstantLootNumberProvider(value: v)
    }
    if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Int.self) {
        return ConstantLootNumberProvider(value: Float(v))
    }

    let container = try decoder.container(keyedBy: ProviderTypeKey.self)
    if container.allKeys.first(where: { $0 == .type }) == nil {
        // object without type -> uniform
        return try ConstantLootNumberProvider(from: decoder)
    }

    let typeRaw = try container.decode(String.self, forKey: .type)
    let type = addDefaultNamespace(typeRaw)
    switch type {
    case "minecraft:constant":
        return try ConstantLootNumberProvider(from: decoder)
    case "minecraft:uniform":
        return try UniformLootNumberProvider(from: decoder)
    case "minecraft:binomial":
        return try BinomialLootNumberProvider(from: decoder)
    default:
        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown FloatProvider type: \(type)")
    }
}

func encodeLootNumberProvider(_ provider: LootNumberProvider, to encoder: Encoder) throws {
    switch provider {
    case let p as ConstantLootNumberProvider: try p.encode(to: encoder)
    case let p as UniformLootNumberProvider: try p.encode(to: encoder)
    case let p as BinomialLootNumberProvider: try p.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported FloatProvider type")
        throw EncodingError.invalidValue(provider, context)
    }
}

public final class LootContext {
    public var random: any Random

    public init(random: any Random) {
        self.random = random
    }
}

public struct ItemStack {
    let itemName: String
    let count: Int
    /// TODO: this design is probably going to turn out to be not helpful but it works for now
    let components: [String: String]?

    public init(itemName: String, count: Int) {
        self.itemName = itemName
        self.count = count
        self.components = nil
    }

    public init(itemName: String, count: Int, components: [String: String]) {
        self.itemName = itemName
        self.count = count
        self.components = components
    }
}

public protocol ItemModifier: Codable {
    
}

public final class ApplyBonusItemModifier: ItemModifier {}
public final class CopyComponentsItemModifier: ItemModifier {}
public final class CopyCustomDataItemModifier: ItemModifier {}
public final class CopyNameItemModifier: ItemModifier {}
public final class CopyStateItemModifier: ItemModifier {}
public final class DiscardItemModifier: ItemModifier {}
public final class EnchantRandomlyItemModifier: ItemModifier {}
public final class EnchantWithLevelsItemModifier: ItemModifier {}
public final class EnchantedCountIncreaseItemModifier: ItemModifier {}
public final class ExplorationMapItemModifier: ItemModifier {}
public final class ExplosionDecayItemModifier: ItemModifier {}
public final class FillPlayerHeadItemModifier: ItemModifier {}
public final class FilteredItemModifier: ItemModifier {}
public final class FurnaceSmeltItemModifier: ItemModifier {}
public final class LimitCountItemModifier: ItemModifier {}
public final class ModifyComponentsItemModifier: ItemModifier {}
public final class ReferenceItemModifier: ItemModifier {}
public final class SequenceItemModifier: ItemModifier {}
public final class SetAttributesItemModifier: ItemModifier {}
public final class SetBannerPatternItemModifier: ItemModifier {}
public final class SetBookCoverItemModifier: ItemModifier {}
public final class SetComponentsItemModifier: ItemModifier {}
public final class SetContentsItemModifier: ItemModifier {}
public final class SetCountItemModifier: ItemModifier {}
public final class SetCustomDataItemModifier: ItemModifier {}
public final class SetCustomModelDataItemModifier: ItemModifier {}
public final class SetDamageItemModifier: ItemModifier {}
public final class SetEnchantmentsItemModifier: ItemModifier {}
public final class SetFireworksItemModifier: ItemModifier {}
public final class SetFireworkExplosionItemModifier: ItemModifier {}
public final class SetInstrumentItemModifier: ItemModifier {}
public final class SetItemItemModifier: ItemModifier {}
public final class SetLootTableItemModifier: ItemModifier {}
public final class SetLoreItemModifier: ItemModifier {}
public final class SetNameItemModifier: ItemModifier {}
public final class SetOminousBottleAmplifierItemModifier: ItemModifier {}
public final class SetPotionItemModifier: ItemModifier {}
public final class SetStewEffectItemModifier: ItemModifier {}
public final class SetWritableBookPagesItemModifier: ItemModifier {}
public final class SetWrittenBookPagesItemModifier: ItemModifier {}
public final class ToggleTooltipsItemModifier: ItemModifier {}