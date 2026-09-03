import Foundation
import Testing
@testable import DPReader

private struct VanillaSchemaFixture {
    let minecraftVersion: String
    let packFormat: Version
}

private enum VanillaSchemaError: Error {
    case noVanillaDataFound
}

private let vanillaSchemaFixtures = [
    VanillaSchemaFixture(minecraftVersion: "1.21", packFormat: Version(major: 48, minor: 0)),
    VanillaSchemaFixture(minecraftVersion: "1.21.4", packFormat: Version(major: 61, minor: 0)),
    VanillaSchemaFixture(minecraftVersion: "1.21.9", packFormat: Version(major: 88, minor: 0)),
    VanillaSchemaFixture(minecraftVersion: "1.21.11", packFormat: Version(major: 94, minor: 1)),
    VanillaSchemaFixture(minecraftVersion: "26.1", packFormat: Version(major: 101, minor: 1)),
    VanillaSchemaFixture(minecraftVersion: "26.2", packFormat: Version(major: 107, minor: 1))
]

private func vanillaRoot(_ version: String, filePath: StaticString = #filePath) throws -> URL {
    let root = URL(fileURLWithPath: "\(filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla", isDirectory: true)
        .appendingPathComponent(version, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        throw VanillaSchemaError.noVanillaDataFound
    }
    return root
}

@Test func testRepresentativeVanillaSchemaPacksLoad() throws {
    for fixture in vanillaSchemaFixtures {
        let pack = try DataPack(fromRootPath: vanillaRoot(fixture.minecraftVersion))
        #expect(pack.packFormat == fixture.packFormat, "Unexpected format for vanilla \(fixture.minecraftVersion)")
    }
}

@Test func testRepresentativeVanillaLootTablesDecode() throws {
    for fixture in vanillaSchemaFixtures {
        let root = try vanillaRoot(fixture.minecraftVersion)
        let pack = try DataPack(
            fromRootPath: root,
            loadingOptions: [
                .noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions,
                .noBiomes, .noStructures, .noStructureSets, .noEnchantments,
                .noStructureTemplates, .noConfiguredCarvers, .noWorldClocks
            ]
        )
        let lootRoot = root.appendingPathComponent("data/minecraft/loot_table", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: lootRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            Issue.record("Could not enumerate vanilla \(fixture.minecraftVersion) loot tables")
            continue
        }
        var decodedCount = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            do {
                _ = try pack.makeDecoder().decode(LootTable.self, from: Data(contentsOf: url))
                decodedCount += 1
            } catch {
                Issue.record("Vanilla \(fixture.minecraftVersion) loot table \(url.path) failed: \(error)")
            }
        }
        #expect(decodedCount > 0, "No vanilla \(fixture.minecraftVersion) loot tables were decoded")
    }
}
