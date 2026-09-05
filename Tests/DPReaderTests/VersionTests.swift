import Foundation
import Testing
@testable import DPReader

private func makePackRoot(withPackMetadata metadata: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    try metadata.data(using: .utf8)!.write(to: root.appendingPathComponent("pack.mcmeta"))
    return root
}

@Test func testVersionRangeContainsExpectedFormats() {
    let exact = VersionRange.exactly(Version(major: 92, minor: 0))
    #expect(exact.contains(Version(major: 92, minor: 0)))
    #expect(!exact.contains(Version(major: 95, minor: 0)))

    let range = VersionRange.between(Version(major: 94, minor: 1), Version(major: 95, minor: 0))
    #expect(!range.contains(Version(major: 94, minor: 0)))
    #expect(range.contains(Version(major: 94, minor: 1)))
    #expect(range.contains(Version(major: 95, minor: 0)))
    #expect(!range.contains(Version(major: 95, minor: 1)))
}

@Test func testLatestSupportedPackFormatIs119() {
    #expect(Version.latestSupported == Version(major: 119, minor: 0))
}

@Test func testDataPackRequiresExplicitMetadataVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try DataPack(
            fromRootPath: root,
            loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments],
            decodingVersion: .latestSupported
        )
        Issue.record("Expected a data pack without pack.mcmeta to be rejected")
    } catch let error as DataPack.LoadingErrors {
        guard case .invalidPackMetadata(let message) = error else {
            Issue.record("Expected invalidPackMetadata, got \(error)")
            return
        }
        #expect(message.contains("pack.mcmeta"))
        #expect(message.contains("declare"))
    }
}

@Test func testDataPackSupportsLatestPackFormat() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [119, 0],
            "max_format": [119, 0],
            "description": "26.3-pre-1 test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(
        fromRootPath: root,
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments]
    )
    #expect(pack.packFormat == .latestSupported)
}

@Test func testDataPackUsesHighestDeclaredVersionByDefault() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [94, 1],
            "max_format": 95,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(fromRootPath: root, loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments])

    #expect(pack.packFormat == Version(major: 95, minor: 0))
    #expect(pack.versioning.supportedVersions == VersionRange.between(Version(major: 94, minor: 1), Version(major: 95, minor: Int.max)))
}

@Test func testDataPackAllowsExplicitSupportedDecodingVersion() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [94, 1],
            "max_format": 95,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(
        fromRootPath: root,
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments],
        decodingVersion: Version(major: 94, minor: 1)
    )

    #expect(pack.packFormat == Version(major: 94, minor: 1))
    #expect(pack.versioning.supportedVersions.contains(pack.packFormat))
}

@Test func testFormat82MetadataAcceptsOneElementVersionLists() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [82],
            "max_format": [82],
            "description": "One-element version list"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(
        fromRootPath: root,
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments]
    )
    #expect(pack.packFormat == Version(major: 82, minor: 0))
    #expect(pack.versioning.supportedVersions.maximum == Version(major: 82, minor: Int.max))
}

@Test func testFormat82MetadataRejectsNonVanillaVersionShapes() throws {
    let root = try makePackRoot(withPackMetadata: """
    {"pack":{"min_format":"82.0","max_format":82,"description":"Invalid"}}
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try DataPack(fromRootPath: root)
        Issue.record("Expected string-valued min_format to be rejected")
    } catch {
        #expect(String(describing: error).contains("integer or a list"))
    }
}

@Test func testDataPackRejectsUnsupportedDecodingVersion() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": 92,
            "max_format": 92,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try DataPack(
            fromRootPath: root,
            loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments],
            decodingVersion: Version(major: 95, minor: 0)
        )
        Issue.record("Expected unsupported decoding version to be rejected")
    } catch let error as DataPack.LoadingErrors {
        guard case let .unsupportedPackVersion(selected, supported) = error else {
            Issue.record("Expected unsupportedPackVersion, got \(error)")
            return
        }
        #expect(selected == Version(major: 95, minor: 0))
        #expect(supported == VersionRange.between(
            Version(major: 92, minor: 0),
            Version(major: 92, minor: Int.max)
        ))
    }
}

@Test func testMetadataRejectsFieldsFromTheWrongSchemaEra() throws {
    let legacyRoot = try makePackRoot(withPackMetadata: """
    {"pack":{"pack_format":81,"min_format":81,"max_format":81,"description":"Invalid"}}
    """)
    let modernRoot = try makePackRoot(withPackMetadata: """
    {"pack":{"pack_format":82,"supported_formats":82,"description":"Invalid"}}
    """)
    defer {
        try? FileManager.default.removeItem(at: legacyRoot)
        try? FileManager.default.removeItem(at: modernRoot)
    }

    for root in [legacyRoot, modernRoot] {
        do {
            _ = try DataPack(fromRootPath: root)
            Issue.record("Expected wrong-era pack metadata fields to be rejected")
        } catch let error as DataPack.LoadingErrors {
            guard case .invalidPackMetadata(let message) = error else {
                Issue.record("Expected invalidPackMetadata, got \(error)")
                continue
            }
            #expect(message.contains("format"))
        }
    }
}

@Test func testFormat16OverlayReplacesBaseRegistryEntry() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
      "pack":{"pack_format":80,"supported_formats":80,"description":"Overlay test"},
      "overlays":{"entries":[{"formats":80,"directory":"overlay"}]}
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let base = root.appendingPathComponent("data/test/tags/item", isDirectory: true)
    let overlay = root.appendingPathComponent("overlay/data/test/tags/item", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
    try Data(#"{"values":["minecraft:stone"]}"#.utf8).write(to: base.appendingPathComponent("sample.json"))
    try Data(#"{"replace":true,"values":["minecraft:dirt"]}"#.utf8).write(to: overlay.appendingPathComponent("sample.json"))

    let pack = try DataPack(fromRootPath: root)
    let tag = pack.tagRegistry.get(RegistryKey(referencing: "test:item/sample"))
    #expect(tag?.replace == true)
    #expect(tag?.values == [.rawID("minecraft:dirt")])
}

@Test func testFormat43And45RejectWrongEraResourceFolders() throws {
    let cases: [(format: Int, path: String, replacement: String)] = [
        (42, "data/test/tags/item", "tags/items"),
        (43, "data/test/tags/items", "tags/item"),
        (44, "data/test/structure", "structures"),
        (45, "data/test/structures", "structure")
    ]

    for testCase in cases {
        let root = try makePackRoot(withPackMetadata: """
        {"pack":{"pack_format":\(testCase.format),"description":"Folder validation"}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidDirectory = root.appendingPathComponent(testCase.path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: invalidDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"values":[]}"#.utf8).write(to: invalidDirectory.appendingPathComponent("sample.json"))

        do {
            _ = try DataPack(fromRootPath: root)
            Issue.record("Expected pack format \(testCase.format) to reject \(testCase.path)")
        } catch let error as DataPack.LoadingErrors {
            guard case .invalidResourcePath(let message) = error else {
                Issue.record("Expected invalidResourcePath, got \(error)")
                continue
            }
            #expect(message.contains(testCase.path))
            #expect(message.contains(testCase.replacement))
        }
    }
}
