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
