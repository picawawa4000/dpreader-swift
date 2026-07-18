import Foundation
import Testing
@testable import DPReader

private let lootPackRoot = URL(filePath: "Tests/Resources/Datapacks/Loot/loot")
private let enchantmentPackRoot = URL(filePath: "Tests/Resources/Datapacks/Enchantments/enchantments")
private let vanilla12111Root = URL(filePath: "vanilla/1.21.11")
private let vanilla12111ReferenceURL = URL(filePath: "Tests/Resources/Loot/vanilla_1_21_11_reference.json")

private func minimalRegistryLoadingOptions(excluding extra: DataPackRegistryLoadingOptions = []) -> DataPackRegistryLoadingOptions {
    [
        .noDensityFunctions,
        .noNoises,
        .noNoiseSettings,
        .noDimensions,
        .noBiomes,
        .noStructures,
        .noStructureSets,
        extra
    ].reduce(into: DataPackRegistryLoadingOptions(rawValue: 0)) { $0.formUnion($1) }
}

private func makeContext(seed: UInt64 = 0, enchantmentResources: LootEnchantmentResources? = nil) -> LootContext {
    LootContext(random: XoroshiroRandom(seed: seed), enchantmentResources: enchantmentResources)
}

private func makeCheckedContext(seed: UInt64, enchantmentResources: LootEnchantmentResources? = nil) -> LootContext {
    LootContext(random: CheckedRandom(seed: seed), enchantmentResources: enchantmentResources)
}

private func loadEnchantmentTestResources() throws -> LootEnchantmentResources {
    let pack = try DataPack(fromRootPath: enchantmentPackRoot, loadingOptions: minimalRegistryLoadingOptions())
    return pack.lootEnchantmentResources
}

private func loadVanilla12111EnchantmentResources() throws -> LootEnchantmentResources {
    let pack = try DataPack(fromRootPath: vanilla12111Root, loadingOptions: minimalRegistryLoadingOptions())
    return pack.lootEnchantmentResources
}

private func decodeLootTable(_ identifier: String, from root: URL = lootPackRoot) throws -> LootTable {
    let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
    let namespace = parts.count == 2 ? parts[0] : "minecraft"
    let path = parts.count == 2 ? parts[1] : parts[0]
    let url = root
        .appendingPathComponent("data")
        .appendingPathComponent(namespace)
        .appendingPathComponent("loot_table")
        .appendingPathComponent(path + ".json")
    return try JSONDecoder().decode(LootTable.self, from: Data(contentsOf: url))
}

private func makeLootDecoder(packFormat: Version = .assumedCurrent) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.setDPReaderVersioning(PackVersioning(supportedVersions: .exactly(packFormat), selectedVersion: packFormat))
    return decoder
}

private func makeTemporaryPackRoot(packFormat: Version) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    let metadata = """
    {
        "pack": {
            "pack_format": \(packFormat.description),
            "description": "Test pack"
        }
    }
    """
    try metadata.data(using: .utf8)!.write(to: root.appendingPathComponent("pack.mcmeta"))
    return root
}

private struct RealWorldLootFixture: Decodable {
    let version: String
    let cases: [RealWorldLootCase]
}

private struct RealWorldLootCase: Decodable {
    let table: String
    let xppleName: String
    let seed: UInt64
    let items: [NormalizedLootItem]

    enum CodingKeys: String, CodingKey {
        case table
        case xppleName = "xpple_name"
        case seed
        case items
    }
}

private struct NormalizedLootItem: Decodable, Equatable {
    let name: String
    let count: Int
    let enchantments: [NormalizedEnchantment]
    let mobEffect: NormalizedMobEffect?

    enum CodingKeys: String, CodingKey {
        case name
        case count
        case enchantments
        case mobEffect = "mob_effect"
    }
}

private struct NormalizedEnchantment: Decodable, Equatable {
    let id: String
    let level: Int
}

private struct NormalizedMobEffect: Decodable, Equatable {
    let id: String
    let duration: Int
}

private func normalizedEnchantmentID(_ id: String) -> String {
    switch id {
    case "minecraft:binding_curse":
        return "minecraft:curse_of_binding"
    case "minecraft:vanishing_curse":
        return "minecraft:curse_of_vanishing"
    default:
        return id
    }
}

private func normalizeGeneratedLoot(_ items: [ItemStack]) -> [NormalizedLootItem] {
    items.map { item in
        let enchantments = item.enchantmentLevels
            .map { NormalizedEnchantment(id: normalizedEnchantmentID($0.key), level: $0.value) }
            .sorted { $0.id < $1.id }

        let mobEffect: NormalizedMobEffect?
        if
            case .array(let effects)? = item.components["minecraft:suspicious_stew_effects"],
            let first = effects.first?.objectValue,
            let id = first["id"]?.stringValue,
            let duration = first["duration"]?.intValue
        {
            mobEffect = NormalizedMobEffect(id: id, duration: duration)
        } else {
            mobEffect = nil
        }

        let normalizedName: String
        if item.itemName == "minecraft:enchanted_book", !enchantments.isEmpty {
            normalizedName = "minecraft:book"
        } else {
            normalizedName = item.itemName
        }

        return NormalizedLootItem(
            name: normalizedName,
            count: item.count,
            enchantments: enchantments,
            mobEffect: mobEffect
        )
    }
}

private func normalizeExpectedLoot(_ items: [NormalizedLootItem]) -> [NormalizedLootItem] {
    items.map {
        NormalizedLootItem(
            name: $0.name,
            count: $0.count,
            enchantments: $0.enchantments
                .map { NormalizedEnchantment(id: normalizedEnchantmentID($0.id), level: $0.level) }
                .sorted { $0.id < $1.id },
            mobEffect: $0.mobEffect
        )
    }
}

@Test func testEncodingForItemLootEntry() throws {
    let lootEntry: any LootEntry = ItemEntry(name: "minecraft:diamond", weight: 5, quality: 2)
    let data = try JSONEncoder().encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:item",
        "name": "minecraft:diamond",
        "weight": 5,
        "quality": 2
    ]))
}

@Test func testEncodingForLootTableLootEntry() throws {
    let lootEntry: any LootEntry = LootTableEntry(value: .name("test:chests/subtable"), weight: 3, quality: 1)
    let data = try JSONEncoder().encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:loot_table",
        "value": "test:chests/subtable",
        "weight": 3,
        "quality": 1
    ]))
}

@Test func testDecodingLootTableFunctionsAndConditions() throws {
    let data = """
    {
        "type": "minecraft:block",
        "functions": [
            {
                "function": "minecraft:explosion_decay"
            }
        ],
        "pools": [
            {
                "rolls": 1.0,
                "bonus_rolls": 0.0,
                "conditions": [
                    {
                        "condition": "minecraft:random_chance",
                        "chance": 0.5
                    }
                ],
                "entries": [
                    {
                        "type": "minecraft:item",
                        "name": "minecraft:stick",
                        "conditions": [
                            {
                                "condition": "minecraft:survives_explosion"
                            }
                        ],
                        "functions": [
                            {
                                "function": "minecraft:set_count",
                                "count": 2,
                                "add": false
                            }
                        ]
                    }
                ]
            }
        ],
        "random_sequence": "minecraft:blocks/example"
    }
    """.data(using: .utf8)!

    let table = try JSONDecoder().decode(LootTable.self, from: data)
    #expect(table.type == "minecraft:block")
    #expect(table.randomSequenceLocation == "minecraft:blocks/example")
    #expect(table.functions.count == 1)
    #expect(table.functions[0] is ExplosionDecayItemModifier)
    #expect(table.pools.count == 1)
    #expect(table.pools[0].conditions.count == 1)
    #expect(table.pools[0].conditions[0] is RandomChanceLootCondition)

    let itemEntry = table.pools[0].entries[0] as! ItemEntry
    #expect(itemEntry.conditions.count == 1)
    #expect(itemEntry.conditions[0] is SurvivesExplosionLootCondition)
    #expect(itemEntry.functions.count == 1)
    #expect(itemEntry.functions[0] is SetCountItemModifier)
}

@Test func testDecodingEnchantWithLevelsTreasureFlag() throws {
    let data = """
    {
        "function": "minecraft:enchant_with_levels",
        "levels": 30,
        "options": "minecraft:infinity",
        "treasure": false
    }
    """.data(using: .utf8)!

    let modifier = try JSONDecoder().decode(ItemModifierInitializer.self, from: data).value
    let enchantWithLevels = modifier as! EnchantWithLevelsItemModifier
    #expect(enchantWithLevels.treasure == false)
}

@Test func testSetPotionModifierEvaluation() throws {
    let modifier = SetPotionItemModifier(id: "minecraft:water")
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:potion", count: 1),
        withContext: makeContext()
    )

    #expect(updated.components["minecraft:potion_contents"] == .object(["potion": .string("minecraft:water")]))
}

@Test func testNewLootFunctionsRequirePackFormat95() throws {
    let packFormat = Version(major: 92, minor: 0)

    for function in ["minecraft:set_random_dyes", "minecraft:set_random_potion"] {
        let data = """
        {
            "function": "\(function)"
        }
        """.data(using: .utf8)!

        do {
            _ = try makeLootDecoder(packFormat: packFormat).decode(ItemModifierInitializer.self, from: data)
            Issue.record("Expected \(function) to be rejected in pack format \(packFormat)")
        } catch let error as DecodingError {
            guard case .dataCorrupted(let context) = error else {
                Issue.record("Expected dataCorrupted for \(function), got \(error)")
                continue
            }
            #expect(context.debugDescription.contains("supported versions: 95.0+"))
        }
    }
}

@Test func testNewLootFunctionsLoadInPackFormat95() throws {
    let data = """
    {
        "type": "minecraft:block",
        "functions": [
            {
                "function": "minecraft:set_random_dyes"
            },
            {
                "function": "minecraft:set_random_potion"
            }
        ],
        "pools": [
            {
                "rolls": 1,
                "entries": [
                    {
                        "type": "minecraft:item",
                        "name": "minecraft:bundle"
                    }
                ]
            }
        ]
    }
    """.data(using: .utf8)!

    let table = try makeLootDecoder(packFormat: Version(major: 95, minor: 0)).decode(LootTable.self, from: data)
    #expect(table.functions.count == 2)
    #expect(table.functions[0] is SetRandomDyesItemModifier)
    #expect(table.functions[1] is SetRandomPotionItemModifier)
}

@Test func testNewLootFunctionsAreUnimplementedInPackFormat95() throws {
    let functions: [(String, any ItemModifier.Type)] = [
        ("minecraft:set_random_dyes", SetRandomDyesItemModifier.self),
        ("minecraft:set_random_potion", SetRandomPotionItemModifier.self)
    ]

    for (function, expectedType) in functions {
        let data = """
        {
            "function": "\(function)"
        }
        """.data(using: .utf8)!

        let modifier = try makeLootDecoder(packFormat: Version(major: 95, minor: 0)).decode(ItemModifierInitializer.self, from: data).value
        #expect(type(of: modifier) == expectedType)

        do {
            _ = try modifier.apply(to: ItemStack(itemName: "minecraft:bundle", count: 1), withContext: makeContext())
            Issue.record("Expected \(function) to be unimplemented during evaluation")
        } catch let error as LootEvaluationError {
            guard case .unimplemented(let message) = error else {
                Issue.record("Expected unimplemented for \(function), got \(error)")
                continue
            }
            #expect(message.contains(function.replacingOccurrences(of: "minecraft:", with: "")))
        }
    }
}

@Test func testDataPackDecoderUsesPackMetadataFormat() throws {
    let pack92Root = try makeTemporaryPackRoot(packFormat: Version(major: 92, minor: 0))
    let pack95Root = try makeTemporaryPackRoot(packFormat: Version(major: 95, minor: 0))
    defer {
        try? FileManager.default.removeItem(at: pack92Root)
        try? FileManager.default.removeItem(at: pack95Root)
    }

    let data = """
    {
        "function": "minecraft:set_random_potion"
    }
    """.data(using: .utf8)!

    let pack92 = try DataPack(fromRootPath: pack92Root, loadingOptions: minimalRegistryLoadingOptions())
    #expect(pack92.packFormat == Version(major: 92, minor: 0))
    do {
        _ = try pack92.makeDecoder().decode(ItemModifierInitializer.self, from: data)
        Issue.record("Expected pack.mcmeta format 92.0 to reject minecraft:set_random_potion")
    } catch let error as DecodingError {
        guard case .dataCorrupted(let context) = error else {
            Issue.record("Expected dataCorrupted for pack format 92.0, got \(error)")
            return
        }
        #expect(context.debugDescription.contains("supported versions: 95.0+"))
    }

    let pack95 = try DataPack(fromRootPath: pack95Root, loadingOptions: minimalRegistryLoadingOptions())
    #expect(pack95.packFormat == Version(major: 95, minor: 0))
    let modifier = try pack95.makeDecoder().decode(ItemModifierInitializer.self, from: data).value
    #expect(modifier is SetRandomPotionItemModifier)
}

@Test func testSetStewEffectModifierEvaluation() throws {
    let modifier = SetStewEffectItemModifier(effects: [
        StewEffect(type: "minecraft:speed", duration: ConstantLootNumberProvider(value: 5.0))
    ])
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:suspicious_stew", count: 1),
        withContext: makeContext()
    )

    #expect(updated.components["minecraft:suspicious_stew_effects"] == .array([
        .object([
            "id": .string("minecraft:speed"),
            "duration": .integer(100)
        ])
    ]))
}

@Test func testSetDamageModifierEvaluation() throws {
    let modifier = SetDamageItemModifier(damage: ConstantLootNumberProvider(value: 0.25))
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:iron_sword", count: 1),
        withContext: makeContext()
    )

    #expect(updated.components["minecraft:damage"] == JSONValue.integer(187))
}

@Test func testSetInstrumentModifierEvaluation() throws {
    let modifier = SetInstrumentItemModifier(options: "minecraft:ponder_goat_horn")
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:goat_horn", count: 1),
        withContext: makeContext(seed: 99)
    )

    #expect(updated.components["minecraft:instrument"] == .string("minecraft:ponder_goat_horn"))
}

@Test func testEnchantRandomlyModifierEvaluation() throws {
    let resources = try loadVanilla12111EnchantmentResources()
    let modifier = EnchantRandomlyItemModifier(options: .string("minecraft:infinity"))
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:book", count: 1),
        withContext: makeContext(seed: 1, enchantmentResources: resources)
    )

    #expect(updated.itemName == "minecraft:enchanted_book")
    #expect(updated.enchantmentLevels == ["minecraft:infinity": 1])
}

@Test func testEnchantWithLevelsModifierEvaluation() throws {
    let resources = try loadVanilla12111EnchantmentResources()
    let modifier = EnchantWithLevelsItemModifier(
        levels: ConstantLootNumberProvider(value: 30.0),
        options: .string("minecraft:infinity")
    )
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:book", count: 1),
        withContext: makeContext(seed: 2, enchantmentResources: resources)
    )

    #expect(updated.itemName == "minecraft:enchanted_book")
    #expect(updated.enchantmentLevels == ["minecraft:infinity": 1])
}

@Test func testEnchantRandomlyUsesSupportedItemsFromLoadedEnchantments() throws {
    let resources = try loadEnchantmentTestResources()
    let modifier = EnchantRandomlyItemModifier(options: .string("#test:on_random_loot"))
    let updated = try modifier.apply(
        to: ItemStack(itemName: "minecraft:iron_axe", count: 1),
        withContext: makeContext(seed: 7, enchantmentResources: resources)
    )

    #expect(updated.itemName == "minecraft:iron_axe")
    #expect(updated.enchantmentLevels.keys.sorted() == ["test:edge"])
    #expect((updated.enchantmentLevels["test:edge"] ?? 0) >= 1)
    #expect((updated.enchantmentLevels["test:edge"] ?? 0) <= 3)
}

@Test func testEnchantWithLevelsUsesPrimaryItemsFromLoadedEnchantments() throws {
    let resources = try loadEnchantmentTestResources()
    let modifier = EnchantWithLevelsItemModifier(
        levels: ConstantLootNumberProvider(value: 5.0)
    )

    let unsupportedPrimary = try modifier.apply(
        to: ItemStack(itemName: "minecraft:iron_axe", count: 1),
        withContext: makeContext(seed: 2, enchantmentResources: resources)
    )
    #expect(unsupportedPrimary.enchantmentLevels.isEmpty)

    let supportedPrimary = try modifier.apply(
        to: ItemStack(itemName: "minecraft:iron_sword", count: 1),
        withContext: makeContext(seed: 2, enchantmentResources: resources)
    )
    #expect(supportedPrimary.enchantmentLevels == ["test:edge": 3])
}

@Test func testNestedLootTableGenerationFromDatapack() throws {
    let resolver: LootTableResolver = { try decodeLootTable($0) }
    let table = try decodeLootTable("test:chests/nested")
    let generated = try table.generateLoot(withContext: makeContext(seed: 3), resolvingTables: resolver)

    #expect(generated.count == 1)
    #expect(generated[0].itemName == "minecraft:golden_apple")
    #expect(generated[0].count == 3)
    #expect(generated[0].components["minecraft:custom_name"] == .object(["text": .string("debug-table")]))
}

@Test func testAlternativesLootTableGenerationFromDatapack() throws {
    let table = try decodeLootTable("test:chests/alternatives")
    let generated = try table.generateLoot(withContext: makeContext(seed: 4))

    #expect(generated.count == 1)
    #expect(generated[0].itemName == "minecraft:emerald")
}

@Test func testSequenceLootTableGenerationFromDatapack() throws {
    let table = try decodeLootTable("test:chests/sequence")
    let generated = try table.generateLoot(withContext: makeContext(seed: 5))

    #expect(generated.count == 1)
    #expect(generated[0].itemName == "minecraft:book")
}

@Test func testGroupLootTableGenerationFromDatapack() throws {
    let table = try decodeLootTable("test:chests/group")
    let generated = try table.generateLoot(withContext: makeContext(seed: 6))

    #expect(generated.count == 1)
    #expect(generated[0].itemName == "minecraft:coal")
}

@Test func testVanilla12111LootTablesAgainstCubiomesReference() throws {
    let fixture = try JSONDecoder().decode(RealWorldLootFixture.self, from: Data(contentsOf: vanilla12111ReferenceURL))
    #expect(fixture.version == "1.21.11")
    let resources = try loadVanilla12111EnchantmentResources()

    for testCase in fixture.cases {
        let table = try decodeLootTable(testCase.table, from: vanilla12111Root)
        let generated = try table.generateLoot(withContext: makeCheckedContext(seed: testCase.seed, enchantmentResources: resources))
        let normalized = normalizeGeneratedLoot(generated)
        #expect(
            normalized == normalizeExpectedLoot(testCase.items),
            "\(testCase.table) / \(testCase.xppleName) / seed \(testCase.seed)"
        )
    }
}
