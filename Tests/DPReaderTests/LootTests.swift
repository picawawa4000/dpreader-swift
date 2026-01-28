import Foundation
import Testing
@testable import DPReader

@Test func testEncodingForItemLootEntry() async throws {
    let lootEntry: any LootEntry = ItemEntry(name: "minecraft:diamond", weight: 5, quality: 2)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:item",
        "name": "minecraft:diamond",
        "weight": 5,
        "quality": 2
    ]))
}

@Test func testEncodingForLootTableLootEntry() async throws {
    let lootEntry: any LootEntry = LootTableEntry(value: .name("test:example"), weight: 3, quality: 1)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    print(String(data: data, encoding: .utf8)!)
    #expect(try checkJSON(data, [
        "type": "minecraft:loot_table",
        "value": "test:example",
        "weight": 3,
        "quality": 1
    ]))
}

@Test func testEncodingForDynamicLootEntryShulkerBoxContents() async throws {
    let dynamicType = DynamicEntry.DynamicType.shulkerBoxContents
    let lootEntry: any LootEntry = DynamicEntry(type: dynamicType, weight: 4, quality: 0)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:dynamic",
        "name": "contents",
        "weight": 4,
        "quality": 0
    ]))
}

@Test func testEncodingForDynamicLootEntryDecoratedPotSherds() async throws {
    let dynamicType = DynamicEntry.DynamicType.decoratedPotSherds
    let lootEntry: any LootEntry = DynamicEntry(type: dynamicType, weight: 6, quality: -1)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:dynamic",
        "name": "sherds",
        "weight": 6,
        "quality": -1
    ]))
}

@Test func testEncodingForEmptyLootEntry() async throws {
    let lootEntry: any LootEntry = EmptyEntry(weight: 10, quality: 2)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:empty",
        "weight": 10,
        "quality": 2
    ]))
}

@Test func testEncodingForTagLootEntryNonExpanding() async throws {
    let lootEntry: any LootEntry = TagEntry(name: "test:example", expand: false, weight: 3, quality: 6)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:tag",
        "weight": 3,
        "quality": 6,
        "expand": false,
        "name": "test:example"
    ]))
}

@Test func testEncodingForTagLootEntryExpanding() async throws {
    let lootEntry: any LootEntry = TagEntry(name: "test:example", expand: true, weight: 5, quality: 0)
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:tag",
        "weight": 5,
        "quality": 0,
        "expand": true,
        "name": "test:example"
    ]))
}

@Test func testEncodingForGroupLootEntry() async throws {
    let lootEntry: any LootEntry = GroupEntry(children: [
        ItemEntry(name: "minecraft:diamond", weight: 1, quality: 1),
        EmptyEntry(weight: 3, quality: 0)
    ])
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:group",
        "children": [
            [
                "type": "minecraft:item",
                "name": "minecraft:diamond",
                "weight": 1,
                "quality": 1
            ],
            [
                "type": "minecraft:empty",
                "weight": 3,
                "quality": 0
            ]
        ]
    ]))
}

@Test func testEncodingForAlternativesLootEntry() async throws {
    let lootEntry: any LootEntry = AlternativesEntry(children: [
        ItemEntry(name: "minecraft:diamond", weight: 1, quality: 1),
        EmptyEntry(weight: 3, quality: 0)
    ])
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:alternatives",
        "children": [
            [
                "type": "minecraft:item",
                "name": "minecraft:diamond",
                "weight": 1,
                "quality": 1
            ],
            [
                "type": "minecraft:empty",
                "weight": 3,
                "quality": 0
            ]
        ]
    ]))
}

@Test func testEncodingForSequenceLootEntry() async throws {
    let lootEntry: any LootEntry = SequenceEntry(children: [
        ItemEntry(name: "minecraft:diamond", weight: 1, quality: 1),
        EmptyEntry(weight: 3, quality: 0)
    ])
    let encoder = JSONEncoder()
    let data = try encoder.encode(lootEntry)
    #expect(try checkJSON(data, [
        "type": "minecraft:sequence",
        "children": [
            [
                "type": "minecraft:item",
                "name": "minecraft:diamond",
                "weight": 1,
                "quality": 1
            ],
            [
                "type": "minecraft:empty",
                "weight": 3,
                "quality": 0
            ]
        ]
    ]))
}

@Test func testDecodingForItemLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:item",
        "name": "minecraft:diamond",
        "weight": 5,
        "quality": 1
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is ItemEntry)
    let itemEntry = lootEntry as! ItemEntry
    #expect(itemEntry.name == "minecraft:diamond")
    #expect(itemEntry.weight == 5)
    #expect(itemEntry.quality == 1)
}

@Test func testDecodingForLootTableLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:loot_table",
        "value": "test:example",
        "weight": 4,
        "quality": 3
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is LootTableEntry)
    let lootTableEntry = lootEntry as! LootTableEntry
    #expect(lootTableEntry.weight == 4)
    #expect(lootTableEntry.quality == 3)
    switch lootTableEntry.value {
        case .name(let name):
            #expect(name == "test:example")
        default:
            // too lazy to add a new exception
            #expect(Bool(false), "LootTableEntry.value != name!")
    }
}

@Test func testDecodingForDynamicLootEntryShulkerBoxContents() async throws {
    let data = """
    {
        "type": "minecraft:dynamic",
        "name": "contents"
    }
    """.data(using: .utf8)! // weight defaults to 1, quality defaults to 0
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is DynamicEntry)
    let dynamicLootEntry = lootEntry as! DynamicEntry
    #expect(dynamicLootEntry.weight == 1)
    #expect(dynamicLootEntry.quality == 0)
    #expect(dynamicLootEntry.type == .shulkerBoxContents)
}

@Test func testDecodingForDynamicLootEntryDecoratedPotSherds() async throws {
    let data = """
    {
        "type": "minecraft:dynamic",
        "name": "sherds"
    }
    """.data(using: .utf8)! // weight defaults to 1, quality defaults to 0
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is DynamicEntry)
    let dynamicLootEntry = lootEntry as! DynamicEntry
    #expect(dynamicLootEntry.weight == 1)
    #expect(dynamicLootEntry.quality == 0)
    #expect(dynamicLootEntry.type == .decoratedPotSherds)
}

@Test func testDecodingForEmptyLootEntryDefaults() async throws {
    let data = """
    {
        "type": "minecraft:empty"
    }
    """.data(using: .utf8)! // weight defaults to 1, quality defaults to 0
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is EmptyEntry)
    let emptyEntry = lootEntry as! EmptyEntry
    #expect(emptyEntry.weight == 1)
    #expect(emptyEntry.quality == 0)
}

@Test func testDecodingForTagLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:tag",
        "name": "test:example",
        "expand": true,
        "weight": 7,
        "quality": -2
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is TagEntry)
    let tagEntry = lootEntry as! TagEntry
    #expect(tagEntry.name == "test:example")
    #expect(tagEntry.expand == true)
    #expect(tagEntry.weight == 7)
    #expect(tagEntry.quality == -2)
}

@Test func testDecodingForGroupLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:group",
        "children": [
            { "type": "minecraft:item", "name": "minecraft:diamond", "weight": 2, "quality": 1 },
            { "type": "minecraft:empty" }
        ]
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is GroupEntry)
    let groupEntry = lootEntry as! GroupEntry
    #expect(groupEntry.children.count == 2)
    #expect(groupEntry.children[0] is ItemEntry)
    #expect(groupEntry.children[1] is EmptyEntry)
    let itemEntry = groupEntry.children[0] as! ItemEntry
    #expect(itemEntry.name == "minecraft:diamond")
    #expect(itemEntry.weight == 2)
    #expect(itemEntry.quality == 1)
    let emptyEntry = groupEntry.children[1] as! EmptyEntry
    #expect(emptyEntry.weight == 1)
    #expect(emptyEntry.quality == 0)
}

@Test func testDecodingForAlternativesLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:alternatives",
        "children": [
            { "type": "minecraft:item", "name": "minecraft:emerald" },
            { "type": "minecraft:empty", "weight": 4, "quality": 3 }
        ]
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is AlternativesEntry)
    let alternativesEntry = lootEntry as! AlternativesEntry
    #expect(alternativesEntry.children.count == 2)
    #expect(alternativesEntry.children[0] is ItemEntry)
    #expect(alternativesEntry.children[1] is EmptyEntry)
    let itemEntry = alternativesEntry.children[0] as! ItemEntry
    #expect(itemEntry.name == "minecraft:emerald")
    #expect(itemEntry.weight == 1)
    #expect(itemEntry.quality == 0)
    let emptyEntry = alternativesEntry.children[1] as! EmptyEntry
    #expect(emptyEntry.weight == 4)
    #expect(emptyEntry.quality == 3)
}

@Test func testDecodingForSequenceLootEntry() async throws {
    let data = """
    {
        "type": "minecraft:sequence",
        "children": [
            { "type": "minecraft:item", "name": "minecraft:gold_ingot", "weight": 3, "quality": 2 },
            { "type": "minecraft:empty" }
        ]
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let lootEntry = try decoder.decode(LootEntryInitializer.self, from: data).value
    #expect(lootEntry is SequenceEntry)
    let sequenceEntry = lootEntry as! SequenceEntry
    #expect(sequenceEntry.children.count == 2)
    #expect(sequenceEntry.children[0] is ItemEntry)
    #expect(sequenceEntry.children[1] is EmptyEntry)
    let itemEntry = sequenceEntry.children[0] as! ItemEntry
    #expect(itemEntry.name == "minecraft:gold_ingot")
    #expect(itemEntry.weight == 3)
    #expect(itemEntry.quality == 2)
    let emptyEntry = sequenceEntry.children[1] as! EmptyEntry
    #expect(emptyEntry.weight == 1)
    #expect(emptyEntry.quality == 0)
}
