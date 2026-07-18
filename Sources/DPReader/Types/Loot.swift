/// Loot table decoding and world-generation evaluation.

/// A decoded loot table.
public final class LootTable: Codable {
    let type: String?
    let pools: [LootPool]
    let functions: [ItemModifier]
    let randomSequenceLocation: String?

    public init(type: String? = nil, pools: [LootPool], functions: [ItemModifier] = [], randomSequenceLocation: String? = nil) {
        self.type = type
        self.pools = pools
        self.functions = functions
        self.randomSequenceLocation = randomSequenceLocation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.type = try c.decodeIfPresent(String.self, forKey: key("type"))
        self.pools = try c.decode([LootPool].self, forKey: key("pools"))
        self.functions = try decodeItemModifiers(from: c, forKey: "functions")
        self.randomSequenceLocation = try c.decodeIfPresent(String.self, forKey: key("random_sequence"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encodeIfPresent(type, forKey: key("type"))
        try c.encode(pools, forKey: key("pools"))
        try encodeItemModifiers(functions, to: &c, forKey: "functions")
        try c.encodeIfPresent(randomSequenceLocation, forKey: key("random_sequence"))
    }

    /// Generates the items produced by this table.
    public func generateLoot(
        withContext context: LootContext,
        resolvingTables resolveTable: LootTableResolver? = nil
    ) throws -> [ItemStack] {
        let state = LootGenerationState(resolveTable: resolveTable)
        return try generateLoot(withContext: context, state: state, activeKey: .inline(ObjectIdentifier(self)))
    }

    fileprivate func generateLoot(
        withContext context: LootContext,
        state: LootGenerationState,
        activeKey: ActiveLootTableKey
    ) throws -> [ItemStack] {
        guard state.activeTables.insert(activeKey).inserted else {
            throw LootEvaluationError.invalidData("Detected recursive loot table reference")
        }
        defer {
            state.activeTables.remove(activeKey)
        }

        var generated: [ItemStack] = []
        for pool in pools {
            generated += try pool.generateLoot(withContext: context, state: state)
        }
        return try applyingModifiers(functions, to: generated, withContext: context)
    }
}

/// A single loot pool inside a loot table.
public final class LootPool: Codable {
    let rolls: LootNumberProvider
    let bonusRolls: LootNumberProvider
    let entries: [LootEntry]
    public let conditions: [LootCondition]
    let functions: [ItemModifier]

    public init(
        rolls: LootNumberProvider,
        bonusRolls: LootNumberProvider,
        entries: [LootEntry],
        conditions: [LootCondition] = [],
        functions: [ItemModifier] = []
    ) {
        self.rolls = rolls
        self.bonusRolls = bonusRolls
        self.entries = entries
        self.conditions = conditions
        self.functions = functions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.rolls = try c.decode(LootNumberProviderInitializer.self, forKey: key("rolls")).value
        if c.contains(key("bonus_rolls")) {
            self.bonusRolls = try c.decode(LootNumberProviderInitializer.self, forKey: key("bonus_rolls")).value
        } else {
            self.bonusRolls = ConstantLootNumberProvider(value: 0.0)
        }
        self.entries = try c.decode([LootEntryInitializer].self, forKey: key("entries")).map(\.value)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.functions = try decodeItemModifiers(from: c, forKey: "functions")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(LootNumberProviderInitializer(rolls), forKey: key("rolls"))
        try c.encode(LootNumberProviderInitializer(bonusRolls), forKey: key("bonus_rolls"))
        try c.encode(entries.map(LootEntryInitializer.init), forKey: key("entries"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try encodeItemModifiers(functions, to: &c, forKey: "functions")
    }

    fileprivate func generateLoot(withContext context: LootContext, state: LootGenerationState) throws -> [ItemStack] {
        guard try allConditionsPass(conditions, withContext: context) else {
            return []
        }

        let rollCount = max(0, rolls.getInt(fromContext: context))
        var generated: [ItemStack] = []
        for _ in 0..<rollCount {
            let choices = try entries.flatMap { try expandLootEntry($0, withContext: context, state: state).choices }
            guard let selectedChoice = selectLootChoice(from: choices, withContext: context) else {
                continue
            }
            let entryStacks = try selectedChoice.generate(context, state)
            generated += try applyingModifiers(functions, to: entryStacks, withContext: context)
        }
        return generated
    }
}

/// Resolves named loot table references during evaluation.
public typealias LootTableResolver = (String) throws -> LootTable

private enum ActiveLootTableKey: Hashable {
    case inline(ObjectIdentifier)
    case named(String)
}

private final class LootGenerationState {
    let resolveTable: LootTableResolver?
    var activeTables: Set<ActiveLootTableKey> = []

    init(resolveTable: LootTableResolver?) {
        self.resolveTable = resolveTable
    }
}

private struct ExpandedLootChoice {
    let weight: Int
    let generate: (LootContext, LootGenerationState) throws -> [ItemStack]
}

private struct LootEntryExpansion {
    let didExpand: Bool
    let choices: [ExpandedLootChoice]
}

/// A decoded loot entry.
public protocol LootEntry: Codable {
}

private enum LootEntryTypeKey: String, CodingKey {
    case type
}

/// Type-erased wrapper used to code heterogeneous loot entries.
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

/// Decodes a concrete loot entry from its `type`.
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

/// Encodes a concrete loot entry using its runtime type.
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

/// Base implementation shared by weighted loot entries.
public class SingletonLootEntry: LootEntry {
    public let conditions: [LootCondition]
    let functions: [ItemModifier]
    let weight: Int
    let quality: Int

    public init(weight: Int = 1, quality: Int = 0, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        self.conditions = conditions
        self.functions = functions
        self.weight = weight
        self.quality = quality
    }

    public required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: container, forKey: "conditions")
        self.functions = try decodeItemModifiers(from: container, forKey: "functions")
        if container.contains(key("weight")) {
            self.weight = try container.decode(Int.self, forKey: key("weight"))
        } else {
            self.weight = 1
        }
        if container.contains(key("quality")) {
            self.quality = try container.decode(Int.self, forKey: key("quality"))
        } else {
            self.quality = 0
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try encodeItemModifiers(functions, to: &c, forKey: "functions")
        try c.encode(weight, forKey: key("weight"))
        try c.encode(quality, forKey: key("quality"))
    }
}

/// A loot entry that directly yields one item.
public final class ItemEntry: SingletonLootEntry {
    let name: String

    public init(name: String, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        self.name = name
        super.init(conditions: conditions, functions: functions)
    }

    public init(
        name: String,
        weight: Int,
        quality: Int,
        conditions: [LootCondition] = [],
        functions: [ItemModifier] = []
    ) {
        self.name = name
        super.init(weight: weight, quality: quality, conditions: conditions, functions: functions)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
        self.name = try c.decode(String.self, forKey: key("name"))
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:item", forKey: key("type"))
        try c.encode(name, forKey: key("name"))
    }
}

/// A loot entry that evaluates another loot table.
public final class LootTableEntry: SingletonLootEntry {
    public enum Value {
        case name(String)
        case table(LootTable)
    }

    let value: Value

    public init(value: Value, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        self.value = value
        super.init(conditions: conditions, functions: functions)
    }

    public init(
        value: Value,
        weight: Int,
        quality: Int,
        conditions: [LootCondition] = [],
        functions: [ItemModifier] = []
    ) {
        self.value = value
        super.init(weight: weight, quality: quality, conditions: conditions, functions: functions)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
        if let s = try? c.decode(String.self, forKey: key("value")) {
            self.value = .name(s)
        } else if let t = try? c.decode(LootTable.self, forKey: key("value")) {
            self.value = .table(t)
        } else {
            throw DecodingError.dataCorruptedError(forKey: key("value"), in: c, debugDescription: "value must be String or LootTable")
        }
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:loot_table", forKey: key("type"))
        switch value {
        case .name(let s): try c.encode(s, forKey: key("value"))
        case .table(let t): try c.encode(t, forKey: key("value"))
        }
    }
}

/// A loot entry whose contents are supplied by runtime game state.
public final class DynamicEntry: SingletonLootEntry {
    let type: DynamicType

    public enum DynamicType: String, Codable {
        case shulkerBoxContents = "contents"
        case decoratedPotSherds = "sherds"
    }

    public init(type: DynamicType, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        self.type = type
        super.init(conditions: conditions, functions: functions)
    }

    public init(
        type: DynamicType,
        weight: Int,
        quality: Int,
        conditions: [LootCondition] = [],
        functions: [ItemModifier] = []
    ) {
        self.type = type
        super.init(weight: weight, quality: quality, conditions: conditions, functions: functions)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
        self.type = try c.decode(DynamicType.self, forKey: key("name"))
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:dynamic", forKey: key("type"))
        try c.encode(type, forKey: key("name"))
    }
}

/// A loot entry that always contributes no items.
public final class EmptyEntry: SingletonLootEntry {
    public init(conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        super.init(conditions: conditions, functions: functions)
    }

    public override init(weight: Int, quality: Int, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        super.init(weight: weight, quality: quality, conditions: conditions, functions: functions)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:empty", forKey: key("type"))
    }
}

/// A loot entry that references an item tag.
/// TODO: these need to expand into multiple entries when decoded if expand=true
public final class TagEntry: SingletonLootEntry {
    let name: String
    let expand: Bool

    public init(name: String, expand: Bool, conditions: [LootCondition] = [], functions: [ItemModifier] = []) {
        self.name = name
        self.expand = expand
        super.init(conditions: conditions, functions: functions)
    }

    public init(
        name: String,
        expand: Bool,
        weight: Int,
        quality: Int,
        conditions: [LootCondition] = [],
        functions: [ItemModifier] = []
    ) {
        self.name = name
        self.expand = expand
        super.init(weight: weight, quality: quality, conditions: conditions, functions: functions)
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
        self.name = try c.decode(String.self, forKey: key("name"))
        self.expand = try c.decode(Bool.self, forKey: key("expand"))
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:tag", forKey: key("type"))
        try c.encode(name, forKey: key("name"))
        try c.encode(expand, forKey: key("expand"))
    }
}

/// Base implementation for composite loot entries.
public class CompositeLootEntry: LootEntry {
    public let conditions: [LootCondition]
    let children: [LootEntry]

    public init(children: [LootEntry], conditions: [LootCondition] = []) {
        self.conditions = conditions
        self.children = children
    }

    public required init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try c.decode(String.self, forKey: key("type"))
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.children = try c.decode([LootEntryInitializer].self, forKey: key("children")).map(\.value)
    }

    func encode(to encoder: any Encoder, type: String) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(type, forKey: key("type"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(children.map(LootEntryInitializer.init), forKey: key("children"))
    }

    public func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "CompositeLootEntry is abstract and cannot be encoded directly"))
    }
}

/// Evaluates all children as one combined set of choices.
public final class GroupEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:group")
    }
}

/// Evaluates the first child whose conditions pass.
public final class AlternativesEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:alternatives")
    }
}

/// Evaluates children in order until one fails to expand.
public final class SequenceEntry: CompositeLootEntry {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:sequence")
    }
}

/// A numeric provider used by loot tables.
public protocol LootNumberProvider: Codable {
    func getInt(fromContext: LootContext) -> Int
    func getFloat(fromContext: LootContext) -> Float
}

extension LootNumberProvider {
    public func getInt(fromContext context: LootContext) -> Int {
        return Int(self.getFloat(fromContext: context).rounded(.toNearestOrAwayFromZero))
    }
}

/// A provider that always returns the same value.
public final class ConstantLootNumberProvider: LootNumberProvider {
    let value: Float

    public init(value: Float) { self.value = value }

    public required init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Float.self) {
            self.value = v
            return
        }
        if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Int.self) {
            self.value = Float(v)
            return
        }

        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        if let v = try? c.decode(Float.self, forKey: key("value")) {
            self.value = v
        } else {
            throw DecodingError.dataCorruptedError(forKey: key("value"), in: c, debugDescription: "Missing value for constant provider")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:constant", forKey: key("type"))
        try c.encode(value, forKey: key("value"))
    }

    public func getFloat(fromContext: LootContext) -> Float {
        return self.value
    }
}

/// A provider that samples uniformly between two bounds.
public final class UniformLootNumberProvider: LootNumberProvider {
    let min: any LootNumberProvider
    let max: any LootNumberProvider

    public init(min: LootNumberProvider, max: LootNumberProvider) {
        self.min = min
        self.max = max
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.min = try c.decode(LootNumberProviderInitializer.self, forKey: key("min")).value
        self.max = try c.decode(LootNumberProviderInitializer.self, forKey: key("max")).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:uniform", forKey: key("type"))
        try c.encode(LootNumberProviderInitializer(min), forKey: key("min"))
        try c.encode(LootNumberProviderInitializer(max), forKey: key("max"))
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

/// A provider that samples a binomial distribution.
public final class BinomialLootNumberProvider: LootNumberProvider {
    let n: any LootNumberProvider
    let p: any LootNumberProvider

    public init(n: any LootNumberProvider, p: any LootNumberProvider) {
        self.n = n
        self.p = p
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.n = try c.decode(LootNumberProviderInitializer.self, forKey: key("n")).value
        self.p = try c.decode(LootNumberProviderInitializer.self, forKey: key("p")).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:binomial", forKey: key("type"))
        try c.encode(LootNumberProviderInitializer(n), forKey: key("n"))
        try c.encode(LootNumberProviderInitializer(p), forKey: key("p"))
    }

    public func getInt(fromContext context: LootContext) -> Int {
        let numTrials = self.n.getInt(fromContext: context)
        let successChance = self.p.getFloat(fromContext: context)
        var successfulTrials = 0
        for _ in 0..<numTrials {
            if context.random.nextFloat() < successChance {
                successfulTrials += 1
            }
        }
        return successfulTrials
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

/// Type-erased wrapper used to code heterogeneous number providers.
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

/// Decodes a concrete loot number provider from its `type`.
func decodeLootNumberProvider(from decoder: Decoder) throws -> LootNumberProvider {
    if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Float.self) {
        return ConstantLootNumberProvider(value: v)
    }
    if let single = try? decoder.singleValueContainer(), let v = try? single.decode(Int.self) {
        return ConstantLootNumberProvider(value: Float(v))
    }

    let container = try decoder.container(keyedBy: ProviderTypeKey.self)
    if container.allKeys.first(where: { $0 == .type }) == nil {
        return try UniformLootNumberProvider(from: decoder)
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

/// Encodes a concrete loot number provider using its runtime type.
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

/// A lightweight JSON value container used by loot payloads.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Int64.self) {
                self = .integer(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var object: [String: JSONValue] = [:]
        for codingKey in container.allKeys {
            object[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        self = .object(object)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (k, v) in object {
                try container.encode(v, forKey: key(k))
            }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        switch self {
        case .array(let value): return value
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let value): return value
        default: return nil
        }
    }
}

/// Errors raised while decoding or evaluating loot.
public enum LootEvaluationError: Error, Sendable {
    case unsupported(String)
    case missingContext(String)
    case invalidData(String)
}

/// Evaluation context shared across a loot generation run.
public final class LootContext {
    public var random: any Random
    /// Datapack registries needed for enchantment-driven loot behavior.
    public let enchantmentResources: LootEnchantmentResources?

    public init(random: any Random, enchantmentResources: LootEnchantmentResources? = nil) {
        self.random = random
        self.enchantmentResources = enchantmentResources
    }
}

/// A generated item stack plus its item components.
public struct ItemStack {
    let itemName: String
    let count: Int
    let components: [String: JSONValue]

    public init(itemName: String, count: Int, components: [String: JSONValue] = [:]) {
        self.itemName = itemName
        self.count = count
        self.components = components
    }

    func withItemName(_ newItemName: String) -> ItemStack {
        ItemStack(itemName: newItemName, count: count, components: components)
    }

    func withCount(_ newCount: Int) -> ItemStack {
        ItemStack(itemName: itemName, count: newCount, components: components)
    }

    func withComponents(_ newComponents: [String: JSONValue]) -> ItemStack {
        ItemStack(itemName: itemName, count: count, components: newComponents)
    }

    func settingComponent(_ key: String, _ value: JSONValue?) -> ItemStack {
        var newComponents = components
        newComponents[key] = value
        return withComponents(newComponents)
    }

    func mergingComponents(_ extraComponents: [String: JSONValue]) -> ItemStack {
        var newComponents = components
        for (key, value) in extraComponents {
            newComponents[key] = value
        }
        return withComponents(newComponents)
    }

    var enchantmentLevels: [String: Int] {
        guard
            case .object(let enchantmentsComponent)? = components["minecraft:enchantments"],
            case .object(let levelsObject)? = enchantmentsComponent["levels"]
        else {
            return [:]
        }

        var levels: [String: Int] = [:]
        for (id, rawLevel) in levelsObject {
            if let level = rawLevel.intValue {
                levels[id] = level
            }
        }
        return levels
    }

    func enchantmentLevel(_ id: String) -> Int {
        enchantmentLevels[addDefaultNamespace(id)] ?? 0
    }

    func settingEnchantments(_ enchantments: [String: Int]) -> ItemStack {
        let normalizedLevels = Dictionary(
            uniqueKeysWithValues: enchantments
                .filter { $0.value > 0 }
                .map { (addDefaultNamespace($0.key), $0.value) }
        )
        let levelObject = normalizedLevels.mapValues { JSONValue.integer(Int64($0)) }
        let component: JSONValue = .object(["levels": .object(levelObject)])
        let targetItemName: String
        switch itemName {
        case "minecraft:book":
            targetItemName = "minecraft:enchanted_book"
        default:
            targetItemName = itemName
        }
        return withItemName(targetItemName).settingComponent("minecraft:enchantments", component)
    }
}

/// A predicate that gates loot evaluation.
public protocol LootCondition: Codable {
    func check(withContext: LootContext) throws -> Bool
}

extension LootCondition {
    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("Loot condition \(String(reflecting: type(of: self))) is not evaluable with the current context")
    }
}

private enum LootConditionTypeKey: String, CodingKey {
    case condition
}

/// Type-erased wrapper used to code heterogeneous loot conditions.
public struct LootConditionInitializer: Codable {
    public let value: LootCondition

    public init(_ value: LootCondition) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        self.value = try decodeLootCondition(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeLootCondition(value, to: encoder)
    }
}

/// Decodes a concrete loot condition from its `condition`.
func decodeLootCondition(from decoder: Decoder) throws -> LootCondition {
    if var array = try? decoder.unkeyedContainer() {
        var terms: [LootCondition] = []
        while !array.isAtEnd {
            terms.append(try array.decode(LootConditionInitializer.self).value)
        }
        return AllOfLootCondition(terms: terms)
    }

    let container = try decoder.container(keyedBy: LootConditionTypeKey.self)
    let type = try addDefaultNamespace(container.decode(String.self, forKey: .condition))
    switch type {
    case "minecraft:inverted":
        return try InvertedLootCondition(from: decoder)
    case "minecraft:any_of":
        return try AnyOfLootCondition(from: decoder)
    case "minecraft:all_of":
        return try AllOfLootCondition(from: decoder)
    case "minecraft:random_chance":
        return try RandomChanceLootCondition(from: decoder)
    case "minecraft:random_chance_with_enchanted_bonus":
        return try RandomChanceWithEnchantedBonusLootCondition(from: decoder)
    case "minecraft:entity_properties":
        return try EntityPropertiesLootCondition(from: decoder)
    case "minecraft:killed_by_player":
        return try KilledByPlayerLootCondition(from: decoder)
    case "minecraft:entity_scores":
        return try EntityScoresLootCondition(from: decoder)
    case "minecraft:block_state_property":
        return try BlockStatePropertyLootCondition(from: decoder)
    case "minecraft:match_tool":
        return try MatchToolLootCondition(from: decoder)
    case "minecraft:table_bonus":
        return try TableBonusLootCondition(from: decoder)
    case "minecraft:survives_explosion":
        return try SurvivesExplosionLootCondition(from: decoder)
    case "minecraft:damage_source_properties":
        return try DamageSourcePropertiesLootCondition(from: decoder)
    case "minecraft:location_check":
        return try LocationCheckLootCondition(from: decoder)
    case "minecraft:weather_check":
        return try WeatherCheckLootCondition(from: decoder)
    case "minecraft:reference":
        return try ReferenceLootCondition(from: decoder)
    case "minecraft:time_check":
        return try TimeCheckLootCondition(from: decoder)
    case "minecraft:value_check":
        return try ValueCheckLootCondition(from: decoder)
    case "minecraft:enchantment_active_check":
        return try EnchantmentActiveCheckLootCondition(from: decoder)
    default:
        throw DecodingError.dataCorruptedError(forKey: .condition, in: container, debugDescription: "Unknown LootCondition type: \(type)")
    }
}

/// Encodes a concrete loot condition using its runtime type.
func encodeLootCondition(_ condition: LootCondition, to encoder: Encoder) throws {
    switch condition {
    case let v as InvertedLootCondition: try v.encode(to: encoder)
    case let v as AnyOfLootCondition: try v.encode(to: encoder)
    case let v as AllOfLootCondition: try v.encode(to: encoder)
    case let v as RandomChanceLootCondition: try v.encode(to: encoder)
    case let v as RandomChanceWithEnchantedBonusLootCondition: try v.encode(to: encoder)
    case let v as EntityPropertiesLootCondition: try v.encode(to: encoder)
    case let v as KilledByPlayerLootCondition: try v.encode(to: encoder)
    case let v as EntityScoresLootCondition: try v.encode(to: encoder)
    case let v as BlockStatePropertyLootCondition: try v.encode(to: encoder)
    case let v as MatchToolLootCondition: try v.encode(to: encoder)
    case let v as TableBonusLootCondition: try v.encode(to: encoder)
    case let v as SurvivesExplosionLootCondition: try v.encode(to: encoder)
    case let v as DamageSourcePropertiesLootCondition: try v.encode(to: encoder)
    case let v as LocationCheckLootCondition: try v.encode(to: encoder)
    case let v as WeatherCheckLootCondition: try v.encode(to: encoder)
    case let v as ReferenceLootCondition: try v.encode(to: encoder)
    case let v as TimeCheckLootCondition: try v.encode(to: encoder)
    case let v as ValueCheckLootCondition: try v.encode(to: encoder)
    case let v as EnchantmentActiveCheckLootCondition: try v.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported LootCondition type")
        throw EncodingError.invalidValue(condition, context)
    }
}

public final class InvertedLootCondition: LootCondition {
    let term: LootCondition

    public init(term: LootCondition) {
        self.term = term
    }

    public convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.init(term: try c.decode(LootConditionInitializer.self, forKey: key("term")).value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:inverted", forKey: key("condition"))
        try c.encode(LootConditionInitializer(term), forKey: key("term"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        return try !term.check(withContext: context)
    }
}

public class AlternativeLootCondition: LootCondition {
    let terms: [LootCondition]

    public init(terms: [LootCondition]) {
        self.terms = terms
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.terms = try c.decode([LootConditionInitializer].self, forKey: key("terms")).map(\.value)
    }

    func encode(to encoder: Encoder, type: String) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(type, forKey: key("condition"))
        try c.encode(terms.map(LootConditionInitializer.init), forKey: key("terms"))
    }

    public func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AlternativeLootCondition is abstract"))
    }
}

public final class AnyOfLootCondition: AlternativeLootCondition {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:any_of")
    }

    public func check(withContext context: LootContext) throws -> Bool {
        for term in terms {
            if try term.check(withContext: context) {
                return true
            }
        }
        return false
    }
}

public final class AllOfLootCondition: AlternativeLootCondition {
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder, type: "minecraft:all_of")
    }

    public func check(withContext context: LootContext) throws -> Bool {
        for term in terms {
            if try !term.check(withContext: context) {
                return false
            }
        }
        return true
    }
}

public final class RandomChanceLootCondition: LootCondition {
    let chance: LootNumberProvider

    public init(chance: LootNumberProvider) {
        self.chance = chance
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.chance = try c.decode(LootNumberProviderInitializer.self, forKey: key("chance")).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:random_chance", forKey: key("condition"))
        try c.encode(LootNumberProviderInitializer(chance), forKey: key("chance"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        return context.random.nextFloat() < chance.getFloat(fromContext: context)
    }
}

public final class RandomChanceWithEnchantedBonusLootCondition: LootCondition {
    let unenchantedChance: Float
    let enchantedChance: JSONValue
    let enchantment: String

    public init(unenchantedChance: Float, enchantedChance: JSONValue, enchantment: String) {
        self.unenchantedChance = unenchantedChance
        self.enchantedChance = enchantedChance
        self.enchantment = enchantment
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.unenchantedChance = try c.decode(Float.self, forKey: key("unenchanted_chance"))
        self.enchantedChance = try c.decode(JSONValue.self, forKey: key("enchanted_chance"))
        self.enchantment = try c.decode(String.self, forKey: key("enchantment"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:random_chance_with_enchanted_bonus", forKey: key("condition"))
        try c.encode(unenchantedChance, forKey: key("unenchanted_chance"))
        try c.encode(enchantedChance, forKey: key("enchanted_chance"))
        try c.encode(enchantment, forKey: key("enchantment"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("random_chance_with_enchanted_bonus is not needed for world-generation loot")
    }
}

public final class EntityPropertiesLootCondition: LootCondition {
    let predicate: JSONValue?
    let entity: String

    public init(predicate: JSONValue?, entity: String) {
        self.predicate = predicate
        self.entity = entity
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.predicate = try c.decodeIfPresent(JSONValue.self, forKey: key("predicate"))
        self.entity = try c.decode(String.self, forKey: key("entity"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:entity_properties", forKey: key("condition"))
        try c.encodeIfPresent(predicate, forKey: key("predicate"))
        try c.encode(entity, forKey: key("entity"))
    }
}

public final class KilledByPlayerLootCondition: LootCondition {
    public init() {}

    public required init(from decoder: Decoder) throws {}

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:killed_by_player", forKey: key("condition"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("killed_by_player is not needed for world-generation loot")
    }
}

public final class EntityScoresLootCondition: LootCondition {
    let scores: [String: JSONValue]
    let entity: String

    public init(scores: [String: JSONValue], entity: String) {
        self.scores = scores
        self.entity = entity
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.scores = try c.decode([String: JSONValue].self, forKey: key("scores"))
        self.entity = try c.decode(String.self, forKey: key("entity"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:entity_scores", forKey: key("condition"))
        try c.encode(scores, forKey: key("scores"))
        try c.encode(entity, forKey: key("entity"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("entity_scores is not needed for world-generation loot")
    }
}

public final class BlockStatePropertyLootCondition: LootCondition {
    let block: String
    let properties: JSONValue?

    public init(block: String, properties: JSONValue?) {
        self.block = block
        self.properties = properties
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.block = try c.decode(String.self, forKey: key("block"))
        self.properties = try c.decodeIfPresent(JSONValue.self, forKey: key("properties"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:block_state_property", forKey: key("condition"))
        try c.encode(block, forKey: key("block"))
        try c.encodeIfPresent(properties, forKey: key("properties"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("block_state_property is not needed for world-generation loot")
    }
}

public final class MatchToolLootCondition: LootCondition {
    let predicate: JSONValue?

    public init(predicate: JSONValue?) {
        self.predicate = predicate
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.predicate = try c.decodeIfPresent(JSONValue.self, forKey: key("predicate"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:match_tool", forKey: key("condition"))
        try c.encodeIfPresent(predicate, forKey: key("predicate"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("match_tool is not needed for world-generation loot")
    }
}

public final class TableBonusLootCondition: LootCondition {
    let enchantment: String
    let chances: [Float]

    public init(enchantment: String, chances: [Float]) {
        self.enchantment = enchantment
        self.chances = chances
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.enchantment = try c.decode(String.self, forKey: key("enchantment"))
        self.chances = try c.decode([Float].self, forKey: key("chances"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:table_bonus", forKey: key("condition"))
        try c.encode(enchantment, forKey: key("enchantment"))
        try c.encode(chances, forKey: key("chances"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("table_bonus is not needed for world-generation loot")
    }
}

public final class SurvivesExplosionLootCondition: LootCondition {
    public init() {}

    public required init(from decoder: Decoder) throws {}

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:survives_explosion", forKey: key("condition"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("survives_explosion is not needed for world-generation loot")
    }
}

public final class DamageSourcePropertiesLootCondition: LootCondition {
    let predicate: JSONValue?

    public init(predicate: JSONValue?) {
        self.predicate = predicate
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.predicate = try c.decodeIfPresent(JSONValue.self, forKey: key("predicate"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:damage_source_properties", forKey: key("condition"))
        try c.encodeIfPresent(predicate, forKey: key("predicate"))
    }
}

public final class LocationCheckLootCondition: LootCondition {
    let predicate: JSONValue?
    let offsetX: Int
    let offsetY: Int
    let offsetZ: Int

    public init(predicate: JSONValue?, offsetX: Int = 0, offsetY: Int = 0, offsetZ: Int = 0) {
        self.predicate = predicate
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.offsetZ = offsetZ
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.predicate = try c.decodeIfPresent(JSONValue.self, forKey: key("predicate"))
        self.offsetX = try c.decodeIfPresent(Int.self, forKey: key("offsetX")) ?? 0
        self.offsetY = try c.decodeIfPresent(Int.self, forKey: key("offsetY")) ?? 0
        self.offsetZ = try c.decodeIfPresent(Int.self, forKey: key("offsetZ")) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:location_check", forKey: key("condition"))
        try c.encodeIfPresent(predicate, forKey: key("predicate"))
        if offsetX != 0 { try c.encode(offsetX, forKey: key("offsetX")) }
        if offsetY != 0 { try c.encode(offsetY, forKey: key("offsetY")) }
        if offsetZ != 0 { try c.encode(offsetZ, forKey: key("offsetZ")) }
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("location_check is not needed for world-generation loot")
    }
}

public final class WeatherCheckLootCondition: LootCondition {
    let raining: Bool?
    let thundering: Bool?

    public init(raining: Bool?, thundering: Bool?) {
        self.raining = raining
        self.thundering = thundering
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.raining = try c.decodeIfPresent(Bool.self, forKey: key("raining"))
        self.thundering = try c.decodeIfPresent(Bool.self, forKey: key("thundering"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:weather_check", forKey: key("condition"))
        try c.encodeIfPresent(raining, forKey: key("raining"))
        try c.encodeIfPresent(thundering, forKey: key("thundering"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("weather_check is not needed for world-generation loot")
    }
}

public final class ReferenceLootCondition: LootCondition {
    let name: String

    public init(name: String) {
        self.name = name
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.name = try c.decode(String.self, forKey: key("name"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:reference", forKey: key("condition"))
        try c.encode(name, forKey: key("name"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("reference conditions are not needed for world-generation loot")
    }
}

public final class TimeCheckLootCondition: LootCondition {
    let period: Int64?
    let value: JSONValue

    public init(period: Int64?, value: JSONValue) {
        self.period = period
        self.value = value
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.period = try c.decodeIfPresent(Int64.self, forKey: key("period"))
        self.value = try c.decode(JSONValue.self, forKey: key("value"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:time_check", forKey: key("condition"))
        try c.encodeIfPresent(period, forKey: key("period"))
        try c.encode(value, forKey: key("value"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("time_check is not needed for world-generation loot")
    }
}

public final class ValueCheckLootCondition: LootCondition {
    let value: LootNumberProvider
    let range: JSONValue

    public init(value: LootNumberProvider, range: JSONValue) {
        self.value = value
        self.range = range
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.value = try c.decode(LootNumberProviderInitializer.self, forKey: key("value")).value
        self.range = try c.decode(JSONValue.self, forKey: key("range"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:value_check", forKey: key("condition"))
        try c.encode(LootNumberProviderInitializer(value), forKey: key("value"))
        try c.encode(range, forKey: key("range"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        return checkIntRange(value.getInt(fromContext: context), against: range)
    }
}

public final class EnchantmentActiveCheckLootCondition: LootCondition {
    let active: Bool

    public init(active: Bool) {
        self.active = active
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.active = try c.decode(Bool.self, forKey: key("active"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:enchantment_active_check", forKey: key("condition"))
        try c.encode(active, forKey: key("active"))
    }

    public func check(withContext context: LootContext) throws -> Bool {
        throw LootEvaluationError.unsupported("enchantment_active_check is not needed for world-generation loot")
    }
}

/// TODO: add an in-place version of apply because it's likely that we'll
/// be reconstructing these item stacks every time for no reason
/// A loot function that transforms one item stack.
public protocol ItemModifier: Codable {
    func apply(to: ItemStack, withContext: LootContext) throws -> ItemStack
}

private enum LootFunctionTypeKey: String, CodingKey {
    case function
}

/// Type-erased wrapper used to code heterogeneous item modifiers.
public struct ItemModifierInitializer: Codable {
    public let value: ItemModifier

    public init(_ value: ItemModifier) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        self.value = try decodeItemModifier(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeItemModifier(value, to: encoder)
    }
}

/// Decodes a concrete item modifier from its `function`.
func decodeItemModifier(from decoder: Decoder) throws -> ItemModifier {
    if var array = try? decoder.unkeyedContainer() {
        var functions: [ItemModifier] = []
        while !array.isAtEnd {
            functions.append(try array.decode(ItemModifierInitializer.self).value)
        }
        return SequenceItemModifier(functions: functions)
    }

    let container = try decoder.container(keyedBy: LootFunctionTypeKey.self)
    let type = try addDefaultNamespace(container.decode(String.self, forKey: .function))
    switch type {
    case "minecraft:apply_bonus":
        return try ApplyBonusItemModifier(from: decoder)
    case "minecraft:copy_components":
        return try CopyComponentsItemModifier(from: decoder)
    case "minecraft:copy_custom_data":
        return try CopyCustomDataItemModifier(from: decoder)
    case "minecraft:copy_name":
        return try CopyNameItemModifier(from: decoder)
    case "minecraft:copy_state":
        return try CopyStateItemModifier(from: decoder)
    case "minecraft:discard":
        return try DiscardItemModifier(from: decoder)
    case "minecraft:enchant_randomly":
        return try EnchantRandomlyItemModifier(from: decoder)
    case "minecraft:enchant_with_levels":
        return try EnchantWithLevelsItemModifier(from: decoder)
    case "minecraft:enchanted_count_increase":
        return try EnchantedCountIncreaseItemModifier(from: decoder)
    case "minecraft:exploration_map":
        return try ExplorationMapItemModifier(from: decoder)
    case "minecraft:explosion_decay":
        return try ExplosionDecayItemModifier(from: decoder)
    case "minecraft:fill_player_head":
        return try FillPlayerHeadItemModifier(from: decoder)
    case "minecraft:filtered":
        return try FilteredItemModifier(from: decoder)
    case "minecraft:furnace_smelt":
        return try FurnaceSmeltItemModifier(from: decoder)
    case "minecraft:limit_count":
        return try LimitCountItemModifier(from: decoder)
    case "minecraft:modify_contents":
        return try ModifyComponentsItemModifier(from: decoder)
    case "minecraft:reference":
        return try ReferenceItemModifier(from: decoder)
    case "minecraft:sequence":
        return try SequenceItemModifier(from: decoder)
    case "minecraft:set_attributes":
        return try SetAttributesItemModifier(from: decoder)
    case "minecraft:set_banner_pattern":
        return try SetBannerPatternItemModifier(from: decoder)
    case "minecraft:set_book_cover":
        return try SetBookCoverItemModifier(from: decoder)
    case "minecraft:set_components":
        return try SetComponentsItemModifier(from: decoder)
    case "minecraft:set_contents":
        return try SetContentsItemModifier(from: decoder)
    case "minecraft:set_count":
        return try SetCountItemModifier(from: decoder)
    case "minecraft:set_custom_data":
        return try SetCustomDataItemModifier(from: decoder)
    case "minecraft:set_custom_model_data":
        return try SetCustomModelDataItemModifier(from: decoder)
    case "minecraft:set_damage":
        return try SetDamageItemModifier(from: decoder)
    case "minecraft:set_enchantments":
        return try SetEnchantmentsItemModifier(from: decoder)
    case "minecraft:set_fireworks":
        return try SetFireworksItemModifier(from: decoder)
    case "minecraft:set_firework_explosion":
        return try SetFireworkExplosionItemModifier(from: decoder)
    case "minecraft:set_instrument":
        return try SetInstrumentItemModifier(from: decoder)
    case "minecraft:set_item":
        return try SetItemItemModifier(from: decoder)
    case "minecraft:set_loot_table":
        return try SetLootTableItemModifier(from: decoder)
    case "minecraft:set_lore":
        return try SetLoreItemModifier(from: decoder)
    case "minecraft:set_name":
        return try SetNameItemModifier(from: decoder)
    case "minecraft:set_ominous_bottle_amplifier":
        return try SetOminousBottleAmplifierItemModifier(from: decoder)
    case "minecraft:set_potion":
        return try SetPotionItemModifier(from: decoder)
    case "minecraft:set_stew_effect":
        return try SetStewEffectItemModifier(from: decoder)
    case "minecraft:set_writable_book_pages":
        return try SetWritableBookPagesItemModifier(from: decoder)
    case "minecraft:set_written_book_pages":
        return try SetWrittenBookPagesItemModifier(from: decoder)
    case "minecraft:toggle_tooltips":
        return try ToggleTooltipsItemModifier(from: decoder)
    default:
        throw DecodingError.dataCorruptedError(forKey: .function, in: container, debugDescription: "Unknown item modifier type: \(type)")
    }
}

/// Encodes a concrete item modifier using its runtime type.
func encodeItemModifier(_ modifier: ItemModifier, to encoder: Encoder) throws {
    switch modifier {
    case let v as ApplyBonusItemModifier: try v.encode(to: encoder)
    case let v as CopyComponentsItemModifier: try v.encode(to: encoder)
    case let v as CopyCustomDataItemModifier: try v.encode(to: encoder)
    case let v as CopyNameItemModifier: try v.encode(to: encoder)
    case let v as CopyStateItemModifier: try v.encode(to: encoder)
    case let v as DiscardItemModifier: try v.encode(to: encoder)
    case let v as EnchantRandomlyItemModifier: try v.encode(to: encoder)
    case let v as EnchantWithLevelsItemModifier: try v.encode(to: encoder)
    case let v as EnchantedCountIncreaseItemModifier: try v.encode(to: encoder)
    case let v as ExplorationMapItemModifier: try v.encode(to: encoder)
    case let v as ExplosionDecayItemModifier: try v.encode(to: encoder)
    case let v as FillPlayerHeadItemModifier: try v.encode(to: encoder)
    case let v as FilteredItemModifier: try v.encode(to: encoder)
    case let v as FurnaceSmeltItemModifier: try v.encode(to: encoder)
    case let v as LimitCountItemModifier: try v.encode(to: encoder)
    case let v as ModifyComponentsItemModifier: try v.encode(to: encoder)
    case let v as ReferenceItemModifier: try v.encode(to: encoder)
    case let v as SequenceItemModifier: try v.encode(to: encoder)
    case let v as SetAttributesItemModifier: try v.encode(to: encoder)
    case let v as SetBannerPatternItemModifier: try v.encode(to: encoder)
    case let v as SetBookCoverItemModifier: try v.encode(to: encoder)
    case let v as SetComponentsItemModifier: try v.encode(to: encoder)
    case let v as SetContentsItemModifier: try v.encode(to: encoder)
    case let v as SetCountItemModifier: try v.encode(to: encoder)
    case let v as SetCustomDataItemModifier: try v.encode(to: encoder)
    case let v as SetCustomModelDataItemModifier: try v.encode(to: encoder)
    case let v as SetDamageItemModifier: try v.encode(to: encoder)
    case let v as SetEnchantmentsItemModifier: try v.encode(to: encoder)
    case let v as SetFireworksItemModifier: try v.encode(to: encoder)
    case let v as SetFireworkExplosionItemModifier: try v.encode(to: encoder)
    case let v as SetInstrumentItemModifier: try v.encode(to: encoder)
    case let v as SetItemItemModifier: try v.encode(to: encoder)
    case let v as SetLootTableItemModifier: try v.encode(to: encoder)
    case let v as SetLoreItemModifier: try v.encode(to: encoder)
    case let v as SetNameItemModifier: try v.encode(to: encoder)
    case let v as SetOminousBottleAmplifierItemModifier: try v.encode(to: encoder)
    case let v as SetPotionItemModifier: try v.encode(to: encoder)
    case let v as SetStewEffectItemModifier: try v.encode(to: encoder)
    case let v as SetWritableBookPagesItemModifier: try v.encode(to: encoder)
    case let v as SetWrittenBookPagesItemModifier: try v.encode(to: encoder)
    case let v as ToggleTooltipsItemModifier: try v.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported item modifier type")
        throw EncodingError.invalidValue(modifier, context)
    }
}

/// Applies several item modifiers in order.
public final class SequenceItemModifier: ItemModifier {
    let functions: [ItemModifier]

    public init(functions: [ItemModifier]) {
        self.functions = functions
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.functions = try c.decode([ItemModifierInitializer].self, forKey: key("functions")).map(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:sequence", forKey: key("function"))
        try c.encode(functions.map(ItemModifierInitializer.init), forKey: key("functions"))
    }

    public func apply(to stack: ItemStack, withContext context: LootContext) throws -> ItemStack {
        var result = stack
        for modifier in functions {
            result = try modifier.apply(to: result, withContext: context)
        }
        return result
    }
}

/// Shared implementation for modifiers guarded by conditions.
public protocol ConditionalItemModifier: ItemModifier {
    var conditions: [LootCondition] { get }

    func applyOnPass(to: ItemStack, withContext: LootContext) throws -> ItemStack
}

extension ConditionalItemModifier {
    public func apply(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        for condition in conditions {
            if try !condition.check(withContext: ctx) {
                return stack
            }
        }
        return try self.applyOnPass(to: stack, withContext: ctx)
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("Loot function \(String(reflecting: type(of: self))) is not evaluable with the current context")
    }
}

/// Vanilla formulas for the `apply_bonus` loot function.
public enum ApplyBonusFormula: Codable, Equatable {
    case binomialWithBonusCount(extra: Int, probability: Float)
    case oreDrops
    case uniformBonusCount(bonusMultiplier: Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let type = addDefaultNamespace(try c.decode(String.self, forKey: key("formula")))
        switch type {
        case "minecraft:binomial_with_bonus_count":
            let parameters = try c.decodeIfPresent(JSONValue.self, forKey: key("parameters"))?.objectValue ?? [:]
            let probability: Float
            switch parameters["probability"] {
            case .number(let value):
                probability = Float(value)
            case .integer(let value):
                probability = Float(value)
            default:
                probability = 0
            }
            self = .binomialWithBonusCount(
                extra: parameters["extra"]?.intValue ?? 0,
                probability: probability
            )
        case "minecraft:ore_drops":
            self = .oreDrops
        case "minecraft:uniform_bonus_count":
            let parameters = try c.decodeIfPresent(JSONValue.self, forKey: key("parameters"))?.objectValue ?? [:]
            self = .uniformBonusCount(bonusMultiplier: parameters["bonusMultiplier"]?.intValue ?? 0)
        default:
            throw DecodingError.dataCorruptedError(forKey: key("formula"), in: c, debugDescription: "Unknown apply_bonus formula: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .binomialWithBonusCount(let extra, let probability):
            try c.encode("minecraft:binomial_with_bonus_count", forKey: key("formula"))
            try c.encode(JSONValue.object([
                "extra": .integer(Int64(extra)),
                "probability": .number(Double(probability))
            ]), forKey: key("parameters"))
        case .oreDrops:
            try c.encode("minecraft:ore_drops", forKey: key("formula"))
        case .uniformBonusCount(let bonusMultiplier):
            try c.encode("minecraft:uniform_bonus_count", forKey: key("formula"))
            try c.encode(JSONValue.object([
                "bonusMultiplier": .integer(Int64(bonusMultiplier))
            ]), forKey: key("parameters"))
        }
    }
}

public final class ApplyBonusItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let enchantment: String
    let formula: ApplyBonusFormula

    public init(conditions: [LootCondition] = [], enchantment: String, formula: ApplyBonusFormula) {
        self.conditions = conditions
        self.enchantment = enchantment
        self.formula = formula
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.enchantment = try c.decode(String.self, forKey: key("enchantment"))
        self.formula = try ApplyBonusFormula(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:apply_bonus", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(enchantment, forKey: key("enchantment"))
        try formula.encode(to: encoder)
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("apply_bonus is not needed for world-generation loot")
    }
}

public final class CopyComponentsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let source: String
    let include: [String]?
    let exclude: [String]?

    public init(conditions: [LootCondition] = [], source: String, include: [String]? = nil, exclude: [String]? = nil) {
        self.conditions = conditions
        self.source = source
        self.include = include
        self.exclude = exclude
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.source = try c.decode(String.self, forKey: key("source"))
        self.include = try c.decodeIfPresent([String].self, forKey: key("include"))
        self.exclude = try c.decodeIfPresent([String].self, forKey: key("exclude"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:copy_components", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(source, forKey: key("source"))
        try c.encodeIfPresent(include, forKey: key("include"))
        try c.encodeIfPresent(exclude, forKey: key("exclude"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("copy_components is not needed for world-generation loot")
    }
}

public struct CopyCustomDataOperation: Codable, Equatable {
    let source: String
    let target: String
    let op: String
}

public final class CopyCustomDataItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let source: JSONValue
    let ops: [CopyCustomDataOperation]

    public init(conditions: [LootCondition] = [], source: JSONValue, ops: [CopyCustomDataOperation]) {
        self.conditions = conditions
        self.source = source
        self.ops = ops
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.source = try c.decode(JSONValue.self, forKey: key("source"))
        self.ops = try c.decode([CopyCustomDataOperation].self, forKey: key("ops"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:copy_custom_data", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(source, forKey: key("source"))
        try c.encode(ops, forKey: key("ops"))
    }
}

public final class CopyNameItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let source: String

    public init(conditions: [LootCondition] = [], source: String) {
        self.conditions = conditions
        self.source = source
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.source = try c.decode(String.self, forKey: key("source"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:copy_name", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(source, forKey: key("source"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("copy_name is not needed for world-generation loot")
    }
}

public final class CopyStateItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let block: String
    let properties: [String]

    public init(conditions: [LootCondition] = [], block: String, properties: [String]) {
        self.conditions = conditions
        self.block = block
        self.properties = properties
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.block = try c.decode(String.self, forKey: key("block"))
        self.properties = try c.decode([String].self, forKey: key("properties"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:copy_state", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(block, forKey: key("block"))
        try c.encode(properties, forKey: key("properties"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("copy_state is not needed for world-generation loot")
    }
}

public final class DiscardItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]

    public init(conditions: [LootCondition] = []) {
        self.conditions = conditions
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:discard", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return stack.withCount(0)
    }
}

/// Applies one random enchantment from an explicit list or tag.
public final class EnchantRandomlyItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let options: JSONValue?
    let onlyCompatible: Bool
    let treasure: Bool

    public init(
        conditions: [LootCondition] = [],
        options: JSONValue? = nil,
        onlyCompatible: Bool = true,
        treasure: Bool = false
    ) {
        self.conditions = conditions
        self.options = options
        self.onlyCompatible = onlyCompatible
        self.treasure = treasure
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.options = try c.decodeIfPresent(JSONValue.self, forKey: key("options"))
        self.onlyCompatible = try c.decodeIfPresent(Bool.self, forKey: key("only_compatible")) ?? true
        self.treasure = try c.decodeIfPresent(Bool.self, forKey: key("treasure")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:enchant_randomly", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(options, forKey: key("options"))
        if onlyCompatible != true {
            try c.encode(onlyCompatible, forKey: key("only_compatible"))
        }
        if treasure != false {
            try c.encode(treasure, forKey: key("treasure"))
        }
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let resources = try requireEnchantmentResources(ctx)
        let allowTreasureForOptions: Bool
        if case .string(let rawOptions)? = options, addDefaultNamespace(rawOptions.replacingOccurrences(of: "#", with: "")) == "minecraft:on_random_loot" {
            allowTreasureForOptions = true
        } else {
            allowTreasureForOptions = treasure
        }

        let optionValues = try resolvedIdentifierList(
            from: options ?? .string("#minecraft:in_enchanting_table"),
            itemName: stack.itemName,
            allowTreasure: allowTreasureForOptions,
            useOverrides: true,
            resources: resources
        ) ?? []

        let applicableOptions = try optionValues.filter { candidate in
            if !onlyCompatible {
                return true
            }
            return try isApplicableWorldgenEnchantment(candidate, to: stack.itemName, useOverrides: true, resources: resources)
        }
        let existingEnchantments = stack.enchantmentLevels
        let filteredOptions = try applicableOptions.filter { candidate in
            try existingEnchantments.allSatisfy {
                try !areEnchantmentsMutuallyExclusive(
                    addDefaultNamespace(candidate),
                    $0.key,
                    resources: resources
                )
            }
        }
        let candidates = filteredOptions.isEmpty ? applicableOptions : filteredOptions
        guard !candidates.isEmpty else {
            return stack
        }

        let chosen = candidates[Int(ctx.random.next(bound: UInt32(candidates.count)))]
        let maxLevel = try maxLevelForEnchantment(chosen, resources: resources)
        let level = maxLevel > 1 ? Int(ctx.random.next(bound: UInt32(maxLevel))) + 1 : 1

        var enchantments = stack.enchantmentLevels
        enchantments[addDefaultNamespace(chosen)] = level
        return stack.settingEnchantments(enchantments)
    }
}

/// Applies enchanting-table style selection using datapack enchantments.
public final class EnchantWithLevelsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let levels: LootNumberProvider
    let options: JSONValue?
    let treasure: Bool

    public init(
        conditions: [LootCondition] = [],
        levels: LootNumberProvider,
        options: JSONValue? = nil,
        treasure: Bool = true
    ) {
        self.conditions = conditions
        self.levels = levels
        self.options = options
        self.treasure = treasure
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.levels = try c.decode(LootNumberProviderInitializer.self, forKey: key("levels")).value
        self.options = try c.decodeIfPresent(JSONValue.self, forKey: key("options"))
        self.treasure = try c.decodeIfPresent(Bool.self, forKey: key("treasure")) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:enchant_with_levels", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(LootNumberProviderInitializer(levels), forKey: key("levels"))
        try c.encodeIfPresent(options, forKey: key("options"))
        if treasure != true {
            try c.encode(treasure, forKey: key("treasure"))
        }
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let resources = try requireEnchantmentResources(ctx)
        let enchantability = enchantabilityForWorldgenItem(stack.itemName)
        let resolvedOptions = try resolvedIdentifierList(
            from: options,
            itemName: stack.itemName,
            allowTreasure: treasure,
            useOverrides: true,
            resources: resources
        )
        let candidateEnchantments = try resolvedOptions ?? worldgenApplicableEnchantments(
            for: stack.itemName,
            allowTreasure: treasure,
            useOverrides: false,
            resources: resources
        )
        guard !candidateEnchantments.isEmpty else {
            return stack
        }

        var effectiveLevel = levels.getInt(fromContext: ctx)
        if effectiveLevel < 0 {
            effectiveLevel = 0
        }
        let delta = enchantability / 4 + 1
        effectiveLevel += 1 + Int(ctx.random.next(bound: UInt32(delta))) + Int(ctx.random.next(bound: UInt32(delta)))
        let amplifier = (ctx.random.nextFloat() + ctx.random.nextFloat() - 1.0) * 0.15
        effectiveLevel = Int((Float(effectiveLevel) + Float(effectiveLevel) * amplifier).rounded())
        if effectiveLevel < 0 {
            effectiveLevel = 0
        }

        var weightedCandidates = try makeEnchantmentLevelChoices(
            from: candidateEnchantments,
            effectiveLevel: effectiveLevel,
            resources: resources
        )
        guard !weightedCandidates.isEmpty else {
            return stack
        }

        var selectedEnchantments: [String: Int] = [:]
        var chosen = chooseWeightedEnchantment(from: weightedCandidates, withContext: ctx)
        selectedEnchantments[chosen.id] = chosen.level

        while Int(ctx.random.next(bound: 50)) <= effectiveLevel {
            try weightedCandidates.removeAll { candidate in
                try areEnchantmentsMutuallyExclusive(candidate.id, chosen.id, resources: resources)
            }
            guard !weightedCandidates.isEmpty else {
                break
            }

            chosen = chooseWeightedEnchantment(from: weightedCandidates, withContext: ctx)
            selectedEnchantments[chosen.id] = chosen.level
            effectiveLevel /= 2
        }

        return stack.settingEnchantments(selectedEnchantments)
    }
}

public final class EnchantedCountIncreaseItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let enchantment: String
    let count: LootNumberProvider
    let limit: Int

    public init(conditions: [LootCondition] = [], enchantment: String, count: LootNumberProvider, limit: Int = 0) {
        self.conditions = conditions
        self.enchantment = enchantment
        self.count = count
        self.limit = limit
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.enchantment = try c.decode(String.self, forKey: key("enchantment"))
        self.count = try c.decode(LootNumberProviderInitializer.self, forKey: key("count")).value
        self.limit = try c.decodeIfPresent(Int.self, forKey: key("limit")) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:enchanted_count_increase", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(enchantment, forKey: key("enchantment"))
        try c.encode(LootNumberProviderInitializer(count), forKey: key("count"))
        if limit != 0 {
            try c.encode(limit, forKey: key("limit"))
        }
    }
}

public final class ExplorationMapItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let destination: String?
    let decoration: String?
    let zoom: Int?
    let searchRadius: Int?
    let skipExistingChunks: Bool?

    public init(
        conditions: [LootCondition] = [],
        destination: String? = nil,
        decoration: String? = nil,
        zoom: Int? = nil,
        searchRadius: Int? = nil,
        skipExistingChunks: Bool? = nil
    ) {
        self.conditions = conditions
        self.destination = destination
        self.decoration = decoration
        self.zoom = zoom
        self.searchRadius = searchRadius
        self.skipExistingChunks = skipExistingChunks
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.destination = try c.decodeIfPresent(String.self, forKey: key("destination"))
        self.decoration = try c.decodeIfPresent(String.self, forKey: key("decoration"))
        self.zoom = try c.decodeIfPresent(Int.self, forKey: key("zoom"))
        self.searchRadius = try c.decodeIfPresent(Int.self, forKey: key("search_radius"))
        self.skipExistingChunks = try c.decodeIfPresent(Bool.self, forKey: key("skip_existing_chunks"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:exploration_map", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(destination, forKey: key("destination"))
        try c.encodeIfPresent(decoration, forKey: key("decoration"))
        try c.encodeIfPresent(zoom, forKey: key("zoom"))
        try c.encodeIfPresent(searchRadius, forKey: key("search_radius"))
        try c.encodeIfPresent(skipExistingChunks, forKey: key("skip_existing_chunks"))
    }
}

public final class ExplosionDecayItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]

    public init(conditions: [LootCondition] = []) {
        self.conditions = conditions
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:explosion_decay", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("explosion_decay is not needed for world-generation loot")
    }
}

public final class FillPlayerHeadItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let entity: String

    public init(conditions: [LootCondition] = [], entity: String) {
        self.conditions = conditions
        self.entity = entity
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.entity = try c.decode(String.self, forKey: key("entity"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:fill_player_head", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(entity, forKey: key("entity"))
    }
}

public final class FilteredItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let itemFilter: JSONValue
    let onPass: ItemModifier?
    let onFail: ItemModifier?

    public init(conditions: [LootCondition] = [], itemFilter: JSONValue, onPass: ItemModifier? = nil, onFail: ItemModifier? = nil) {
        self.conditions = conditions
        self.itemFilter = itemFilter
        self.onPass = onPass
        self.onFail = onFail
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.itemFilter = try c.decode(JSONValue.self, forKey: key("item_filter"))
        self.onPass = try c.decodeIfPresent(ItemModifierInitializer.self, forKey: key("on_pass"))?.value
        self.onFail = try c.decodeIfPresent(ItemModifierInitializer.self, forKey: key("on_fail"))?.value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:filtered", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(itemFilter, forKey: key("item_filter"))
        try c.encodeIfPresent(onPass.map(ItemModifierInitializer.init), forKey: key("on_pass"))
        try c.encodeIfPresent(onFail.map(ItemModifierInitializer.init), forKey: key("on_fail"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("filtered is not needed for world-generation loot")
    }
}

public final class FurnaceSmeltItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]

    public init(conditions: [LootCondition] = []) {
        self.conditions = conditions
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:furnace_smelt", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("furnace_smelt is not needed for world-generation loot")
    }
}

public final class LimitCountItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let limit: JSONValue

    public init(conditions: [LootCondition] = [], limit: JSONValue) {
        self.conditions = conditions
        self.limit = limit
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.limit = try c.decode(JSONValue.self, forKey: key("limit"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:limit_count", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(limit, forKey: key("limit"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let newCount = clampedCount(stack.count, with: limit)
        return ItemStack(itemName: stack.itemName, count: newCount, components: stack.components)
    }
}

public final class ModifyComponentsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let component: JSONValue
    let modifier: ItemModifier

    public init(conditions: [LootCondition] = [], component: JSONValue, modifier: ItemModifier) {
        self.conditions = conditions
        self.component = component
        self.modifier = modifier
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.component = try c.decode(JSONValue.self, forKey: key("component"))
        self.modifier = try c.decode(ItemModifierInitializer.self, forKey: key("modifier")).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:modify_contents", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(component, forKey: key("component"))
        try c.encode(ItemModifierInitializer(modifier), forKey: key("modifier"))
    }
}

public final class ReferenceItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let name: String

    public init(conditions: [LootCondition] = [], name: String) {
        self.conditions = conditions
        self.name = name
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.name = try c.decode(String.self, forKey: key("name"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:reference", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(name, forKey: key("name"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        throw LootEvaluationError.unsupported("reference item modifiers are not needed for world-generation loot")
    }
}

public struct SetAttributeModifier: Codable {
    let id: String
    let attribute: String
    let operation: String
    let amount: LootNumberProviderInitializer
    let slot: JSONValue

    public init(id: String, attribute: String, operation: String, amount: LootNumberProvider, slot: JSONValue) {
        self.id = id
        self.attribute = attribute
        self.operation = operation
        self.amount = LootNumberProviderInitializer(amount)
        self.slot = slot
    }
}

public final class SetAttributesItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let modifiers: [SetAttributeModifier]
    let replace: Bool

    public init(conditions: [LootCondition] = [], modifiers: [SetAttributeModifier], replace: Bool = true) {
        self.conditions = conditions
        self.modifiers = modifiers
        self.replace = replace
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.modifiers = try c.decode([SetAttributeModifier].self, forKey: key("modifiers"))
        self.replace = try c.decodeIfPresent(Bool.self, forKey: key("replace")) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_attributes", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(modifiers, forKey: key("modifiers"))
        if replace != true {
            try c.encode(replace, forKey: key("replace"))
        }
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let modifierPayload = modifiers.map { modifier in
            JSONValue.object([
                "id": .string(modifier.id),
                "attribute": .string(modifier.attribute),
                "operation": .string(modifier.operation),
                "amount": .number(Double(modifier.amount.value.getFloat(fromContext: ctx))),
                "slot": modifier.slot
            ])
        }

        if replace {
            return stack.settingComponent("minecraft:attribute_modifiers", .array(modifierPayload))
        }

        let existing = stack.components["minecraft:attribute_modifiers"]?.arrayValue ?? []
        return stack.settingComponent("minecraft:attribute_modifiers", .array(existing + modifierPayload))
    }
}

public final class SetBannerPatternItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let patterns: JSONValue
    let append: Bool

    public init(conditions: [LootCondition] = [], patterns: JSONValue, append: Bool) {
        self.conditions = conditions
        self.patterns = patterns
        self.append = append
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.patterns = try c.decode(JSONValue.self, forKey: key("patterns"))
        self.append = try c.decode(Bool.self, forKey: key("append"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_banner_pattern", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(patterns, forKey: key("patterns"))
        try c.encode(append, forKey: key("append"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        if append, let existing = stack.components["minecraft:banner_patterns"]?.arrayValue, let extra = patterns.arrayValue {
            return stack.settingComponent("minecraft:banner_patterns", .array(existing + extra))
        }
        return stack.settingComponent("minecraft:banner_patterns", patterns)
    }
}

public final class SetBookCoverItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let title: JSONValue?
    let author: String?
    let generation: Int?

    public init(conditions: [LootCondition] = [], title: JSONValue? = nil, author: String? = nil, generation: Int? = nil) {
        self.conditions = conditions
        self.title = title
        self.author = author
        self.generation = generation
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.title = try c.decodeIfPresent(JSONValue.self, forKey: key("title"))
        self.author = try c.decodeIfPresent(String.self, forKey: key("author"))
        self.generation = try c.decodeIfPresent(Int.self, forKey: key("generation"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_book_cover", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(title, forKey: key("title"))
        try c.encodeIfPresent(author, forKey: key("author"))
        try c.encodeIfPresent(generation, forKey: key("generation"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var cover: [String: JSONValue] = stack.components["minecraft:written_book_content"]?.objectValue ?? [:]
        if let title {
            cover["title"] = title
        }
        if let author {
            cover["author"] = .string(author)
        }
        if let generation {
            cover["generation"] = .integer(Int64(generation))
        }
        return stack.settingComponent("minecraft:written_book_content", .object(cover))
    }
}

public final class SetComponentsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let components: JSONValue

    public init(conditions: [LootCondition] = [], components: JSONValue) {
        self.conditions = conditions
        self.components = components
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.components = try c.decode(JSONValue.self, forKey: key("components"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_components", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(components, forKey: key("components"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        guard let componentObject = components.objectValue else {
            throw LootEvaluationError.invalidData("set_components requires an object payload")
        }
        return stack.mergingComponents(componentObject)
    }
}

public final class SetContentsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let component: JSONValue
    let entries: [LootEntry]

    public init(conditions: [LootCondition] = [], component: JSONValue, entries: [LootEntry]) {
        self.conditions = conditions
        self.component = component
        self.entries = entries
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.component = try c.decode(JSONValue.self, forKey: key("component"))
        self.entries = try c.decode([LootEntryInitializer].self, forKey: key("entries")).map(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_contents", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(component, forKey: key("component"))
        try c.encode(entries.map(LootEntryInitializer.init), forKey: key("entries"))
    }
}

public final class SetCountItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let count: LootNumberProvider
    let add: Bool

    public init(conditions: [LootCondition] = [], count: LootNumberProvider, add: Bool = false) {
        self.conditions = conditions
        self.count = count
        self.add = add
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.count = try c.decode(LootNumberProviderInitializer.self, forKey: key("count")).value
        self.add = try c.decodeIfPresent(Bool.self, forKey: key("add")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_count", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(LootNumberProviderInitializer(count), forKey: key("count"))
        try c.encode(add, forKey: key("add"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let value = count.getInt(fromContext: ctx)
        let updatedCount = max(0, add ? stack.count + value : value)
        return ItemStack(itemName: stack.itemName, count: updatedCount, components: stack.components)
    }
}

public final class SetCustomDataItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let tag: JSONValue

    public init(conditions: [LootCondition] = [], tag: JSONValue) {
        self.conditions = conditions
        self.tag = tag
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.tag = try c.decode(JSONValue.self, forKey: key("tag"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_custom_data", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(tag, forKey: key("tag"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return stack.settingComponent("minecraft:custom_data", tag)
    }
}

public final class SetCustomModelDataItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let floats: JSONValue?
    let flags: JSONValue?
    let strings: JSONValue?
    let colors: JSONValue?

    public init(
        conditions: [LootCondition] = [],
        floats: JSONValue? = nil,
        flags: JSONValue? = nil,
        strings: JSONValue? = nil,
        colors: JSONValue? = nil
    ) {
        self.conditions = conditions
        self.floats = floats
        self.flags = flags
        self.strings = strings
        self.colors = colors
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.floats = try c.decodeIfPresent(JSONValue.self, forKey: key("floats"))
        self.flags = try c.decodeIfPresent(JSONValue.self, forKey: key("flags"))
        self.strings = try c.decodeIfPresent(JSONValue.self, forKey: key("strings"))
        self.colors = try c.decodeIfPresent(JSONValue.self, forKey: key("colors"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_custom_model_data", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(floats, forKey: key("floats"))
        try c.encodeIfPresent(flags, forKey: key("flags"))
        try c.encodeIfPresent(strings, forKey: key("strings"))
        try c.encodeIfPresent(colors, forKey: key("colors"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var customModelData: [String: JSONValue] = [:]
        if let floats { customModelData["floats"] = floats }
        if let flags { customModelData["flags"] = flags }
        if let strings { customModelData["strings"] = strings }
        if let colors { customModelData["colors"] = colors }
        return stack.settingComponent("minecraft:custom_model_data", .object(customModelData))
    }
}

public final class SetDamageItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let damage: LootNumberProvider
    let add: Bool

    public init(conditions: [LootCondition] = [], damage: LootNumberProvider, add: Bool = false) {
        self.conditions = conditions
        self.damage = damage
        self.add = add
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.damage = try c.decode(LootNumberProviderInitializer.self, forKey: key("damage")).value
        self.add = try c.decodeIfPresent(Bool.self, forKey: key("add")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_damage", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(LootNumberProviderInitializer(damage), forKey: key("damage"))
        try c.encode(add, forKey: key("add"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        guard let maxDamage = maxDamageForWorldgenItem(stack.itemName), maxDamage > 0 else {
            throw LootEvaluationError.unsupported("set_damage does not support \(stack.itemName)")
        }

        let existingDamage = stack.components["minecraft:damage"]?.intValue ?? 0
        let existingDurabilityFraction = 1.0 - Double(existingDamage) / Double(maxDamage)
        let baseFraction = add ? existingDurabilityFraction : 0.0
        let remainingDurabilityFraction = max(0.0, min(1.0, baseFraction + Double(damage.getFloat(fromContext: ctx))))
        let rawDamage = Int(((1.0 - remainingDurabilityFraction) * Double(maxDamage)).rounded(.down))
        return stack.settingComponent("minecraft:damage", .integer(Int64(rawDamage)))
    }
}

public final class SetEnchantmentsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let enchantments: [String: LootNumberProvider]
    let add: Bool

    public init(conditions: [LootCondition] = [], enchantments: [String: LootNumberProvider] = [:], add: Bool = false) {
        self.conditions = conditions
        self.enchantments = enchantments
        self.add = add
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.enchantments = try decodeLootNumberProviders(from: c, forKey: "enchantments")
        self.add = try c.decodeIfPresent(Bool.self, forKey: key("add")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_enchantments", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try encodeLootNumberProviders(enchantments, to: &c, forKey: "enchantments")
        try c.encode(add, forKey: key("add"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var updatedEnchantments = add ? stack.enchantmentLevels : [:]
        for (id, provider) in enchantments {
            let normalizedID = addDefaultNamespace(id)
            let providedLevel = provider.getInt(fromContext: ctx)
            let level = add ? (updatedEnchantments[normalizedID] ?? 0) + providedLevel : providedLevel
            if level > 0 {
                updatedEnchantments[normalizedID] = level
            } else {
                updatedEnchantments.removeValue(forKey: normalizedID)
            }
        }
        return stack.settingEnchantments(updatedEnchantments)
    }
}

public final class SetFireworksItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let explosions: JSONValue?
    let flightDuration: Int?

    public init(conditions: [LootCondition] = [], explosions: JSONValue? = nil, flightDuration: Int? = nil) {
        self.conditions = conditions
        self.explosions = explosions
        self.flightDuration = flightDuration
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.explosions = try c.decodeIfPresent(JSONValue.self, forKey: key("explosions"))
        self.flightDuration = try c.decodeIfPresent(Int.self, forKey: key("flight_duration"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_fireworks", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(explosions, forKey: key("explosions"))
        try c.encodeIfPresent(flightDuration, forKey: key("flight_duration"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var fireworks: [String: JSONValue] = stack.components["minecraft:fireworks"]?.objectValue ?? [:]
        if let explosions {
            fireworks["explosions"] = explosions
        }
        if let flightDuration {
            fireworks["flight_duration"] = .integer(Int64(flightDuration))
        }
        return stack.settingComponent("minecraft:fireworks", .object(fireworks))
    }
}

public final class SetFireworkExplosionItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let shape: String?
    let colors: [Int]?
    let fadeColors: [Int]?
    let trail: Bool?
    let twinkle: Bool?

    public init(
        conditions: [LootCondition] = [],
        shape: String? = nil,
        colors: [Int]? = nil,
        fadeColors: [Int]? = nil,
        trail: Bool? = nil,
        twinkle: Bool? = nil
    ) {
        self.conditions = conditions
        self.shape = shape
        self.colors = colors
        self.fadeColors = fadeColors
        self.trail = trail
        self.twinkle = twinkle
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.shape = try c.decodeIfPresent(String.self, forKey: key("shape"))
        self.colors = try c.decodeIfPresent([Int].self, forKey: key("colors"))
        self.fadeColors = try c.decodeIfPresent([Int].self, forKey: key("fade_colors"))
        self.trail = try c.decodeIfPresent(Bool.self, forKey: key("trail"))
        self.twinkle = try c.decodeIfPresent(Bool.self, forKey: key("twinkle"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_firework_explosion", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(shape, forKey: key("shape"))
        try c.encodeIfPresent(colors, forKey: key("colors"))
        try c.encodeIfPresent(fadeColors, forKey: key("fade_colors"))
        try c.encodeIfPresent(trail, forKey: key("trail"))
        try c.encodeIfPresent(twinkle, forKey: key("twinkle"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var explosion: [String: JSONValue] = [:]
        if let shape { explosion["shape"] = .string(shape) }
        if let colors { explosion["colors"] = .array(colors.map { .integer(Int64($0)) }) }
        if let fadeColors { explosion["fade_colors"] = .array(fadeColors.map { .integer(Int64($0)) }) }
        if let trail { explosion["trail"] = .bool(trail) }
        if let twinkle { explosion["twinkle"] = .bool(twinkle) }
        return stack.settingComponent("minecraft:firework_explosion", .object(explosion))
    }
}

public final class SetInstrumentItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let options: String

    public init(conditions: [LootCondition] = [], options: String) {
        self.conditions = conditions
        self.options = options
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.options = try c.decode(String.self, forKey: key("options"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_instrument", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(options, forKey: key("options"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let candidates = instrumentOptions(for: options)
        guard !candidates.isEmpty else {
            throw LootEvaluationError.unsupported("set_instrument does not support \(options)")
        }
        let selected = candidates[Int(ctx.random.next(bound: UInt32(candidates.count)))]
        return stack.settingComponent("minecraft:instrument", .string(selected))
    }
}

public final class SetItemItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let item: String

    public init(conditions: [LootCondition] = [], item: String) {
        self.conditions = conditions
        self.item = item
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.item = try c.decode(String.self, forKey: key("item"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_item", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(item, forKey: key("item"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return ItemStack(itemName: item, count: stack.count, components: stack.components)
    }
}

public final class SetLootTableItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let name: String
    let seed: Int64
    let type: String

    public init(conditions: [LootCondition] = [], name: String, seed: Int64 = 0, type: String) {
        self.conditions = conditions
        self.name = name
        self.seed = seed
        self.type = type
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.name = try c.decode(String.self, forKey: key("name"))
        self.seed = try c.decodeIfPresent(Int64.self, forKey: key("seed")) ?? 0
        self.type = try c.decode(String.self, forKey: key("type"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_loot_table", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(name, forKey: key("name"))
        if seed != 0 {
            try c.encode(seed, forKey: key("seed"))
        }
        try c.encode(type, forKey: key("type"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        var lootTable: [String: JSONValue] = [
            "loot_table": .string(name),
            "type": .string(type)
        ]
        if seed != 0 {
            lootTable["seed"] = .integer(seed)
        }
        return stack.settingComponent("minecraft:container_loot", .object(lootTable))
    }
}

public final class SetLoreItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let lore: [JSONValue]
    let operation: JSONValue
    let entity: String?

    public init(conditions: [LootCondition] = [], lore: [JSONValue], operation: JSONValue, entity: String? = nil) {
        self.conditions = conditions
        self.lore = lore
        self.operation = operation
        self.entity = entity
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.lore = try c.decode([JSONValue].self, forKey: key("lore"))
        self.operation = try c.decode(JSONValue.self, forKey: key("operation"))
        self.entity = try c.decodeIfPresent(String.self, forKey: key("entity"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_lore", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(lore, forKey: key("lore"))
        try c.encode(operation, forKey: key("operation"))
        try c.encodeIfPresent(entity, forKey: key("entity"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let operationName = operation.stringValue ?? "replace_all"
        let existing = stack.components["minecraft:lore"]?.arrayValue ?? []
        let mergedLore: [JSONValue]
        switch operationName {
        case "append":
            mergedLore = existing + lore
        case "replace_all":
            mergedLore = lore
        default:
            throw LootEvaluationError.unsupported("Unsupported set_lore operation '\(operationName)'")
        }
        return stack.settingComponent("minecraft:lore", .array(mergedLore))
    }
}

public final class SetNameItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let name: JSONValue?
    let entity: String?
    let target: String

    public init(conditions: [LootCondition] = [], name: JSONValue? = nil, entity: String? = nil, target: String = "custom_name") {
        self.conditions = conditions
        self.name = name
        self.entity = entity
        self.target = target
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.name = try c.decodeIfPresent(JSONValue.self, forKey: key("name"))
        self.entity = try c.decodeIfPresent(String.self, forKey: key("entity"))
        self.target = try c.decodeIfPresent(String.self, forKey: key("target")) ?? "custom_name"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_name", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encodeIfPresent(name, forKey: key("name"))
        try c.encodeIfPresent(entity, forKey: key("entity"))
        if target != "custom_name" {
            try c.encode(target, forKey: key("target"))
        }
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let resolvedName: JSONValue
        if let name {
            resolvedName = name
        } else {
            throw LootEvaluationError.unsupported("set_name entity substitution is not needed for world-generation loot")
        }

        let keyName = target == "item_name" ? "minecraft:item_name" : "minecraft:custom_name"
        return stack.settingComponent(keyName, resolvedName)
    }
}

public final class SetOminousBottleAmplifierItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let amplifier: LootNumberProvider

    public init(conditions: [LootCondition] = [], amplifier: LootNumberProvider) {
        self.conditions = conditions
        self.amplifier = amplifier
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.amplifier = try c.decode(LootNumberProviderInitializer.self, forKey: key("amplifier")).value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_ominous_bottle_amplifier", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(LootNumberProviderInitializer(amplifier), forKey: key("amplifier"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return stack.settingComponent("minecraft:ominous_bottle_amplifier", .integer(Int64(amplifier.getInt(fromContext: ctx))))
    }
}

public final class SetPotionItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let id: String

    public init(conditions: [LootCondition] = [], id: String) {
        self.conditions = conditions
        self.id = id
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.id = try c.decode(String.self, forKey: key("id"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_potion", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(id, forKey: key("id"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return stack.settingComponent("minecraft:potion_contents", .object(["potion": .string(id)]))
    }
}

public struct StewEffect: Codable {
    let type: String
    let duration: LootNumberProviderInitializer

    public init(type: String, duration: LootNumberProvider) {
        self.type = type
        self.duration = LootNumberProviderInitializer(duration)
    }
}

public final class SetStewEffectItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let effects: [StewEffect]

    public init(conditions: [LootCondition] = [], effects: [StewEffect] = []) {
        self.conditions = conditions
        self.effects = effects
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.effects = try c.decodeIfPresent([StewEffect].self, forKey: key("effects")) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_stew_effect", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        if !effects.isEmpty {
            try c.encode(effects, forKey: key("effects"))
        }
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        guard !effects.isEmpty else {
            return stack
        }
        let selected = effects[Int(ctx.random.next(bound: UInt32(effects.count)))]
        var duration = selected.duration.value.getInt(fromContext: ctx)
        if !isInstantEffect(selected.type) {
            duration *= 20
        }
        let effectPayload: JSONValue = .object([
            "id": .string(selected.type),
            "duration": .integer(Int64(duration))
        ])
        return stack.settingComponent("minecraft:suspicious_stew_effects", .array([effectPayload]))
    }
}

public final class SetWritableBookPagesItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let pages: [JSONValue]
    let operation: JSONValue

    public init(conditions: [LootCondition] = [], pages: [JSONValue], operation: JSONValue) {
        self.conditions = conditions
        self.pages = pages
        self.operation = operation
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.pages = try c.decode([JSONValue].self, forKey: key("pages"))
        self.operation = try c.decode(JSONValue.self, forKey: key("operation"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_writable_book_pages", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(pages, forKey: key("pages"))
        try c.encode(operation, forKey: key("operation"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return try applyBookPages(stack: stack, componentKey: "minecraft:writable_book_content", pages: pages, operation: operation)
    }
}

public final class SetWrittenBookPagesItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let pages: [JSONValue]
    let operation: JSONValue

    public init(conditions: [LootCondition] = [], pages: [JSONValue], operation: JSONValue) {
        self.conditions = conditions
        self.pages = pages
        self.operation = operation
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.pages = try c.decode([JSONValue].self, forKey: key("pages"))
        self.operation = try c.decode(JSONValue.self, forKey: key("operation"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:set_written_book_pages", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(pages, forKey: key("pages"))
        try c.encode(operation, forKey: key("operation"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        return try applyBookPages(stack: stack, componentKey: "minecraft:written_book_content", pages: pages, operation: operation)
    }
}

public final class ToggleTooltipsItemModifier: ConditionalItemModifier {
    public let conditions: [LootCondition]
    let toggles: [String: Bool]

    public init(conditions: [LootCondition] = [], toggles: [String: Bool]) {
        self.conditions = conditions
        self.toggles = toggles
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.conditions = try decodeLootConditions(from: c, forKey: "conditions")
        self.toggles = try c.decode([String: Bool].self, forKey: key("toggles"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode("minecraft:toggle_tooltips", forKey: key("function"))
        try encodeLootConditions(conditions, to: &c, forKey: "conditions")
        try c.encode(toggles, forKey: key("toggles"))
    }

    public func applyOnPass(to stack: ItemStack, withContext ctx: LootContext) throws -> ItemStack {
        let tooltipPayload = toggles.mapValues(JSONValue.bool)
        return stack.settingComponent("minecraft:tooltip_display", .object(tooltipPayload))
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Builds a dynamic coding key from a string literal.
private func key(_ string: String) -> DynamicCodingKey {
    return DynamicCodingKey(stringValue: string)!
}

/// Decodes a condition list only when its key is present.
private func decodeLootConditions(from container: KeyedDecodingContainer<DynamicCodingKey>, forKey keyString: String) throws -> [LootCondition] {
    guard container.contains(key(keyString)) else {
        return []
    }
    return try container.decode([LootConditionInitializer].self, forKey: key(keyString)).map(\.value)
}

/// Encodes a condition list only when it is non-empty.
private func encodeLootConditions(
    _ conditions: [LootCondition],
    to container: inout KeyedEncodingContainer<DynamicCodingKey>,
    forKey keyString: String
) throws {
    if !conditions.isEmpty {
        try container.encode(conditions.map(LootConditionInitializer.init), forKey: key(keyString))
    }
}

/// Decodes a modifier list only when its key is present.
private func decodeItemModifiers(from container: KeyedDecodingContainer<DynamicCodingKey>, forKey keyString: String) throws -> [ItemModifier] {
    guard container.contains(key(keyString)) else {
        return []
    }
    return try container.decode([ItemModifierInitializer].self, forKey: key(keyString)).map(\.value)
}

/// Encodes a modifier list only when it is non-empty.
private func encodeItemModifiers(
    _ modifiers: [ItemModifier],
    to container: inout KeyedEncodingContainer<DynamicCodingKey>,
    forKey keyString: String
) throws {
    if !modifiers.isEmpty {
        try container.encode(modifiers.map(ItemModifierInitializer.init), forKey: key(keyString))
    }
}

/// Decodes a dictionary of number providers.
private func decodeLootNumberProviders(
    from container: KeyedDecodingContainer<DynamicCodingKey>,
    forKey keyString: String
) throws -> [String: LootNumberProvider] {
    guard container.contains(key(keyString)) else {
        return [:]
    }
    let raw = try container.decode([String: LootNumberProviderInitializer].self, forKey: key(keyString))
    return raw.mapValues(\.value)
}

/// Encodes a dictionary of number providers.
private func encodeLootNumberProviders(
    _ providers: [String: LootNumberProvider],
    to container: inout KeyedEncodingContainer<DynamicCodingKey>,
    forKey keyString: String
) throws {
    if !providers.isEmpty {
        try container.encode(providers.mapValues(LootNumberProviderInitializer.init), forKey: key(keyString))
    }
}

/// Checks whether an integer satisfies the vanilla JSON range format.
private func checkIntRange(_ value: Int, against range: JSONValue) -> Bool {
    switch range {
    case .integer(let exact):
        return Int(exact) == value
    case .number(let exact):
        return Int(exact) == value
    case .object(let object):
        let min = object["min"]?.intValue
        let max = object["max"]?.intValue
        if let min, value < min { return false }
        if let max, value > max { return false }
        return true
    default:
        return true
    }
}

/// Clamps a count using the vanilla JSON range format.
private func clampedCount(_ count: Int, with limit: JSONValue) -> Int {
    switch limit {
    case .integer(let exact):
        return Int(exact)
    case .number(let exact):
        return Int(exact)
    case .object(let object):
        var result = count
        if let min = object["min"]?.intValue {
            result = max(result, min)
        }
        if let max = object["max"]?.intValue {
            result = min(result, max)
        }
        return result
    default:
        return count
    }
}

/// Resolves one enchantment identifier, identifier list, or enchantment tag.
private func resolvedIdentifierList(
    from value: JSONValue?,
    itemName: String? = nil,
    allowTreasure: Bool = true,
    useOverrides: Bool = true,
    resources: LootEnchantmentResources
) throws -> [String]? {
    guard let value else {
        return nil
    }

    switch value {
    case .string(let identifier):
        if identifier.hasPrefix("#") {
            let entries = try enchantmentTagValues(
                for: identifier,
                itemName: itemName,
                allowTreasure: allowTreasure,
                useOverrides: useOverrides,
                resources: resources
            )
            guard !entries.isEmpty else {
                throw LootEvaluationError.unsupported("Unsupported loot tag \(identifier)")
            }
            return entries
        }
        return [addDefaultNamespace(identifier)]
    case .array(let values):
        var resolved: [String] = []
        for child in values {
            resolved += try resolvedIdentifierList(
                from: child,
                itemName: itemName,
                allowTreasure: allowTreasure,
                useOverrides: useOverrides,
                resources: resources
            ) ?? []
        }
        return resolved
    default:
        throw LootEvaluationError.invalidData("Expected identifier or identifier array")
    }
}

/// Applies book page mutations shared by writable and written books.
private func applyBookPages(stack: ItemStack, componentKey: String, pages: [JSONValue], operation: JSONValue) throws -> ItemStack {
    let operationName = operation.stringValue ?? "replace_all"
    var content = stack.components[componentKey]?.objectValue ?? [:]
    let existingPages = content["pages"]?.arrayValue ?? []
    switch operationName {
    case "append":
        content["pages"] = .array(existingPages + pages)
    case "replace_all":
        content["pages"] = .array(pages)
    default:
        throw LootEvaluationError.unsupported("Unsupported book-page operation '\(operationName)'")
    }
    return stack.settingComponent(componentKey, .object(content))
}

/// Returns whether a potion effect resolves instantly instead of over time.
private func isInstantEffect(_ effectID: String) -> Bool {
    switch addDefaultNamespace(effectID) {
    case "minecraft:instant_health", "minecraft:instant_damage", "minecraft:saturation":
        return true
    default:
        return false
    }
}

/// Returns the maximum durability of a world-generation loot item.
private func maxDamageForWorldgenItem(_ itemName: String) -> Int? {
    switch addDefaultNamespace(itemName) {
    case "minecraft:wooden_sword", "minecraft:wooden_pickaxe", "minecraft:wooden_axe", "minecraft:wooden_shovel", "minecraft:wooden_hoe":
        return 59
    case "minecraft:stone_sword", "minecraft:stone_pickaxe", "minecraft:stone_axe", "minecraft:stone_shovel", "minecraft:stone_hoe":
        return 131
    case "minecraft:iron_sword", "minecraft:iron_pickaxe", "minecraft:iron_axe", "minecraft:iron_shovel", "minecraft:iron_hoe", "minecraft:trident":
        return 250
    case "minecraft:golden_sword", "minecraft:golden_pickaxe", "minecraft:golden_axe", "minecraft:golden_shovel", "minecraft:golden_hoe":
        return 32
    case "minecraft:diamond_sword", "minecraft:diamond_pickaxe", "minecraft:diamond_axe", "minecraft:diamond_shovel", "minecraft:diamond_hoe":
        return 1561
    case "minecraft:netherite_sword", "minecraft:netherite_pickaxe", "minecraft:netherite_axe", "minecraft:netherite_shovel", "minecraft:netherite_hoe":
        return 2031
    case "minecraft:bow":
        return 384
    case "minecraft:crossbow":
        return 465
    case "minecraft:fishing_rod", "minecraft:carrot_on_a_stick":
        return 64
    case "minecraft:warped_fungus_on_a_stick":
        return 100
    case "minecraft:flint_and_steel":
        return 64
    case "minecraft:shears":
        return 238
    case "minecraft:shield":
        return 336
    case "minecraft:elytra":
        return 432
    case "minecraft:leather_helmet":
        return 55
    case "minecraft:leather_chestplate":
        return 80
    case "minecraft:leather_leggings":
        return 75
    case "minecraft:leather_boots":
        return 65
    case "minecraft:chainmail_helmet", "minecraft:iron_helmet":
        return 165
    case "minecraft:chainmail_chestplate", "minecraft:iron_chestplate":
        return 240
    case "minecraft:chainmail_leggings", "minecraft:iron_leggings":
        return 225
    case "minecraft:chainmail_boots", "minecraft:iron_boots":
        return 195
    case "minecraft:golden_helmet":
        return 77
    case "minecraft:golden_chestplate":
        return 112
    case "minecraft:golden_leggings":
        return 105
    case "minecraft:golden_boots":
        return 91
    case "minecraft:diamond_helmet":
        return 363
    case "minecraft:diamond_chestplate":
        return 528
    case "minecraft:diamond_leggings":
        return 495
    case "minecraft:diamond_boots":
        return 429
    case "minecraft:netherite_helmet":
        return 407
    case "minecraft:netherite_chestplate":
        return 592
    case "minecraft:netherite_leggings":
        return 555
    case "minecraft:netherite_boots":
        return 481
    case "minecraft:turtle_helmet":
        return 275
    default:
        return nil
    }
}

/// Coarse item classes used by enchantment applicability checks.
private enum WorldgenEnchantableItemKind {
    case other
    case book
    case helmet
    case chestplate
    case leggings
    case boots
    case sword
    case axe
    case pickaxe
    case shovel
    case hoe
    case bow
    case crossbow
    case fishingRod
    case trident
    case spear
    case mace
}

/// Maps an item ID onto the simplified enchantment compatibility classes.
private func worldgenEnchantableItemKind(for itemName: String) -> WorldgenEnchantableItemKind {
    switch addDefaultNamespace(itemName) {
    case "minecraft:book", "minecraft:enchanted_book":
        return .book
    case "minecraft:bow":
        return .bow
    case "minecraft:crossbow":
        return .crossbow
    case "minecraft:fishing_rod":
        return .fishingRod
    case "minecraft:trident":
        return .trident
    case "minecraft:mace":
        return .mace
    case "minecraft:turtle_helmet":
        return .helmet
    default:
        let normalizedItem = addDefaultNamespace(itemName)
        if normalizedItem.hasSuffix("_helmet") {
            return .helmet
        }
        if normalizedItem.hasSuffix("_chestplate") {
            return .chestplate
        }
        if normalizedItem.hasSuffix("_leggings") {
            return .leggings
        }
        if normalizedItem.hasSuffix("_boots") {
            return .boots
        }
        if normalizedItem.hasSuffix("_sword") {
            return .sword
        }
        if normalizedItem.hasSuffix("_pickaxe") {
            return .pickaxe
        }
        if normalizedItem.hasSuffix("_shovel") {
            return .shovel
        }
        if normalizedItem.hasSuffix("_hoe") {
            return .hoe
        }
        if normalizedItem.hasSuffix("_axe") {
            return .axe
        }
        if normalizedItem.hasSuffix("_spear") {
            return .spear
        }
        return .other
    }
}

/// Registry domains whose tags can be expanded during loot evaluation.
private enum LootTagDomain {
    case item
    case enchantment

    /// Converts a namespaced tag ID into the corresponding tag-registry key.
    func registryKey(for tagID: String) -> String {
        let normalizedTag = addDefaultNamespace(tagID)
        let parts = normalizedTag.split(separator: ":", maxSplits: 1).map(String.init)
        let namespace = parts.count == 2 ? parts[0] : "minecraft"
        let path = parts.count == 2 ? parts[1] : parts[0]

        switch self {
        case .item:
            return "\(namespace):item/\(path)"
        case .enchantment:
            return "\(namespace):enchantment/\(path)"
        }
    }
}

/// Returns the enchantment registries required by datapack-driven enchantment logic.
private func requireEnchantmentResources(_ context: LootContext) throws -> LootEnchantmentResources {
    guard let resources = context.enchantmentResources else {
        throw LootEvaluationError.missingContext("Enchantment resources are required for enchantment-based loot evaluation")
    }
    return resources
}

/// Loads one enchantment definition from the datapack registry.
private func loadedEnchantment(_ enchantmentID: String, resources: LootEnchantmentResources) -> Enchantment? {
    resources.enchantmentRegistry.get(RegistryKey(referencing: addDefaultNamespace(enchantmentID)))
}

/// Loads one enchantment definition or throws when the identifier is unknown.
private func requireEnchantment(_ enchantmentID: String, resources: LootEnchantmentResources) throws -> Enchantment {
    let normalizedID = addDefaultNamespace(enchantmentID)
    guard let enchantment = loadedEnchantment(normalizedID, resources: resources) else {
        throw LootEvaluationError.invalidData("Unknown enchantment \(normalizedID)")
    }
    return enchantment
}

/// Expands direct IDs and nested tags into a deduplicated identifier list.
private func resolveRegistryReferences(
    _ references: [TagValue],
    in domain: LootTagDomain,
    resources: LootEnchantmentResources,
    visitedTags: inout Set<String>,
    seenValues: inout Set<String>
) -> [String] {
    var resolved: [String] = []

    for reference in references {
        switch reference {
        case .rawID(let id):
            let normalized = addDefaultNamespace(id)
            if seenValues.insert(normalized).inserted {
                resolved.append(normalized)
            }
        case .tagID(let id):
            let tagKey = domain.registryKey(for: id)
            guard visitedTags.insert(tagKey).inserted else {
                continue
            }
            defer { visitedTags.remove(tagKey) }

            guard let tag = resources.tagRegistry.get(RegistryKey(referencing: tagKey)) else {
                continue
            }
            resolved += resolveRegistryReferences(
                tag.values,
                in: domain,
                resources: resources,
                visitedTags: &visitedTags,
                seenValues: &seenValues
            )
        }
    }

    return resolved
}

/// Convenience overload for expanding a `RegistryReferenceList`.
private func resolveRegistryReferences(
    _ references: RegistryReferenceList,
    in domain: LootTagDomain,
    resources: LootEnchantmentResources
) -> [String] {
    var visitedTags: Set<String> = []
    var seenValues: Set<String> = []
    return resolveRegistryReferences(
        references.values,
        in: domain,
        resources: resources,
        visitedTags: &visitedTags,
        seenValues: &seenValues
    )
}

/// Checks whether an item is present in a resolved item/tag reference list.
private func itemMatchesRegistryReferences(
    _ itemName: String,
    references: RegistryReferenceList,
    resources: LootEnchantmentResources
) -> Bool {
    let normalizedItem = addDefaultNamespace(itemName)
    return resolveRegistryReferences(references, in: .item, resources: resources).contains(normalizedItem)
}

/// Checks whether an enchantment can be applied to an item in world-generation loot.
private func isApplicableWorldgenEnchantment(
    _ enchantment: Enchantment,
    to itemName: String,
    useOverrides: Bool,
    resources: LootEnchantmentResources
) -> Bool {
    let itemKind = worldgenEnchantableItemKind(for: itemName)
    if itemKind == .book {
        return true
    }

    if useOverrides {
        return itemMatchesRegistryReferences(itemName, references: enchantment.supportedItems, resources: resources)
    }

    if let primaryItems = enchantment.primaryItems {
        return itemMatchesRegistryReferences(itemName, references: primaryItems, resources: resources)
    }

    return itemMatchesRegistryReferences(itemName, references: enchantment.supportedItems, resources: resources)
}

/// Returns the maximum level of an enchantment from datapack data.
private func maxLevelForEnchantment(_ enchantmentID: String, resources: LootEnchantmentResources) throws -> Int {
    try requireEnchantment(enchantmentID, resources: resources).maxLevel
}

/// Resolves and checks whether an enchantment ID can be applied to an item.
private func isApplicableWorldgenEnchantment(
    _ enchantmentID: String,
    to itemName: String,
    useOverrides: Bool,
    resources: LootEnchantmentResources
) throws -> Bool {
    try isApplicableWorldgenEnchantment(
        requireEnchantment(enchantmentID, resources: resources),
        to: itemName,
        useOverrides: useOverrides,
        resources: resources
    )
}

/// Checks whether two enchantments cannot coexist.
private func areEnchantmentsMutuallyExclusive(
    _ lhs: String,
    _ rhs: String,
    resources: LootEnchantmentResources
) throws -> Bool {
    let left = addDefaultNamespace(lhs)
    let right = addDefaultNamespace(rhs)
    if left == right {
        return true
    }

    let leftEnchantment = try requireEnchantment(left, resources: resources)
    let rightEnchantment = try requireEnchantment(right, resources: resources)
    let leftExclusive = Set(resolveRegistryReferences(leftEnchantment.exclusiveSet, in: .enchantment, resources: resources))
    let rightExclusive = Set(resolveRegistryReferences(rightEnchantment.exclusiveSet, in: .enchantment, resources: resources))
    return leftExclusive.contains(right) || rightExclusive.contains(left)
}

private func instrumentOptions(for options: String) -> [String] {
    switch addDefaultNamespace(options.replacingOccurrences(of: "#", with: "")) {
    case "minecraft:regular_goat_horns":
        return [
            "minecraft:ponder_goat_horn",
            "minecraft:sing_goat_horn",
            "minecraft:seek_goat_horn",
            "minecraft:feel_goat_horn"
        ]
    case "minecraft:screaming_goat_horns":
        return [
            "minecraft:admire_goat_horn",
            "minecraft:call_goat_horn",
            "minecraft:yearn_goat_horn",
            "minecraft:dream_goat_horn"
        ]
    case "minecraft:goat_horns":
        return instrumentOptions(for: "#minecraft:regular_goat_horns") + instrumentOptions(for: "#minecraft:screaming_goat_horns")
    default:
        if options.hasPrefix("#") {
            return []
        }
        return [addDefaultNamespace(options)]
    }
}

/// Applies the standard condition pipeline to a list of conditions.
private func allConditionsPass(_ conditions: [LootCondition], withContext context: LootContext) throws -> Bool {
    for condition in conditions {
        if try !condition.check(withContext: context) {
            return false
        }
    }
    return true
}

/// Applies several modifiers to several stacks in order.
private func applyingModifiers(
    _ modifiers: [ItemModifier],
    to stacks: [ItemStack],
    withContext context: LootContext
) throws -> [ItemStack] {
    var output: [ItemStack] = []
    output.reserveCapacity(stacks.count)
    for stack in stacks {
        var updated = stack
        for modifier in modifiers {
            updated = try modifier.apply(to: updated, withContext: context)
        }
        output.append(updated)
    }
    return output
}

/// Selects one weighted loot choice using the context RNG.
private func selectLootChoice(from choices: [ExpandedLootChoice], withContext context: LootContext) -> ExpandedLootChoice? {
    let eligible = choices.filter { $0.weight > 0 }
    guard !eligible.isEmpty else {
        return nil
    }
    if eligible.count == 1 {
        return eligible[0]
    }

    let totalWeight = eligible.reduce(0) { $0 + $1.weight }
    var cursor = Int(context.random.next(bound: UInt32(totalWeight)))
    for choice in eligible {
        cursor -= choice.weight
        if cursor < 0 {
            return choice
        }
    }
    return eligible.last
}

/// Expands one loot entry into weighted choices or immediate output.
private func expandLootEntry(
    _ entry: LootEntry,
    withContext context: LootContext,
    state: LootGenerationState
) throws -> LootEntryExpansion {
    switch entry {
    case let singleton as ItemEntry:
        return try expandSingletonEntry(singleton, withContext: context) { _, _ in
            [ItemStack(itemName: singleton.name, count: 1)]
        }
    case let singleton as EmptyEntry:
        return try expandSingletonEntry(singleton, withContext: context) { _, _ in
            []
        }
    case let singleton as LootTableEntry:
        return try expandSingletonEntry(singleton, withContext: context) { context, state in
            switch singleton.value {
            case .name(let name):
                guard let resolveTable = state.resolveTable else {
                    throw LootEvaluationError.missingContext("A loot table resolver is required to evaluate \(name)")
                }
                let normalizedName = addDefaultNamespace(name)
                let table = try resolveTable(normalizedName)
                return try table.generateLoot(
                    withContext: context,
                    state: state,
                    activeKey: .named(normalizedName)
                )
            case .table(let table):
                return try table.generateLoot(
                    withContext: context,
                    state: state,
                    activeKey: .inline(ObjectIdentifier(table))
                )
            }
        }
    case is DynamicEntry:
        throw LootEvaluationError.unsupported("dynamic loot entries are not needed for world-generation loot")
    case is TagEntry:
        throw LootEvaluationError.unsupported("tag loot entries are not needed for world-generation loot")
    case let composite as GroupEntry:
        return try expandGroupEntry(composite, withContext: context, state: state)
    case let composite as AlternativesEntry:
        return try expandAlternativesEntry(composite, withContext: context, state: state)
    case let composite as SequenceEntry:
        return try expandSequenceEntry(composite, withContext: context, state: state)
    default:
        throw LootEvaluationError.unsupported("Unsupported loot entry \(String(reflecting: type(of: entry)))")
    }
}

/// Expands a singleton entry if its conditions pass.
private func expandSingletonEntry(
    _ entry: SingletonLootEntry,
    withContext context: LootContext,
    generator: @escaping (LootContext, LootGenerationState) throws -> [ItemStack]
) throws -> LootEntryExpansion {
    guard try allConditionsPass(entry.conditions, withContext: context) else {
        return LootEntryExpansion(didExpand: false, choices: [])
    }

    let choice = ExpandedLootChoice(weight: max(entry.weight, 0)) { context, state in
        let generated = try generator(context, state)
        return try applyingModifiers(entry.functions, to: generated, withContext: context)
    }
    return LootEntryExpansion(didExpand: true, choices: [choice])
}

/// Expands all children of a `group` entry.
private func expandGroupEntry(
    _ entry: GroupEntry,
    withContext context: LootContext,
    state: LootGenerationState
) throws -> LootEntryExpansion {
    guard try allConditionsPass(entry.conditions, withContext: context) else {
        return LootEntryExpansion(didExpand: false, choices: [])
    }

    var choices: [ExpandedLootChoice] = []
    for child in entry.children {
        choices += try expandLootEntry(child, withContext: context, state: state).choices
    }
    return LootEntryExpansion(didExpand: true, choices: choices)
}

/// Expands a `sequence` entry until one child fails.
private func expandSequenceEntry(
    _ entry: SequenceEntry,
    withContext context: LootContext,
    state: LootGenerationState
) throws -> LootEntryExpansion {
    guard try allConditionsPass(entry.conditions, withContext: context) else {
        return LootEntryExpansion(didExpand: false, choices: [])
    }

    var choices: [ExpandedLootChoice] = []
    for child in entry.children {
        let expansion = try expandLootEntry(child, withContext: context, state: state)
        choices += expansion.choices
        if !expansion.didExpand {
            return LootEntryExpansion(didExpand: false, choices: choices)
        }
    }
    return LootEntryExpansion(didExpand: true, choices: choices)
}

/// Expands the first child of an `alternatives` entry that passes.
private func expandAlternativesEntry(
    _ entry: AlternativesEntry,
    withContext context: LootContext,
    state: LootGenerationState
) throws -> LootEntryExpansion {
    guard try allConditionsPass(entry.conditions, withContext: context) else {
        return LootEntryExpansion(didExpand: false, choices: [])
    }

    for child in entry.children {
        let expansion = try expandLootEntry(child, withContext: context, state: state)
        if expansion.didExpand {
            return expansion
        }
    }
    return LootEntryExpansion(didExpand: false, choices: [])
}

/// One candidate enchantment level together with its selection weight.
private struct WeightedEnchantmentChoice {
    let id: String
    let level: Int
    let weight: Int
}

/// Selects one weighted enchantment candidate using the context RNG.
private func chooseWeightedEnchantment(
    from choices: [WeightedEnchantmentChoice],
    withContext context: LootContext
) -> WeightedEnchantmentChoice {
    let totalWeight = choices.reduce(0) { $0 + $1.weight }
    var cursor = Int(context.random.next(bound: UInt32(totalWeight)))
    for choice in choices {
        cursor -= choice.weight
        if cursor < 0 {
            return choice
        }
    }
    return choices[choices.count - 1]
}

/// Returns the vanilla enchantability of an item used by `enchant_with_levels`.
private func enchantabilityForWorldgenItem(_ itemName: String) -> Int {
    switch addDefaultNamespace(itemName) {
    case "minecraft:leather_helmet",
        "minecraft:leather_chestplate",
        "minecraft:leather_leggings",
        "minecraft:leather_boots":
        return 15
    case "minecraft:iron_helmet",
        "minecraft:iron_chestplate",
        "minecraft:iron_leggings",
        "minecraft:iron_boots":
        return 9
    case "minecraft:golden_helmet",
        "minecraft:golden_chestplate",
        "minecraft:golden_leggings",
        "minecraft:golden_boots":
        return 25
    case "minecraft:diamond_helmet",
        "minecraft:diamond_chestplate",
        "minecraft:diamond_leggings",
        "minecraft:diamond_boots":
        return 10
    case "minecraft:fishing_rod", "minecraft:book", "minecraft:bow":
        return 1
    case "minecraft:iron_pickaxe",
        "minecraft:iron_axe",
        "minecraft:iron_hoe",
        "minecraft:iron_shovel",
        "minecraft:iron_sword":
        return 14
    case "minecraft:golden_pickaxe",
        "minecraft:golden_axe",
        "minecraft:golden_hoe",
        "minecraft:golden_shovel",
        "minecraft:golden_sword":
        return 22
    case "minecraft:diamond_pickaxe",
        "minecraft:diamond_axe",
        "minecraft:diamond_hoe",
        "minecraft:diamond_shovel",
        "minecraft:diamond_sword":
        return 10
    default:
        return 1
    }
}

/// Resolves an enchantment tag to concrete enchantment IDs.
private func enchantmentTagValues(
    for tag: String,
    itemName: String?,
    allowTreasure: Bool,
    useOverrides: Bool,
    resources: LootEnchantmentResources
) throws -> [String] {
    let normalizedTag = addDefaultNamespace(tag.replacingOccurrences(of: "#", with: ""))

    let resolved = resolveRegistryReferences(
        RegistryReferenceList(values: [.tagID(normalizedTag)]),
        in: .enchantment,
        resources: resources
    )
    guard !resolved.isEmpty else {
        return []
    }

    let applicable: [String]
    if let itemName {
        applicable = try resolved.filter {
            try isApplicableWorldgenEnchantment(
                $0,
                to: itemName,
                useOverrides: useOverrides,
                resources: resources
            )
        }
    } else {
        applicable = resolved
    }

    if allowTreasure {
        return applicable
    }
    return try applicable.filter { try !isTreasureEnchantment($0, resources: resources) }
}

/// Returns all enchantments applicable to an item in registry order.
private func worldgenApplicableEnchantments(
    for itemName: String,
    allowTreasure: Bool,
    useOverrides: Bool,
    resources: LootEnchantmentResources
) throws -> [String] {
    try resources.enchantmentRegistry.entries().compactMap { entry in
        let id = entry.key.name
        guard try isApplicableWorldgenEnchantment(id, to: itemName, useOverrides: useOverrides, resources: resources) else {
            return nil
        }
        if !allowTreasure, try isTreasureEnchantment(id, resources: resources) {
            return nil
        }
        return id
    }
}

/// Checks whether an enchantment is in the datapack's treasure tag.
private func isTreasureEnchantment(_ enchantmentID: String, resources: LootEnchantmentResources) throws -> Bool {
    let treasureEnchantments = try enchantmentTagValues(
        for: "#minecraft:treasure",
        itemName: nil,
        allowTreasure: true,
        useOverrides: true,
        resources: resources
    )
    return treasureEnchantments.contains(addDefaultNamespace(enchantmentID))
}

/// Returns the datapack-defined weight of an enchantment.
private func enchantmentWeight(_ enchantmentID: String, resources: LootEnchantmentResources) throws -> Int {
    try requireEnchantment(enchantmentID, resources: resources).weight
}

/// Builds the weighted enchantment choices available at an effective power level.
private func makeEnchantmentLevelChoices(
    from enchantments: [String],
    effectiveLevel: Int,
    resources: LootEnchantmentResources
) throws -> [WeightedEnchantmentChoice] {
    try enchantments.compactMap { enchantment in
        let normalized = addDefaultNamespace(enchantment)
        let level = try highestAllowedEnchantmentLevel(for: normalized, effectiveLevel: effectiveLevel, resources: resources)
        guard level > 0 else {
            return nil
        }
        return WeightedEnchantmentChoice(
            id: normalized,
            level: level,
            weight: try enchantmentWeight(normalized, resources: resources)
        )
    }
}

/// Returns the highest enchantment level allowed by the datapack cost windows.
private func highestAllowedEnchantmentLevel(
    for enchantmentID: String,
    effectiveLevel: Int,
    resources: LootEnchantmentResources
) throws -> Int {
    for level in stride(from: try maxLevelForEnchantment(enchantmentID, resources: resources), through: 1, by: -1) {
        if try isAllowedEnchantmentLevel(enchantmentID, level: level, effectiveLevel: effectiveLevel, resources: resources) {
            return level
        }
    }
    return 0
}

/// Checks whether one enchantment level is valid for an effective enchanting power.
private func isAllowedEnchantmentLevel(
    _ enchantmentID: String,
    level: Int,
    effectiveLevel: Int,
    resources: LootEnchantmentResources
) throws -> Bool {
    let enchantment = try requireEnchantment(enchantmentID, resources: resources)
    return effectiveLevel >= enchantment.minPower(for: level) && effectiveLevel <= enchantment.maxPower(for: level)
}
